// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {ITradeVault} from "./interfaces/ITradeVault.sol";
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

    IMarketStorage public marketStorage;
    ILiquidityVault public liquidityVault;
    ITradeVault public tradeVault;

    /// Note move over to libraries
    uint256 public liquidationFeeUsd;
    uint256 public tradingFee;
    uint256 public minExecutionFee = 0.001 ether;
    uint256 public accumulatedBorrowFees;


    /// Note Move all number initializations to an initialize function
    constructor(IMarketStorage _marketStorage, ILiquidityVault _liquidityVault, ITradeVault _tradeVault) RoleValidation(roleStorage) {
        marketStorage = _marketStorage;
        liquidityVault = _liquidityVault;
        tradeVault = _tradeVault;
        liquidationFeeUsd = 5e18; // 5 USD
        tradingFee = 0.001e18; // 0.1%
    }

    ///////////////////////
    // REQUEST FUNCTIONS //
    ///////////////////////

    function createOrderRequest(MarketStructs.PositionRequest memory _positionRequest) external onlyRouter {
        bytes32 _positionKey = TradeHelper.generateKey(_positionRequest);
        TradeHelper.validateRequest(address(this), _positionKey, _positionRequest.isLimit);
        _assignRequest(_positionKey, _positionRequest, _positionRequest.isLimit);
    }

    /// Note Caller must be request creator
    function cancelOrderRequest(bytes32 _positionKey, bool _isLimit) external onlyRouter {
        require(orders[_isLimit][_positionKey].user != address(0), "Order does not exist");

        uint256 index = orders[_isLimit][_positionKey].requestIndex;
        uint256 lastIndex = orderKeys[_isLimit].length - 1;

        // Delete the order
        delete orders[_isLimit][_positionKey];

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

    function _executeCollateralEdit(MarketStructs.PositionRequest memory _positionRequest, uint256 _price, bytes32 _positionKey)
        internal
    {
        // check the position exists
        require(openPositions[_positionKey].user != address(0), "Position does not exist");
        // if limit => ensure the limit has been met before deleting
        if (_positionRequest.isLimit) TradeHelper.checkLimitPrice(_price, _positionRequest);
        // delete the request
        _deletePositionRequest(_positionKey, _positionRequest.requestIndex, _positionRequest.isLimit);
        // get the positions current collateral and size
        uint256 currentCollateral = openPositions[_positionKey].collateralAmount;
        uint256 currentSize = openPositions[_positionKey].positionSize;

        _updateFundingParameters(_positionKey, _positionRequest);

        // validate the added collateral won't push position below min leverage
        if (_positionRequest.isIncrease) {
            TradeHelper.checkLeverage(currentSize, currentCollateral + _positionRequest.collateralDelta);
            // edit the positions collateral and average entry price
            _editPosition(_positionRequest.collateralDelta, 0, 0, _price, true, _positionKey);
        } else {
            // Note can probably combine into 1 function alongside process fees to send them to the correct areas
            uint256 afterFeeAmount = processFees(_positionKey, _positionRequest);
            TradeHelper.checkLeverage(currentSize, currentCollateral - _positionRequest.collateralDelta);
            // Note check the remaining collateral is above the PNL losses + liquidaton fee (minimum collateral)
            _editPosition(afterFeeAmount, 0, 0, 0, false, _positionKey);
            bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken, _positionRequest.collateralToken);
            tradeVault.transferOutTokens(
                _positionRequest.collateralToken,
                marketKey,
                _positionRequest.user,
                afterFeeAmount,
                _positionRequest.isLong
            );
        }
    }

    function _executeSizeEdit(MarketStructs.PositionRequest memory _positionRequest, uint256 _price, bytes32 _positionKey)
        internal
    {
        // check the position exists
        require(openPositions[_positionKey].user != address(0), "Position does not exist");
        // delete the request
        _deletePositionRequest(_positionKey, _positionRequest.requestIndex, _positionRequest.isLimit);
        // if limit => ensure the limit has been met before deleting
        if (_positionRequest.isLimit) TradeHelper.checkLimitPrice(_price, _positionRequest);

        // get the positions current collateral and size
        uint256 currentCollateral = openPositions[_positionKey].collateralAmount;
        uint256 currentSize = openPositions[_positionKey].positionSize;

        // calculate funding for the position

        // update the funding parameters

        if (_positionRequest.isIncrease) {
            // validate added size won't push position above max leverage
            TradeHelper.checkLeverage(currentSize + _positionRequest.sizeDelta, currentCollateral);
            // edit the positions size and average entry price
            _editPosition(0, _positionRequest.sizeDelta, 0, _price, true, _positionKey);
        } else {
            // check that decreasing the size won't put position below the min leverage
            // Note, for a size edit, make the user supply enough collateral to cover their fees
            // Review, this won't work as collateralDelta will be defaulted to 0 for size edits currently
            uint256 afterFeeAmount = processFees(_positionKey, _positionRequest);
            TradeHelper.checkLeverage(currentSize - _positionRequest.sizeDelta, afterFeeAmount);
            // subtract the size
            // Note realise PNL and update 3rd argument
            _editPosition(0, _positionRequest.sizeDelta, 0, _price, false, _positionKey);
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
        bytes32 _positionKey
    ) internal {
        if (_positionRequest.isLimit) TradeHelper.checkLimitPrice(_price, _positionRequest);
        // decrease or close position
        _deletePositionRequest(_positionKey, _positionRequest.requestIndex, _positionRequest.isLimit);
        // is it a full close or partial?
        // if full close, delete the position, transfer all of the collateral +- PNL
        // if partial close, calculate size delta from the collateral delta and decrease the position
        MarketStructs.Position storage _position = openPositions[_positionKey];
        uint256 leverage = TradeHelper.calculateLeverage(_position.positionSize, _position.collateralAmount);

        //process the fees for the decrease and return after fee amount
        // Note separate into separate functions => 1 to pay funding to counterparty
        // 1 to pay borrow fees to Liquidity Vault LPs
        uint256 afterFeeAmount = processFees(_positionKey, _positionRequest);
        // Note Need to process the borrow fee here

        uint256 sizeDelta = afterFeeAmount * leverage;

        // Review: Probably some issues => Pos or negative PNL?
        int256 pnl =
            PnLCalculator.getDecreasePositionPnL(sizeDelta, _position.averagePricePerToken, _price, _position.isLong);

        _editPosition(afterFeeAmount, sizeDelta, pnl, 0, false, _positionKey);

        // validate the decrease => if removing collat, lev must remain below threshold
        // add the size and collat deltas together
        // transfer that amount

        bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken, _positionRequest.collateralToken);
        // Note Separate PNL Substitution => add function here and return afterpnl amount, replace collateralDelta
        tradeVault.transferOutTokens(
            _positionRequest.collateralToken,
            marketKey,
            _positionRequest.user,
            _positionRequest.collateralDelta,
            _positionRequest.isLong
        );

        if (_position.positionSize == 0) {
            _deletePosition(_positionKey, marketKey, _position.isLong);
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
    function _deletePositionRequest(bytes32 _positionKey, uint256 _requestIndex, bool _isLimit) internal {
        delete orders[_isLimit][_positionKey];
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

    function _assignRequest(bytes32 _positionKey, MarketStructs.PositionRequest memory _positionRequest, bool _isLimit)
        internal
    {
        if (_isLimit) {
            orders[true][_positionKey] = _positionRequest;
            orderKeys[true].push(_positionKey);
        } else {
            orders[false][_positionKey] = _positionRequest;
            orderKeys[false].push(_positionKey);
        }
    }

    /////////////////////
    // TOKEN RELATED //
    ////////////////////

    function _sendExecutionFee(address _executor, uint256 _executionFee) internal {
        require(address(this).balance >= _executionFee, "TradeStorage: Insufficient balance");
        payable(_executor).transfer(_executionFee);
    }

    // takes in borrow and funding fees owed
    // subtracts them
    // sends them to the liquidity vault
    // returns the collateral amount
    function processFees(bytes32 _positionKey, MarketStructs.PositionRequest memory _positionRequest)
        internal
        returns (uint256 _afterFeeAmount)
    {
        uint256 fundingFee = _subtractFundingFee(openPositions[_positionKey], _positionRequest.collateralDelta);
        uint256 borrowFee = _subtractBorrowingFee(openPositions[_positionKey], _positionRequest.collateralDelta);
        // transfer borrow fee to LPs in the LiquidityVault
        _sendFeeToVault(_positionRequest.collateralToken, borrowFee);

        return _positionRequest.collateralDelta - fundingFee - borrowFee;
    }

    /// currently only editing the struct in memory?
    function _subtractFundingFee(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        returns (uint256 _fee)
    {
        // get the funding fee owed on the position
        uint256 feesOwed = _position.fundingParams.feesOwed;
        // Note: User shouldn't be able to reduce collateral by less than the fees owed
        require(feesOwed <= _collateralDelta, "TradeStorage: FEES OWED EXCEEDS COLLATERAL DELTA");
        //uint256 feesOwed = unwrap(ud(earnedFundingFees) * ud(position.positionSize));
        // transfer the subtracted amount to the counterparties' liquidity
        bytes32 marketKey = TradeHelper.getMarketKey(_position.indexToken, _position.collateralToken);
        // Note Need to move collateral balance storage to TradeVault
        if (_position.isLong) {
            tradeVault.updateCollateralBalance(marketKey, feesOwed, false, true);
            tradeVault.updateCollateralBalance(marketKey, feesOwed, true, false);
        } else {
            tradeVault.updateCollateralBalance(marketKey, feesOwed, true, true);
            tradeVault.updateCollateralBalance(marketKey, feesOwed, false, false);
        }
        bytes32 _positionKey = keccak256(abi.encodePacked(_position.indexToken, _position.user, _position.isLong));
        openPositions[_positionKey].fundingParams.feesOwed = 0;
        // return the collateral delta - the funding fee paid to the counterparty
        _fee = feesOwed;
    }

    function _subtractBorrowingFee(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        returns (uint256 _fee)
    {
        address market = TradeHelper.getMarket(address(marketStorage), _position.indexToken, _position.collateralToken);
        uint256 borrowFee = BorrowingCalculator.calculateBorrowingFee(market, _position, _collateralDelta);
        accumulatedBorrowFees += borrowFee;
        return borrowFee;
    }

    function _sendFeeToVault(address _token, uint256 _amount) internal returns(bool) {
        require(IERC20(_token).balanceOf(address(this)) >= _amount, "TradeStorage: Insufficient balance");
        liquidityVault.accumulateBorrowingFees(_amount);
        IERC20(_token).safeTransfer(address(liquidityVault), _amount);
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
            require(tradeVault.shortCollateral(marketKey) >= claimable, "Not enough collateral to claim"); // Almost impossible scenario
        } else {
            require(tradeVault.longCollateral(marketKey) >= claimable, "Not enough collateral to claim"); // Almost impossible scenario
        }
        // if some to claim, add to realised funding of the position
        openPositions[_positionKey].fundingParams.realisedFees += claimable;
        // transfer funding from the counter parties' liquidity pool
        position.isLong ? tradeVault.updateCollateralBalance(marketKey, claimable, false, false) : tradeVault.updateCollateralBalance(marketKey, claimable, true, false);
        // transfer funding to the user
        IERC20(position.collateralToken).safeTransfer(position.user, claimable);
    }

    function _updateFundingParameters(bytes32 _positionKey, MarketStructs.PositionRequest memory _positionRequest) internal {
        address market =
            TradeHelper.getMarket(address(marketStorage), _positionRequest.indexToken, _positionRequest.collateralToken);
        // calculate funding for the position
        (uint256 longFee, uint256 shortFee) = FundingCalculator.getFundingFees(market, openPositions[_positionKey]);

        // update funding parameters for the position
        openPositions[_positionKey].fundingParams.longFeeDebt += longFee;
        openPositions[_positionKey].fundingParams.shortFeeDebt += shortFee;

        uint256 earned = openPositions[_positionKey].isLong ? shortFee * openPositions[_positionKey].positionSize : longFee * openPositions[_positionKey].positionSize;
        uint256 owed = openPositions[_positionKey].isLong ? longFee * openPositions[_positionKey].positionSize : shortFee * openPositions[_positionKey].positionSize;
        openPositions[_positionKey].fundingParams.feesEarned += earned;
        openPositions[_positionKey].fundingParams.feesOwed += owed;

        // get current long and short cumulative funding rates
        // get market address first => then call functions to get rates
        uint256 longCumulative = IMarket(market).longCumulativeFundingFees();
        uint256 shortCumulative = IMarket(market).shortCumulativeFundingFees();

        openPositions[_positionKey].fundingParams.lastLongCumulativeFunding = longCumulative;
        openPositions[_positionKey].fundingParams.lastShortCumulativeFunding = shortCumulative;

        openPositions[_positionKey].fundingParams.lastFundingUpdate = block.timestamp;
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

}
