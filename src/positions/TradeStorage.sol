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
import {PricingCalculator} from "./PricingCalculator.sol";

contract TradeStorage is RoleValidation {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.Position;
    using MarketStructs for MarketStructs.PositionRequest;
    using SafeCast for uint256;
    using SafeCast for int256;

    IMarketStorage public marketStorage;
    ILiquidityVault public liquidityVault;
    ITradeVault public tradeVault;

    mapping(bool _isLimit => mapping(bytes32 _orderKey => MarketStructs.PositionRequest)) public orders;
    mapping(bool _isLimit => bytes32[] _orderKeys) public orderKeys;

    // Track open positions
    mapping(bytes32 _positionKey => MarketStructs.Position) public openPositions;
    mapping(bytes32 _marketKey => mapping(bool _isLong => bytes32[] _positionKeys)) public openPositionKeys;

    mapping(address _user => uint256 _rewards) public accumulatedRewards;

    /// Note move over to libraries
    uint256 public liquidationFeeUsd;
    uint256 public tradingFee;
    uint256 public minExecutionFee = 0.001 ether;
    uint256 public accumulatedBorrowFees; //Note Should accumulate in tradevault not here

    event OrderRequestCreated(bytes32 _orderKey, MarketStructs.PositionRequest _positionRequest);
    event OrderRequestCancelled(bytes32 _orderKey);
    event TradeExecuted(MarketStructs.ExecutionParams _executionParams);
    event DecreaseTokenTransfer(address _user, address _token, uint256 _principle, int256 _pnl);
    event LiquidatePosition(bytes32 _positionKey, address _liquidator, uint256 _fee);
    event ExecutionFeeSent(address _executor, uint256 _fee);
    event FeesProcessed(bytes32 _positionKey, uint256 _fundingFee, uint256 _borrowFee);
    event FundingFeesClaimed(address _user, uint256 _fundingFees);
    event TradingFeesSet(uint256 _liquidationFee, uint256 _tradingFee);

    error TradeStorage_InsufficientBalance();
    error TradeStorage_OrderDoesNotExist();
    error TradeStorage_PositionDoesNotExist();
    error TradeStorage_FeeExceedsCollateralDelta();
    error TradeStorage_InsufficientCollateralToClaim();
    error TradeStorage_LiquidationFeeExceedsMax();
    error TradeStorage_TradingFeeExceedsMax();
    error TradeStorage_FailedToSendExecutionFee();
    error TradeStorage_NoFeesToClaim();

    /// Note Move all number initializations to an initialize function
    constructor(IMarketStorage _marketStorage, ILiquidityVault _liquidityVault, ITradeVault _tradeVault)
        RoleValidation(roleStorage)
    {
        marketStorage = _marketStorage;
        liquidityVault = _liquidityVault;
        tradeVault = _tradeVault;
        liquidationFeeUsd = 5e18; // 5 USD
        tradingFee = 0.001e18; // 0.1%
    }

    function createOrderRequest(MarketStructs.PositionRequest memory _positionRequest) external onlyRouter {
        bytes32 _positionKey = TradeHelper.generateKey(_positionRequest);
        TradeHelper.validateRequest(address(this), _positionKey, _positionRequest.isLimit);
        _assignRequest(_positionKey, _positionRequest, _positionRequest.isLimit);
        emit OrderRequestCreated(_positionKey, _positionRequest);
    }

    /// Note Caller must be request creator
    function cancelOrderRequest(bytes32 _positionKey, bool _isLimit) external onlyRouter {
        if (orders[_isLimit][_positionKey].user == address(0)) revert TradeStorage_OrderDoesNotExist();

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
        emit OrderRequestCancelled(_positionKey);
    }

    function executeTrade(MarketStructs.ExecutionParams memory _executionParams)
        external
        onlyExecutor
        returns (MarketStructs.Position memory)
    {
        bytes32 key = TradeHelper.generateKey(_executionParams.positionRequest);

        uint256 price = ImpactCalculator.applyPriceImpact(
            _executionParams.signedBlockPrice, _executionParams.positionRequest.priceImpact
        );
        // if type = 0 => collateral edit => only for collateral increase
        if (_executionParams.positionRequest.sizeDelta == 0) {
            _executeCollateralEdit(_executionParams.positionRequest, price, key);
        } else {
            _executionParams.positionRequest.isIncrease
                ? _executePositionRequest(_executionParams.positionRequest, price, key)
                : _executeDecreasePosition(_executionParams.positionRequest, price, key);
        }
        _sendExecutionFee(_executionParams.executor, minExecutionFee);

        // fire event to be picked up by backend and stored in DB
        emit TradeExecuted(_executionParams);
        // return the edited position
        return openPositions[key];
    }

    // only callable from liquidator contract
    /// Note NEEDS FIX
    /// Note Should also transfer funding fees to the counterparty of the position
    function liquidatePosition(bytes32 _positionKey, address _liquidator) external onlyLiquidator {
        // check that the position exists
        if (openPositions[_positionKey].user == address(0)) revert TradeStorage_PositionDoesNotExist();
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
        emit LiquidatePosition(_positionKey, _liquidator, feesOwed);
    }

    function setFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyConfigurator {
        if (_liquidationFee > TradeHelper.MAX_LIQUIDATION_FEE) revert TradeStorage_LiquidationFeeExceedsMax();
        if (_tradingFee > TradeHelper.MAX_TRADING_FEE) revert TradeStorage_TradingFeeExceedsMax();
        liquidationFeeUsd = _liquidationFee;
        tradingFee = _tradingFee;
        emit TradingFeesSet(_liquidationFee, _tradingFee);
    }

    /// Claim funding fees for a specified position
    /// Review => Check claimable fee scale converts to tokens
    function claimFundingFees(bytes32 _positionKey) external {
        // get the position
        MarketStructs.Position storage position = openPositions[_positionKey];
        // check that the position exists
        if (position.user == address(0)) revert TradeStorage_PositionDoesNotExist();
        // get the funding fees a user is eligible to claim for that position
        _updateFundingParameters(_positionKey, position.indexToken, position.collateralToken);
        // if none, revert
        uint256 earnedFees = position.fundingParams.feesEarned;
        if (earnedFees == 0) revert TradeStorage_NoFeesToClaim();
        uint256 claimable = earnedFees - position.fundingParams.realisedFees;
        if (claimable == 0) revert TradeStorage_NoFeesToClaim();
        bytes32 marketKey = TradeHelper.getMarketKey(position.indexToken, position.collateralToken);
        if (position.isLong) {
            if (tradeVault.shortCollateral(marketKey) < claimable) revert TradeStorage_InsufficientCollateralToClaim();
        } else {
            if (tradeVault.longCollateral(marketKey) < claimable) revert TradeStorage_InsufficientCollateralToClaim();
        }
        // if some to claim, add to realised funding of the position
        openPositions[_positionKey].fundingParams.realisedFees += claimable;
        // transfer funding from the counter parties' liquidity pool
        position.isLong
            ? tradeVault.updateCollateralBalance(marketKey, claimable, false, false)
            : tradeVault.updateCollateralBalance(marketKey, claimable, true, false);
        // transfer funding to the user
        IERC20(position.collateralToken).safeTransfer(position.user, claimable);
        emit FundingFeesClaimed(position.user, claimable);
    }

    function getNextPositionIndex(bytes32 _marketKey, bool _isLong) external view returns (uint256) {
        return openPositionKeys[_marketKey][_isLong].length - 1;
    }

    function getOrderKeys() external view returns (bytes32[] memory, bytes32[] memory) {
        return (orderKeys[true], orderKeys[false]);
    }

    function getPositionFees(MarketStructs.Position memory _position) public view returns (uint256, uint256) {
        address market = TradeHelper.getMarket(address(marketStorage), _position.indexToken, _position.collateralToken);
        uint256 borrowFee = IMarket(market).getBorrowingFees(_position);
        return (borrowFee, liquidationFeeUsd);
    }

    function getRequestQueueLengths() public view returns (uint256, uint256) {
        return (orderKeys[false].length, orderKeys[true].length);
    }

    /// Review Check Flow With Tree Diagram
    function _executeCollateralEdit(
        MarketStructs.PositionRequest memory _positionRequest,
        uint256 _price,
        bytes32 _positionKey
    ) internal {
        // check the position exists
        if (openPositions[_positionKey].user == address(0)) revert TradeStorage_PositionDoesNotExist();
        // delete the request
        _deletePositionRequest(_positionKey, _positionRequest.requestIndex, _positionRequest.isLimit);
        // get the positions current collateral and size
        uint256 currentCollateral = openPositions[_positionKey].collateralAmount;
        uint256 currentSize = openPositions[_positionKey].positionSize;

        _updateFundingParameters(_positionKey, _positionRequest.indexToken, _positionRequest.collateralToken);

        // validate the added collateral won't push position below min leverage
        if (_positionRequest.isIncrease) {
            TradeHelper.checkLeverage(currentSize, currentCollateral + _positionRequest.collateralDelta);
            // edit the positions collateral and average entry price
            _editPosition(_positionRequest.collateralDelta, 0, 0, _price, true, _positionKey);
        } else {
            // Pay user's funding and borrowing fees off
            uint256 afterFeeAmount = processFees(_positionKey, _positionRequest);
            TradeHelper.checkLeverage(currentSize, currentCollateral - _positionRequest.collateralDelta);
            // Note check the remaining collateral is above the PNL losses + liquidaton fee (minimum collateral)
            _editPosition(afterFeeAmount, 0, 0, 0, false, _positionKey);
            bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken, _positionRequest.collateralToken);
            // Note Where is the borrow fee being transferred to the LiquidityVault?
            tradeVault.transferOutTokens(
                _positionRequest.collateralToken,
                marketKey,
                _positionRequest.user,
                afterFeeAmount,
                _positionRequest.isLong
            );
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
            address market = marketStorage.getMarket(marketKey).market;
            MarketStructs.Position memory _position =
                TradeHelper.generateNewPosition(market, address(this), _positionRequest, _price);
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

        int256 pnl = PricingCalculator.getDecreasePositionPnL(
            sizeDelta, _position.pnlParams.weightedAvgEntryPrice, _price, _position.isLong
        );

        uint256 principle = PricingCalculator.getDecreasePositionPrinciple(
            sizeDelta, _position.pnlParams.weightedAvgEntryPrice, _position.pnlParams.leverage
        );

        _editPosition(afterFeeAmount, sizeDelta, pnl, 0, false, _positionKey);

        // validate the decrease => if removing collat, lev must remain below threshold
        // add the size and collat deltas together
        // transfer that amount

        bytes32 marketKey = TradeHelper.getMarketKey(_positionRequest.indexToken, _positionRequest.collateralToken);

        // Handle Principle + PNL Transfers
        _handleTokenTransfers(_positionRequest, marketKey, pnl, principle);

        if (_position.positionSize == 0) {
            _deletePosition(_positionKey, marketKey, _position.isLong);
        }
    }

    function _handleTokenTransfers(
        MarketStructs.PositionRequest memory _positionRequest,
        bytes32 _marketKey,
        int256 _pnl,
        uint256 _principle
    ) internal {
        if (_pnl < 0) {
            // Loss scenario
            uint256 lossAmount = uint256(-_pnl); // Convert the negative PnL to a positive value for calculations
            require(_principle >= lossAmount, "Loss exceeds principle"); // Ensure that the principle can cover the loss
            // Note ^^ convert to revert

            uint256 userAmount = _principle - lossAmount;
            tradeVault.transferOutTokens(
                _positionRequest.collateralToken, _marketKey, _positionRequest.user, userAmount, _positionRequest.isLong
            );

            // Transfer the lossAmount to liquidity vault (assuming there's a function for it)
            tradeVault.transferLossToLiquidityVault(_positionRequest.collateralToken, lossAmount);
        } else {
            // Profit scenario
            tradeVault.transferOutTokens(
                _positionRequest.collateralToken, _marketKey, _positionRequest.user, _principle, _positionRequest.isLong
            );
            // Assuming liquidityVault has a function to transfer the profit
            liquidityVault.transferPositionProfit(_positionRequest.user, uint256(_pnl));
        }
        emit DecreaseTokenTransfer(_positionRequest.user, _positionRequest.collateralToken, _principle, _pnl);
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
                int256 sizeDeltaUsd =
                    _isIncrease ? _sizeDelta.toInt256() * _price.toInt256() : -_sizeDelta.toInt256() * _price.toInt256();
                position.pnlParams.weightedAvgEntryPrice = PricingCalculator.calculateWeightedAverageEntryPrice(
                    position.pnlParams.weightedAvgEntryPrice, position.pnlParams.sigmaIndexSizeUSD, sizeDeltaUsd, _price
                );
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

    function _sendExecutionFee(address _executor, uint256 _executionFee) internal {
        if (address(this).balance < _executionFee) revert TradeStorage_InsufficientBalance();
        (bool success,) = _executor.call{value: _executionFee}("");
        if (!success) revert TradeStorage_FailedToSendExecutionFee();
        emit ExecutionFeeSent(_executor, _executionFee);
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

        emit FeesProcessed(_positionKey, fundingFee, borrowFee);

        return _positionRequest.collateralDelta - fundingFee - borrowFee;
    }

    function _subtractFundingFee(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        returns (uint256 _fee)
    {
        // get the funding fee owed on the position
        uint256 feesOwed = _position.fundingParams.feesOwed;
        // Note: User shouldn't be able to reduce collateral by less than the fees owed
        if (feesOwed > _collateralDelta) revert TradeStorage_FeeExceedsCollateralDelta();
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

    /// Note Needs fix => should accumulate in TradeVault
    /// Review Where is token transfer happening?
    function _subtractBorrowingFee(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        returns (uint256 _fee)
    {
        address market = TradeHelper.getMarket(address(marketStorage), _position.indexToken, _position.collateralToken);
        uint256 borrowFee = BorrowingCalculator.calculateBorrowingFee(market, _position, _collateralDelta);
        accumulatedBorrowFees += borrowFee;
        return borrowFee;
    }

    /// Note Needs Permission To Transfer From TradeVault
    function _sendFeeToVault(address _token, uint256 _amount) internal {
        if (IERC20(_token).balanceOf(address(this)) < _amount) revert TradeStorage_InsufficientBalance();
        liquidityVault.accumulateBorrowingFees(_amount);
        IERC20(_token).safeTransferFrom(address(tradeVault), address(liquidityVault), _amount);
    }

    function _updateFundingParameters(bytes32 _positionKey, address _indexToken, address _collateralToken) internal {
        address market = TradeHelper.getMarket(address(marketStorage), _indexToken, _collateralToken);
        // calculate funding for the position
        (uint256 earned, uint256 owed) =
            FundingCalculator.getFeesSinceLastPositionUpdate(market, openPositions[_positionKey]);

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
}
