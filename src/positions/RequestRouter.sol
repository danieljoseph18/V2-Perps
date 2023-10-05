// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";

contract RequestRouter {
    using SafeERC20 for IERC20;
    using MarketStructs for MarketStructs.PositionRequest;
    using MarketStructs for MarketStructs.RequestType;
    // contract for creating requests for trades
    // limit orders, market orders, all will have 2 step process
    // swap orders included
    // orders will be stored in storage
    // orders will be executed by the Executor, which will put them on TradeManager

    ITradeStorage public tradeStorage;
    ILiquidityVault public liquidityVault;
    IMarketStorage public marketStorage;

    constructor(ITradeStorage _tradeStorage, ILiquidityVault _liquidityVault, IMarketStorage _marketStorage) {
        tradeStorage = _tradeStorage;
        liquidityVault = _liquidityVault;
        marketStorage = _marketStorage;
    }

    // if _isLimit, it's a limit order, else it's a market order
    // every time a request is created, call to the price oracle and sign the block price
    // update the mapping with the price at the block of the request
    /// @dev front-end can pass default values for block and index
    function createTradeRequest(MarketStructs.PositionRequest memory _positionRequest, bool _isLimit, uint256 _executionFee) external payable {
        uint256 minExecutionFee = tradeStorage.minExecutionFee();
        require(msg.value >= minExecutionFee, "RequestRouter: fee too low");
        require(msg.value == _executionFee, "RequestRouter: incorrect fee");

        _sendFeeToStorage(_executionFee);

        // get the key for the market
        bytes32 marketKey = keccak256(abi.encodePacked(_positionRequest.indexToken, _positionRequest.collateralToken));
        _validateAllocation(marketKey, _positionRequest.sizeDelta);

        _transferInTokens(_positionRequest.indexToken, _positionRequest.user, _positionRequest.collateralDelta);

        _deductTradingFee(_positionRequest);

        ITradeStorage target = ITradeStorage(tradeStorage);
        (uint256 marketLen, uint256 limitLen, , ,) = target.getRequestQueueLengths();
        uint256 index = _isLimit ? limitLen : marketLen;
        // get the request type, if COLLAT, set size to 0, if SIZE, set collateral to 0, if REGULAR do nothing
        if(_positionRequest.requestType == MarketStructs.RequestType(0)) {
            _positionRequest.collateralDelta = 0;
        } else if (_positionRequest.requestType == MarketStructs.RequestType(1)) {
            _positionRequest.sizeDelta = 0;
        }
        _positionRequest.requestIndex = index;
        _positionRequest.requestBlock = block.number;
        // validate the request meets all safety parameters
        // open the request on the trade storage contract
        _isLimit ? target.createLimitOrderRequest(_positionRequest) : target.createMarketOrderRequest(_positionRequest);

    }


    function createDecreaseRequest(MarketStructs.DecreasePositionRequest memory _decreaseRequest, bool _isLimit, uint256 _executionFee) external payable {
        uint256 minExecutionFee = tradeStorage.minExecutionFee();
        require(msg.value >= minExecutionFee, "RequestRouter: fee too low");
        require(msg.value == _executionFee, "RequestRouter: incorrect fee");

        _sendFeeToStorage(_executionFee);

        // validate the request meets all safety parameters
        // open the request on the trade storage contract
        ITradeStorage target = ITradeStorage(tradeStorage);
        (,, , uint256 marketLen,uint256 limitLen) = target.getRequestQueueLengths();
        uint256 index = _isLimit ? limitLen : marketLen;
        // get the request type, if COLLAT, set size to 0, if SIZE, set collateral to 0, if REGULAR do nothing
        if(_decreaseRequest.requestType == MarketStructs.RequestType(0)) {
            _decreaseRequest.collateralDelta = 0;
        } else if (_decreaseRequest.requestType == MarketStructs.RequestType(1)) {
            _decreaseRequest.sizeDelta = 0;
        }
        _decreaseRequest.requestIndex = index;
        _decreaseRequest.requestBlock = block.number;
        // validate the request meets all safety parameters
        // open the request on the trade storage contract
        _isLimit ? target.createLimitDecreaseRequest(_decreaseRequest) : target.createMarketDecreaseRequest(_decreaseRequest);
    }

    // get position to close
    // get the current price
    // create decrease request for full position size
    function createCloseRequest(bytes32 _key, uint256 _acceptablePrice, bool _isLimit) external {
        // validate the request meets all safety parameters
        // open the request on the trade storage contract
        ITradeStorage target = ITradeStorage(tradeStorage);
        (,, , uint256 marketLen,uint256 limitLen) = target.getRequestQueueLengths();
        uint256 index = _isLimit ? limitLen : marketLen;
        MarketStructs.Position memory _position = target.openPositions(_key);
        MarketStructs.DecreasePositionRequest memory _decreaseRequest = MarketStructs.DecreasePositionRequest({
            requestIndex: index,
            indexToken: _position.indexToken,
            user: _position.user,
            collateralToken: _position.collateralToken,
            sizeDelta: _position.positionSize,
            collateralDelta: _position.collateralAmount,
            requestType: MarketStructs.RequestType(2), // set to regular request
            requestBlock: block.number,
            acceptablePrice: _acceptablePrice,
            isLong: _position.isLong,
            isMarketOrder: !_isLimit
        });
        _isLimit ? target.createLimitDecreaseRequest(_decreaseRequest) : target.createMarketDecreaseRequest(_decreaseRequest);
    }


    function cancelOrderRequest(bytes32 _key, bool _isLimit) external {
        // perform safety checks => it exists, it's their position etc.
        ITradeStorage(tradeStorage).cancelOrderRequest(_key, _isLimit);
    }

    function _transferInTokens(address _token, address _user, uint256 _amount) internal {
        // transfer in the tokens
        // check tokens are stables
        // other safety checks
        IERC20(_token).safeTransferFrom(_user, address(tradeStorage), _amount);
    }

    function _deductTradingFee(MarketStructs.PositionRequest memory _positionRequest) internal {
        // get the fee
        uint256 fee = tradeStorage.tradingFee();
        // return 99.9% of the amount etc.
        uint256 feeAmount = (_positionRequest.collateralDelta * fee) / 1000;

        // transfer fee to trade storage
        // NEED FUNCTION IN TRADE STORAGE TO PROCESS FEES
        IERC20(_positionRequest.collateralToken).safeTransfer(address(tradeStorage), feeAmount);
    }

    function _sendFeeToStorage(uint256 _executionFee) internal returns (bool) {
        (bool success, ) = address(tradeStorage).call{value: _executionFee}("");
        require(success, "RequestRouter: fee transfer failed");
        return true;
    }

    // validate that the additional open interest won't put the market over the max open interest (allocated reserves)
    // call the mapping to get the allocation and divide by over collateralization then * 100
    // compare to what the size delta will put the open interest to
    function _validateAllocation(bytes32 _marketKey, uint256 _sizeDelta) internal view {
        uint256 allocation = ILiquidityVault(liquidityVault).getMarketAllocation(_marketKey);
        uint256 overcollateralization = ILiquidityVault(liquidityVault).overCollateralizationRatio();
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        uint256 totalOI = IMarket(market).getTotalOpenInterest();
        uint256 maxOI = (allocation / overcollateralization) * 100;
        require(totalOI + _sizeDelta <= maxOI, "Position size too large");
    }

}