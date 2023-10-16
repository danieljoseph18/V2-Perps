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
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {ImpactCalculator} from "./ImpactCalculator.sol";
import {BorrowingCalculator} from "./BorrowingCalculator.sol";
import {FundingCalculator} from "./FundingCalculator.sol";
import {TradeHelper} from "./TradeHelper.sol";
import {PnLCalculator} from "./PnLCalculator.sol";

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
        bytes32 _key = TradeHelper.generateKey(_positionRequest);
        TradeHelper.validateRequest(address(this), _key, _positionRequest.isLimit);
        _assignRequest(_key, _positionRequest, _positionRequest.isLimit);
    }

    /// Note Caller must be request creator
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
        bytes32 key = TradeHelper.generateKey(_executionParams.positionRequest);

        uint256 price = ImpactCalculator.applyPriceImpact(
            _executionParams.signedBlockPrice,
            _executionParams.positionRequest.priceImpact,
            _executionParams.positionRequest.isLong
        );
        bool isIncrease = _executionParams.positionRequest.isIncrease;
        // if type = 0 => collateral edit => only for collateral increase
        if (requestType == 0) {
            _executeCollateralEdit(_executionParams.positionRequest, price, key);
        } else if (requestType == 1) {
            _executeSizeEdit(_executionParams.positionRequest, price, key);
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

    function _executeCollateralEdit(MarketStructs.PositionRequest memory _positionRequest, uint256 _price, bytes32 _key)
        internal
    {
        // check the position exists
        require(openPositions[_key].user != address(0), "Position does not exist");
        // delete the request
        _deletePositionRequest(_key, _positionRequest.requestIndex, _positionRequest.isLimit);
        // if limit => ensure the limit has been met before deleting
        if (_positionRequest.isLimit) TradeHelper.checkLimitPrice(_price, _positionRequest);
        // get the positions current collateral and size
        uint256 currentCollateral = openPositions[_key].collateralAmount;
        uint256 currentSize = openPositions[_key].positionSize;

        _updateFundingParameters(_key, _positionRequest);

        // validate the added collateral won't push position below min leverage
        if (_positionRequest.isIncrease) {
            TradeHelper.checkLeverage(currentSize, currentCollateral + _positionRequest.collateralDelta);
            // edit the positions collateral and average entry price
            _editPosition(_positionRequest.collateralDelta, 0, 0, _price, true, _key);
        } else {
            uint256 afterFeeAmount = _subtractFundingFee(openPositions[_key], _positionRequest.collateralDelta);
            // Note Need to process Borrowing Fee here
            TradeHelper.checkLeverage(currentSize, currentCollateral - afterFeeAmount);
            // subtract the collateral
            // Note Update 3rd argument after adding PNL
            _editPosition(afterFeeAmount, 0, 0, 0, false, _key);
            // ADD transfer the collateral reduced
            // Note Remove the PNL Parameter, add PNL into processFees function
            bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken, _positionRequest.collateralToken);
            _transferOutTokens(
                _positionRequest.collateralToken,
                marketKey,
                _positionRequest.user,
                afterFeeAmount,
                0,
                _positionRequest.isLong
            );
        }
    }

    function _executeSizeEdit(MarketStructs.PositionRequest memory _positionRequest, uint256 _price, bytes32 _key)
        internal
    {
        // check the position exists
        require(openPositions[_key].user != address(0), "Position does not exist");
        // delete the request
        _deletePositionRequest(_key, _positionRequest.requestIndex, _positionRequest.isLimit);
        // if limit => ensure the limit has been met before deleting
        if (_positionRequest.isLimit) TradeHelper.checkLimitPrice(_price, _positionRequest);

        // get the positions current collateral and size
        uint256 currentCollateral = openPositions[_key].collateralAmount;
        uint256 currentSize = openPositions[_key].positionSize;

        // calculate funding for the position

        // update the funding parameters

        if (_positionRequest.isIncrease) {
            // validate added size won't push position above max leverage
            TradeHelper.checkLeverage(currentSize + _positionRequest.sizeDelta, currentCollateral);
            // edit the positions size and average entry price
            _editPosition(0, _positionRequest.sizeDelta, 0, _price, true, _key);
        } else {
            // check that decreasing the size won't put position below the min leverage
            TradeHelper.checkLeverage(currentSize - _positionRequest.sizeDelta, currentCollateral);
            // subtract the size
            // Note realise PNL and update 3rd argument
            _editPosition(0, _positionRequest.sizeDelta, 0, _price, false, _key);
            // Note calculate and transfer any profit
            // Note claim funding and borrowing fees
        }
    }

    function _executePositionRequest(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _positionKey
    ) internal {
        // regular increase, or new position request
        // check the request is valid
        if (_positionRequest.isLimit) TradeHelper.checkLimitPrice(_price, _positionRequest);

        // if position exists, edit existing position
        _deletePositionRequest(_positionKey, _positionRequest.requestIndex, _positionRequest.isLimit);
        if (openPositions[_positionKey].user != address(0)) {
            // if exists, leverage must remain constant
            // calculate the size delta from the collateral delta
            // size / current collateral = leverage, +1 collateral = (+1 x leverage) size
            /// Note USE PRB MATH
            uint256 leverage = TradeHelper.calculateLeverage(
                openPositions[_positionKey].positionSize, openPositions[_positionKey].collateralAmount
            );
            uint256 sizeDelta = _positionRequest.collateralDelta * leverage;

            // add on to the position
            _editPosition(_positionRequest.collateralDelta, sizeDelta, 0, _price, true, _positionKey);
        } else {
            bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken, _positionRequest.collateralToken);
            MarketStructs.Position memory _position =
                TradeHelper.generateNewPosition(address(this), _positionRequest, _price, address(marketStorage));
            _createNewPosition(_position, _positionKey, marketKey);
        }
    }

    function _executeDecreasePosition(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _key
    ) internal {
        if (_positionRequest.isLimit) TradeHelper.checkLimitPrice(_price, _positionRequest);
        // decrease or close position
        _deletePositionRequest(_key, _positionRequest.requestIndex, _positionRequest.isLimit);
        // is it a full close or partial?
        // if full close, delete the position, transfer all of the collateral +- PNL
        // if partial close, calculate size delta from the collateral delta and decrease the position
        MarketStructs.Position storage _position = openPositions[_key];
        uint256 leverage = TradeHelper.calculateLeverage(_position.positionSize, _position.collateralAmount);

        //process the fees for the decrease and return after fee amount
        // Note separate into separate functions => 1 to pay funding to counterparty
        // 1 to pay borrow fees to Liquidity Vault LPs
        uint256 afterFeeAmount;
        afterFeeAmount = _subtractFundingFee(_position, _positionRequest.collateralDelta);
        // Note Need to process the borrow fee here

        uint256 sizeDelta = afterFeeAmount * leverage;

        int256 pnl =
            PnLCalculator.getDecreasePositionPnL(sizeDelta, _position.averagePricePerToken, _price, _position.isLong);

        _editPosition(afterFeeAmount, sizeDelta, pnl, 0, false, _key);

        // validate the decrease => if removing collat, lev must remain below threshold
        // add the size and collat deltas together
        // transfer that amount

        bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken, _positionRequest.collateralToken);
        // Note Separate PNL Substitution => add function here and return afterpnl amount
        _transferOutTokens(
            _positionRequest.collateralToken,
            marketKey,
            _positionRequest.user,
            _positionRequest.collateralDelta,
            pnl,
            _positionRequest.isLong
        );

        if (_position.positionSize == 0) {
            _deletePosition(_key, marketKey, _position.isLong);
        }
    }

    // only callable from liquidator contract
    /// Note NEEDS FIX
    /// Note Should also transfer funding fees to the counterparty of the position
    function liquidatePosition(bytes32 _positionKey, address _liquidator) external onlyLiquidator {
        // check that the position exists
        require(openPositions[_positionKey].user != address(0), "Position does not exist");
        // get the position fees
        address market = TradeHelper.getMarket(
            address(marketStorage), openPositions[_positionKey].indexToken, openPositions[_positionKey].collateralToken
        );
        uint256 borrowFee = BorrowingCalculator.getBorrowingFees(market, openPositions[_positionKey]);
        // int256 fundingFees = FundingCalculator.getFundingFees(_positionKey);
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

    function _deletePosition(bytes32 _positionKey, bytes32 _marketKey, bool _isLong) internal {
        delete openPositions[_positionKey];
        uint256 index = openPositions[_positionKey].index;
        if (_isLong) {
            delete openPositionKeys[_marketKey][true][index];
        } else {
            delete openPositionKeys[_marketKey][false][index];
        }
    }

    function _editPosition(
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        int256 _pnlDelta,
        uint256 _price,
        bool _isIncrease,
        bytes32 _positionKey
    ) internal {
        MarketStructs.Position storage position = openPositions[_positionKey];
        if (_isIncrease) {
            if (_collateralDelta != 0) {
                position.collateralAmount += _collateralDelta;
            }
            if (_sizeDelta != 0) {
                position.positionSize += _sizeDelta;
            }
            if (_price != 0) {
                position.averagePricePerToken =
                    TradeHelper.calculateNewAveragePricePerToken(position.averagePricePerToken, _price);
            }
        } else {
            if (_collateralDelta != 0) {
                position.collateralAmount -= _collateralDelta;
            }
            if (_sizeDelta != 0) {
                position.positionSize -= _sizeDelta;
            }
            if (_pnlDelta != 0) {
                position.realisedPnl += _pnlDelta;
            }
        }
    }

    function _createNewPosition(MarketStructs.Position memory _position, bytes32 _positionKey, bytes32 _marketKey)
        internal
    {
        openPositions[_positionKey] = _position;
        openPositionKeys[_marketKey][_position.isLong].push(_positionKey);
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
    // Move to TradeVault
    function _transferOutTokens(
        address _token,
        bytes32 _marketKey,
        address _to,
        uint256 _collateralDelta,
        int256 _pnl,
        bool _isLong
    ) internal {
        // profit = size now - initial size => initial size is not their
        uint256 amount = _collateralDelta;
        _pnl >= 0 ? amount += _pnl.toUint256() : amount -= (-_pnl).toUint256();
        _isLong ? longCollateral[_marketKey] -= amount : shortCollateral[_marketKey] -= amount;
        // NEED TO ALSO GET PNL FROM LIQUIDITY VAULT TO COVER THIS
        IERC20(_token).safeTransfer(_to, amount);
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

    function _subtractFundingFee(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        returns (uint256 _afterFeeAmount)
    {
        // get the funding fee owed on the position
        address market = TradeHelper.getMarket(address(marketStorage), _position.indexToken, _position.collateralToken);
        uint256 fees = FundingCalculator.getFeeSubtraction(market, _position, _collateralDelta);
        //uint256 feesOwed = unwrap(ud(earnedFundingFees) * ud(position.positionSize));
        // transfer the subtracted amount to the counterparties' liquidity
        bytes32 marketKey = TradeHelper.getMarketKey(_position.indexToken, _position.collateralToken);
        if (_position.isLong) {
            shortCollateral[marketKey] += fees;
            longCollateral[marketKey] -= fees;
        } else {
            longCollateral[marketKey] += fees;
            shortCollateral[marketKey] -= fees;
        }
        bytes32 _positionKey = keccak256(abi.encodePacked(_position.indexToken, _position.user, _position.isLong));
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
        address market = TradeHelper.getMarket(address(marketStorage), position.indexToken, position.collateralToken);
        (uint256 longFunding, uint256 shortFunding) = FundingCalculator.getFundingFees(market, position);
        // if none, revert
        uint256 earnedFundingFees = position.isLong ? shortFunding : longFunding;
        if (earnedFundingFees == 0) revert("No funding fees to claim"); // Note Update to custom revert
        // apply funding fees to position size
        uint256 feesOwed = unwrap(ud(earnedFundingFees) * ud(position.positionSize)); // Note Check scale
        uint256 claimable = feesOwed - position.fundingParams.realisedFees; // underflow also = no fees
        if (claimable == 0) revert("No funding fees to claim"); // Note Update to custom revert
        bytes32 marketKey = TradeHelper.getMarketKey(position.indexToken, position.collateralToken);
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

    function _updateFundingParameters(bytes32 _key, MarketStructs.PositionRequest memory _positionRequest) internal {
        address market =
            TradeHelper.getMarket(address(marketStorage), _positionRequest.indexToken, _positionRequest.collateralToken);
        // calculate funding for the position
        (uint256 longFee, uint256 shortFee) = FundingCalculator.getFundingFees(market, openPositions[_key]);

        // update funding parameters for the position
        openPositions[_key].fundingParams.longFeeDebt += longFee;
        openPositions[_key].fundingParams.shortFeeDebt += shortFee;

        uint256 claimable = openPositions[_key].isLong ? shortFee : longFee;
        openPositions[_key].fundingParams.claimableFees += claimable;

        // get current long and short cumulative funding rates
        // get market address first => then call functions to get rates
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
        require(_liquidationFee <= TradeHelper.MAX_LIQUIDATION_FEE, "Liquidation fee too high");
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
    }

    //////////////////////
    // GETTER FUNCTIONS //
    //////////////////////

    function getPositionFees(MarketStructs.Position memory _position) public view returns (uint256, uint256) {
        address market = TradeHelper.getMarket(address(marketStorage), _position.indexToken, _position.collateralToken);
        uint256 borrowFee = IMarket(market).getBorrowingFees(_position);
        return (borrowFee, liquidationFeeUsd);
    }

    function getOrderKeys() external view returns (bytes32[] memory, bytes32[] memory) {
        return (orderKeys[true], orderKeys[false]);
    }

    function getRequestQueueLengths() public view returns (uint256, uint256) {
        return (orderKeys[false].length, orderKeys[true].length);
    }

    function getNextPositionIndex(bytes32 _marketKey, bool _isLong) external view returns (uint256) {
        return openPositionKeys[_marketKey][_isLong].length - 1;
    }

    ////////////////////
    // Token Balances //
    ////////////////////

    function updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong) external onlyRouter {
        _isLong ? longCollateral[_marketKey] += _amount : shortCollateral[_marketKey] += _amount;
    }
}
