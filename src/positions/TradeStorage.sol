// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { UD60x18, ud, unwrap } from "@prb/math/UD60x18.sol";

contract TradeStorage is RoleValidation {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.Position;
    using MarketStructs for MarketStructs.PositionRequest;
    using SafeCast for uint256;
    using SafeCast for int256;

    mapping(bool _isLimit => mapping(bytes32 _orderKey => MarketStructs.PositionRequest)) public orders;
    mapping(bool _isLimit => bytes32[] _orderKeys) public orderKeys;

    // Track open positions
    mapping(bytes32 _positionKey => MarketStructs.Position) public openPositions;
    mapping(bytes32 _marketKey => mapping(bool _isLong => bytes32[] _positionKeys)) public openPositionKeys;

    mapping(address _user => uint256 _rewards) public accumulatedRewards;


    mapping(bytes32 _marketKey => uint256 _collateral) public longCollateral;
    mapping(bytes32 _marketKey => uint256 _collateral) public shortCollateral;

    IMarketStorage public marketStorage;
    uint256 public liquidationFeeUsd; 
    uint256 public tradingFee; 
    uint256 public minExecutionFee = 0.001 ether;

    ILiquidityVault public liquidityVault;

    uint256 public constant MIN_LEVERAGE = 1e18; // 1x
    uint256 public constant MAX_LEVERAGE = 50e18; // 50x
    uint256 public constant MAX_LIQUIDATION_FEE = 100e18; // 100 USD

    constructor(IMarketStorage _marketStorage, ILiquidityVault _liquidityVault) RoleValidation(roleStorage) {
        marketStorage = _marketStorage;
        liquidityVault = _liquidityVault;
        liquidationFeeUsd = 5e18; // 5 USD
        tradingFee = 0.001e18; // 0.1%
    }

    ///////////////////////
    // REQUEST FUNCTIONS //
    ///////////////////////

    function createOrderRequest(MarketStructs.PositionRequest memory _positionRequest) external onlyRouter {
        bytes32 _key = _generateKey(_positionRequest);
        _validateRequest(_key, _positionRequest.isLimit);
        _assignRequest(_key, _positionRequest, _positionRequest.isLimit);
    }

    function cancelOrderRequest(bytes32 _key, bool _isLimit) external onlyRouter {
        require(orders[_isLimit][_key].user != address(0), "Order does not exist");

        uint256 index = orders[_isLimit][_key].requestIndex;
        uint256 lastIndex = orderKeys[_isLimit].length - 1;

        // Delete the order
        delete orders[_isLimit][_key];

        // If the order to be deleted is not the last one, replace its slot with the last order's key
        if (index != lastIndex) {
            bytes32 lastKey = orderKeys[_isLimit][lastIndex];
            orderKeys[_isLimit][index] = lastKey;
            orders[_isLimit][lastKey].requestIndex = index; // Update the requestIndex of the order that was moved
        }

        // Remove the last key
        orderKeys[_isLimit].pop();
    }

    //////////////////////////
    // EXECUTION FUNCTIONS //
    ////////////////////////

    // only callable from executor contracts
    // DEFINITELY NEED A LOT MORE SECURITY CHECKS
    function executeTrade(MarketStructs.ExecutionParams memory _executionParams)
        external
        onlyExecutor
        returns (MarketStructs.Position memory)
    {
        uint8 requestType = uint8(_executionParams.positionRequest.requestType);
        bytes32 key = _generateKey(_executionParams.positionRequest);

        uint256 price = _applyPriceImpact(
            _executionParams.signedBlockPrice, _executionParams.positionRequest.priceImpact, _executionParams.positionRequest.isLong
        );
        bool isIncrease = _executionParams.positionRequest.isIncrease;
        // if type = 0 => collateral edit => only for collateral increase
        if (requestType == 0) {
            _executeCollateralEdit(_executionParams.positionRequest, price, key, isIncrease);
        } else if (requestType == 1) {
            _executeSizeEdit(_executionParams.positionRequest, price, key, isIncrease);
        } else {
            isIncrease
                ? _executePositionRequest(_executionParams.positionRequest, price, key)
                : _executeDecreasePosition(_executionParams.positionRequest, price, key);
        }
        _sendExecutionFee(_executionParams.executor, minExecutionFee);

        // fire event to be picked up by backend and stored in DB

        // return the edited position
        return openPositions[key];
    }

    function _executeCollateralEdit(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _key,
        bool _isIncrease
    ) internal {
        // check the position exists
        require(openPositions[_key].user != address(0), "Position does not exist");
        // delete the request
        _deletePositionRequest(_key, _positionRequest.requestIndex, _positionRequest.isLimit);
        // if limit => ensure the limit has been met before deleting
        if (_positionRequest.isLimit) {
            // require current price >= limit price for shorts, <= limit price for longs
            require(
                _positionRequest.isLong
                    ? _price <= _positionRequest.acceptablePrice
                    : _price >= _positionRequest.acceptablePrice,
                "Limit price not met"
            );
        }
        // get the positions current collateral and size
        uint256 currentCollateral = openPositions[_key].collateralAmount;
        uint256 currentSize = openPositions[_key].positionSize;

        _updateFundingParameters(_key, _positionRequest);
        
        // validate the added collateral won't push position below min leverage
        if (_isIncrease) {
            require(
                ud(currentSize).div(ud(currentCollateral + _positionRequest.collateralDelta)) >= ud(MIN_LEVERAGE),
                "Collateral can't exceed size"
            );
            // edit the positions collateral and average entry price
            openPositions[_key].collateralAmount += _positionRequest.collateralDelta;
            openPositions[_key].averagePricePerToken += (openPositions[_key].averagePricePerToken + _price) / 2;
        } else {
            uint256 afterFeeAmount = _subtractFundingFee(openPositions[_key], _positionRequest.collateralDelta);
            // Note Need to process Borrowing Fee here
            require(
                ud(currentSize).div(ud(currentCollateral - afterFeeAmount)) <= ud(MAX_LEVERAGE), "Collateral exceeds max leverage"
            );
            // subtract the collateral
            openPositions[_key].collateralAmount -= afterFeeAmount;
            // ADD transfer the collateral reduced
            // Note Remove the PNL Parameter, add PNL into processFees function
            bytes32 marketKey = getMarketKey(_positionRequest.indexToken, _positionRequest.collateralToken);
            _transferOutTokens(_positionRequest.collateralToken, marketKey, _positionRequest.user, afterFeeAmount, 0, _positionRequest.isLong);
        }
    }

    function _executeSizeEdit(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _key,
        bool _isIncrease
    ) internal {
        // check the position exists
        require(openPositions[_key].user != address(0), "Position does not exist");
        // delete the request
        _deletePositionRequest(_key, _positionRequest.requestIndex, _positionRequest.isLimit);
        // if limit => ensure the limit has been met before deleting
        if (_positionRequest.isLimit) {
            // require current price >= limit price for shorts, <= limit price for longs
            require(
                _positionRequest.isLong
                    ? _price <= _positionRequest.acceptablePrice
                    : _price >= _positionRequest.acceptablePrice,
                "Limit price not met"
            );
        }
        // get the positions current collateral and size
        uint256 currentCollateral = openPositions[_key].collateralAmount;
        uint256 currentSize = openPositions[_key].positionSize;

        // calculate funding for the position

        // update the funding parameters 


        if (_isIncrease) {
            // validate added size won't push position above max leverage
            require(
                ud((currentSize + _positionRequest.sizeDelta)).div(ud(currentCollateral)) <= ud(MAX_LEVERAGE),
                "Size exceeds max leverage"
            );
            // edit the positions size and average entry price
            openPositions[_key].positionSize += _positionRequest.sizeDelta;
            openPositions[_key].averagePricePerToken = (openPositions[_key].averagePricePerToken + _price) / 2;
        } else {
            // check that decreasing the size won't put position below the min leverage
            require(
                ud(currentSize - _positionRequest.sizeDelta).div(ud(openPositions[_key].collateralAmount)) >= ud(MIN_LEVERAGE),
                "Size below min leverage"
            );
            // subtract the size
            openPositions[_key].positionSize -= _positionRequest.sizeDelta;
            // Note calculate and transfer any profit
            // Note claim funding and borrowing fees
        }
    }

    function _executePositionRequest(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _key
    ) internal {
        // regular increase, or new position request
        // check the request is valid
        if (_positionRequest.isLimit) {
            // require current price >= limit price for shorts, <= limit price for longs
            require(
                _positionRequest.isLong
                    ? _price <= _positionRequest.acceptablePrice
                    : _price >= _positionRequest.acceptablePrice,
                "Limit price not met"
            );
        }
        // if position exists, edit existing position
        _deletePositionRequest(_key, _positionRequest.requestIndex, _positionRequest.isLimit);
        if (openPositions[_key].user != address(0)) {
            // if exists, leverage must remain constant
            // calculate the size delta from the collateral delta
            // size / current collateral = leverage, +1 collateral = (+1 x leverage) size
            uint256 leverage = openPositions[_key].positionSize / openPositions[_key].collateralAmount;
            uint256 sizeDelta = _positionRequest.collateralDelta * leverage;

            // add on to the position
            openPositions[_key].collateralAmount += _positionRequest.collateralDelta;
            openPositions[_key].positionSize += sizeDelta;
            openPositions[_key].averagePricePerToken = (openPositions[_key].averagePricePerToken + _price) / 2;
        } else {
            // create a new position
            // calculate all input variables
            bytes32 market = keccak256(abi.encodePacked(_positionRequest.indexToken, _positionRequest.collateralToken));
            address marketAddress = IMarketStorage(marketStorage).getMarket(market).market;
            (uint256 longFunding, uint256 shortFunding, uint256 longBorrowFee, uint256 shortBorrowFee) =
                IMarket(marketAddress).getMarketParameters();
            uint256 positionIndex = openPositionKeys[market][_positionRequest.isLong].length - 1;
            // make sure all Position and PositionRequest instantiations are in the correct order.
            openPositions[_key] = MarketStructs.Position({
                index: positionIndex,
                market: market,
                indexToken: _positionRequest.indexToken,
                collateralToken: _positionRequest.collateralToken,
                user: _positionRequest.user,
                collateralAmount: _positionRequest.collateralDelta,
                positionSize: _positionRequest.sizeDelta,
                isLong: _positionRequest.isLong,
                realisedPnl: 0,
                borrowParams: MarketStructs.BorrowParams(longBorrowFee, shortBorrowFee),
                fundingParams: MarketStructs.FundingParams(0, 0, 0, 0, 0, block.timestamp, longFunding, shortFunding),
                averagePricePerToken: _price,
                entryTimestamp: block.timestamp
            });
            _positionRequest.isLong
                ? openPositionKeys[market][true].push(_key)
                : openPositionKeys[market][false].push(_key);
        }
    }

    function _executeDecreasePosition(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _key
    ) internal {
        if (_positionRequest.isLimit) {
            // require current price >= limit price for shorts, <= limit price for longs
            require(
                _positionRequest.isLong
                    ? _price <= _positionRequest.acceptablePrice
                    : _price >= _positionRequest.acceptablePrice,
                "Limit price not met"
            );
        }
        // decrease or close position
        _deletePositionRequest(_key, _positionRequest.requestIndex, _positionRequest.isLimit);
        // is it a full close or partial?
        // if full close, delete the position, transfer all of the collateral +- PNL
        // if partial close, calculate size delta from the collateral delta and decrease the position
        MarketStructs.Position storage _position = openPositions[_key];
        uint256 leverage = unwrap(ud(_position.positionSize).div(ud(_position.collateralAmount)));

        //process the fees for the decrease and return after fee amount
        // Note separate into separate functions => 1 to pay funding to counterparty
        // 1 to pay borrow fees to Liquidity Vault LPs
        uint256 afterFeeAmount;
        afterFeeAmount = _subtractFundingFee(_position, _positionRequest.collateralDelta);
        // Note Need to process the borrow fee here

        uint256 sizeDelta = afterFeeAmount * leverage;

        // only realise a percentage equivalent to the percentage of the position being closed
        int256 valueDelta = (sizeDelta * _position.averagePricePerToken).toInt256() - (sizeDelta * _price).toInt256();
        // if long, > 0 is profit, < 0 is loss
        // if short, > 0 is loss, < 0 is profit
        int256 pnl;
        // if profit, add to realised pnl
        if (valueDelta >= 0) {
            _position.isLong ? pnl += valueDelta : pnl -= valueDelta;
        } else {
            // subtract from realised pnl
            _position.isLong ? pnl -= valueDelta : pnl += valueDelta;
        }

        _position.realisedPnl += pnl;

        _position.collateralAmount -= afterFeeAmount;
        _position.positionSize -= sizeDelta;

        // validate the decrease => if removing collat, lev must remain below threshold
        // add the size and collat deltas together
        // transfer that amount

        bytes32 marketKey = getMarketKey(_positionRequest.indexToken, _positionRequest.collateralToken);
        // Note Separate PNL Substitution => add function here and return afterpnl amount
        _transferOutTokens(
            _positionRequest.collateralToken, marketKey, _positionRequest.user, _positionRequest.collateralDelta, pnl, _positionRequest.isLong
        );

        if (_position.positionSize == 0) {
            delete openPositions[_key];
            uint256 index = openPositions[_key].index;
            if (_position.isLong) {
                delete openPositionKeys[_position.market][true][index];
            } else {
                delete openPositionKeys[_position.market][false][index];
            }
        }
    }

    // only callable from liquidator contract
    /// Note NEEDS FIX
    /// Note Should also transfer funding fees to the counterparty of the position
    function liquidatePosition(bytes32 _positionKey, address _liquidator) external onlyLiquidator {
        // check that the position exists
        require(openPositions[_positionKey].user != address(0), "Position does not exist");
        // get the position fees
        uint256 borrowFee = _getBorrowingFees(openPositions[_positionKey]);
        // int256 fundingFees = _getFundingFees(_positionKey);
        uint256 feesOwed = borrowFee;
        // fundingFees >= 0 ? feesOwed += fundingFees.toUint256() : feesOwed -= (-fundingFees).toUint256();
        // delete the position from storage
        delete openPositions[_positionKey];
        // transfer the liquidation fee to the liquidator
        accumulatedRewards[_liquidator] += liquidationFeeUsd;
        // transfer the remaining collateral to the liquidity vault
        // Note LIQUDITY VAULT NEEDS FUNCTION TO CALL CLAIM REWARDS
        accumulatedRewards[address(liquidityVault)] += feesOwed;
    }

    // deletes a position request from storage
    function _deletePositionRequest(bytes32 _key, uint256 _requestIndex, bool _isLimit) internal {
        delete orders[_isLimit][_key];
        orderKeys[_isLimit][_requestIndex] = orderKeys[_isLimit][orderKeys[_isLimit].length - 1];
        orderKeys[_isLimit].pop();
    }

    function _validateRequest(bytes32 _key, bool _isLimit) internal view {
        if (_isLimit) {
            require(orders[true][_key].user == address(0), "Position already exists");
        } else {
            require(orders[false][_key].user == address(0), "Position already exists");
        }
    }

    function _generateKey(MarketStructs.PositionRequest memory _positionRequest) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                _positionRequest.indexToken, _positionRequest.user, _positionRequest.isLong
            )
        );
    }

    function _assignRequest(bytes32 _key, MarketStructs.PositionRequest memory _positionRequest, bool _isLimit)
        internal
    {
        if (_isLimit) {
            orders[true][_key] = _positionRequest;
            orderKeys[true].push(_key);
        } else {
            orders[false][_key] = _positionRequest;
            orderKeys[false].push(_key);
        }
    }

    /////////////////////
    // TOKEN RELATED //
    ////////////////////

    // contract must be validated to transfer funds from TradeStorage
    // perhaps need to adopt a plugin transfer method like GMX V1
    // Note Should only Do 1 thing, transfer out tokens and update state
    // Separate PNL substitution
    function _transferOutTokens(address _token, bytes32 _marketKey, address _to, uint256 _collateralDelta, int256 _pnl, bool _isLong) internal {
        // profit = size now - initial size => initial size is not their
        uint256 amount = _collateralDelta;
        _pnl >= 0 ? amount += _pnl.toUint256() : amount -= (-_pnl).toUint256();
        _isLong ? longCollateral[_marketKey] -= amount : shortCollateral[_marketKey] -= amount;
        // NEED TO ALSO GET PNL FROM LIQUIDITY VAULT TO COVER THIS
        IERC20(_token).safeTransfer( _to, amount);
    }

    function _sendExecutionFee(address _executor, uint256 _executionFee) internal returns (bool) {}

    // takes in borrow and funding fees owed
    // subtracts them
    // sends them to the liquidity vault
    // returns the collateral amount
    function processFees(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        returns (uint256 _afterFeeAmount)
    {
        // (uint256 borrowFee, int256 fundingFees,) = getPositionFees(_position);

        // int256 totalFees = borrowFee.toInt256() + fundingFees; // 0.0001e18 = 0.01%

        // if (totalFees > 0) {
        //     // subtract the fee from the position collateral delta
        //     uint256 fees = unwrap(ud(totalFees.toUint256()) * ud(_collateralDelta));
        //     // give fees to liquidity vault
        //     // Note need to store funding fees separately from borrow fees
        //     // Funding fees need to be claimable by the counterparty
        //     accumulatedRewards[address(liquidityVault)] += fees;
        //     // return size + fees
        //     _afterFeeAmount = _collateralDelta + fees;
        // } else if (totalFees < 0) {
        //     // user is owed fees
        //     // add fee to mapping in liquidity vault
        //     uint256 fees = (-totalFees).toUint256() * _collateralDelta; // precision
        //     liquidityVault.accumulateFundingFees(fees, _position.user);
        //     _afterFeeAmount = _collateralDelta;
        // } else {
        //     _afterFeeAmount = _collateralDelta;
        // }
    }

    function _subtractFundingFee(MarketStructs.Position memory _position, uint256 _collateralDelta) internal returns (uint256 _afterFeeAmount) {
        // get the funding fee owed on the position
        (uint256 longFundingFees, uint256 shortFundingFees) = _getFundingFees(_position);
        uint256 fundingFee = _position.isLong ? longFundingFees : shortFundingFees;
        // if nothing is owed, return the collateral delta
        if (fundingFee == 0) return _collateralDelta;
        // if something is owed, subtract it from the collateral delta
        uint256 fees = unwrap(ud(fundingFee) * ud(_collateralDelta));
        //uint256 feesOwed = unwrap(ud(earnedFundingFees) * ud(position.positionSize));
        // transfer the subtracted amount to the counterparties' liquidity
        bytes32 marketKey = getMarketKey(_position.indexToken, _position.collateralToken);
        if (_position.isLong) {
            shortCollateral[marketKey] += fees;
            longCollateral[marketKey] -= fees;
        } else {
            longCollateral[marketKey] += fees;
            shortCollateral[marketKey] -= fees;
        }
        bytes32 _positionKey = keccak256(
            abi.encodePacked(
                _position.indexToken, _position.user, _position.isLong
            ));
        openPositions[_positionKey].fundingParams.feesPaid += fees;
        // return the collateral delta - the funding fee paid to the counterparty
        _afterFeeAmount = _collateralDelta - fees;
    }


    /// Claim funding fees for a specified position
    function claimFundingFees(bytes32 _positionKey) external {
        // get the position
        MarketStructs.Position memory position = openPositions[_positionKey];
        // check that the position exists
        require(position.user != address(0), "Position does not exist");
        // get the funding fees a user is eligible to claim for that position
        (uint256 longFunding, uint256 shortFunding) = _getFundingFees(position);
        // if none, revert
        uint256 earnedFundingFees = position.isLong ? shortFunding : longFunding;
        if (earnedFundingFees == 0) revert("No funding fees to claim"); // Note Update to custom revert
        // apply funding fees to position size
        uint256 feesOwed = unwrap(ud(earnedFundingFees) * ud(position.positionSize)); // Note Check scale
        uint256 claimable = feesOwed - position.fundingParams.realisedFees; // underflow also = no fees
        if (claimable == 0) revert("No funding fees to claim"); // Note Update to custom revert
        bytes32 marketKey = getMarketKey(position.indexToken, position.collateralToken);
        if (position.isLong) {
            require(shortCollateral[marketKey] >= claimable, "Not enough collateral to claim"); // Almost impossible scenario
        } else {
            require(longCollateral[marketKey] >= claimable, "Not enough collateral to claim"); // Almost impossible scenario
        }
        // if some to claim, add to realised funding of the position
        openPositions[_positionKey].fundingParams.realisedFees += claimable;
        // transfer funding from the counter parties' liquidity pool
        position.isLong ? shortCollateral[marketKey] -= claimable : longCollateral[marketKey] -= claimable;
        // transfer funding to the user
        IERC20(position.collateralToken).safeTransfer(position.user, claimable);
    }

    function _updateFundingParameters(
        bytes32 _key,
        MarketStructs.PositionRequest memory _positionRequest
    ) internal {
        // calculate funding for the position
        (uint256 longFee, uint256 shortFee) = _getFundingFees(openPositions[_key]);

        // update funding parameters for the position
        openPositions[_key].fundingParams.longFeeDebt += longFee;
        openPositions[_key].fundingParams.shortFeeDebt += shortFee;

        uint256 claimable = openPositions[_key].isLong ? shortFee : longFee;
        openPositions[_key].fundingParams.claimableFees += claimable;

        // get current long and short cumulative funding rates
        // get market address first => then call functions to get rates
        address market = getMarket(_positionRequest.indexToken, _positionRequest.collateralToken);
        uint256 longCumulative = IMarket(market).longCumulativeFundingFees();
        uint256 shortCumulative = IMarket(market).shortCumulativeFundingFees();

        openPositions[_key].fundingParams.lastLongCumulativeFunding = longCumulative;
        openPositions[_key].fundingParams.lastShortCumulativeFunding = shortCumulative;

        openPositions[_key].fundingParams.lastFundingUpdate = block.timestamp;
    }

    /// Note Need function to process PNL => Check positions PNL and subtract a % of it whenever edited

    //////////////////////
    // SETTER FUNCTIONS //
    //////////////////////

    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyConfigurator {
        require(_liquidationFee <= MAX_LIQUIDATION_FEE, "Liquidation fee too high");
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
    }

    //////////////////////
    // GETTER FUNCTIONS //
    //////////////////////

    function getPositionFees(MarketStructs.Position memory _position) public view returns (uint256, uint256) {
        address market = marketStorage.getMarket(_position.market).market;
        uint256 borrowFee = IMarket(market).getBorrowingFees(_position);
        return (borrowFee, liquidationFeeUsd);
    }

    // if return value is negative, they're owed funding fees
    // if return value is positive, they owe funding fees
    function _getFundingFees(MarketStructs.Position memory _position) internal view returns (uint256 _longFunding, uint256 _shortFunding) {
        address market = marketStorage.getMarket(_position.market).market;
        return IMarket(market).getFundingFees(_position);
    }

    function _getBorrowingFees(MarketStructs.Position memory _position) internal view returns (uint256) {
        address market = marketStorage.getMarket(_position.market).market;
        return IMarket(market).getBorrowingFees(_position);
    }

    function getOrderKeys() external view returns (bytes32[] memory, bytes32[] memory) {
        return (orderKeys[true], orderKeys[false]);
    }

    function getRequestQueueLengths() public view returns (uint256, uint256) {
        return (orderKeys[false].length, orderKeys[true].length);
    }

    function getMarket(address _indexToken, address _collateralToken) public view returns (address) {
        bytes32 market = keccak256(abi.encodePacked(_indexToken, _collateralToken));
        return marketStorage.getMarket(market).market;
    }

    function getMarketKey(address _indexToken, address _collateralToken) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_indexToken, _collateralToken));
    }

    //////////////////
    // PRICE IMPACT //
    //////////////////

    // Note Wrong => Needs PRB Math not Scale Factor
    // Review
    function _applyPriceImpact(uint256 _signedBlockPrice, int256 _priceImpact, bool _isLong)
        internal
        pure
        returns (uint256)
    {
        // Scaling factor; for example, 10^4 to handle four decimal places
        uint256 scaleFactor = 10 ** 4;

        // Convert priceImpact to scaled integer (e.g., 0.1% becomes 10 when scaleFactor is 10^4)
        uint256 scaledImpact = (_priceImpact >= 0 ? _priceImpact : -_priceImpact).toUint256() * scaleFactor / 100;

        // Calculate the price change due to impact, then scale down
        uint256 priceDelta = (_signedBlockPrice * scaledImpact) / scaleFactor;

        // Apply the price impact
        if ((_priceImpact >= 0 && !_isLong) || (_priceImpact < 0 && _isLong)) {
            return _signedBlockPrice + priceDelta;
        } else {
            return _signedBlockPrice - priceDelta; // Ensure non-negative
        }
    }

    ////////////////////
    // Token Balances //
    ////////////////////

    function updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong) external onlyRouter {
        _isLong ? longCollateral[_marketKey] += _amount : shortCollateral[_marketKey] += _amount;
    }


}
