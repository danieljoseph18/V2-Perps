//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Funding} from "../libraries/Funding.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Pricing} from "../libraries/Pricing.sol";

/// @dev Library containing all the data types used throughout the protocol
library Position {
    using SignedMath for int256;

    uint256 public constant MIN_LEVERAGE = 100; // 1x
    uint256 public constant MAX_LEVERAGE = 5000; // 50x
    uint256 public constant LEVERAGE_PRECISION = 100;
    uint256 public constant PRECISION = 1e18;
    // Open Position

    struct Data {
        IMarket market;
        address indexToken;
        address user;
        address collateralToken; // WETH long, USDC short
        uint256 collateralAmount; // vs size = leverage
        uint256 positionSize; // position size in index tokens, value fluctuates in USD giving PnL
        bool isLong; // will determine token used
        int256 realisedPnl;
        BorrowingParams borrowingParams;
        FundingParams fundingParams;
        PnLParams pnlParams;
    }

    // Borrow Component of a Position
    struct BorrowingParams {
        uint256 feesOwed;
        uint256 lastBorrowUpdate;
        uint256 lastLongCumulativeBorrowFee; // borrow fee at last for longs
        uint256 lastShortCumulativeBorrowFee; // borrow fee at entry for shorts
    }

    // Funding Component of a Position
    // All Values in Index Tokens
    struct FundingParams {
        uint256 feesEarned;
        uint256 feesOwed;
        uint256 lastFundingUpdate;
        uint256 lastLongCumulativeFunding;
        uint256 lastShortCumulativeFunding;
    }

    // PnL Component of a Position
    struct PnLParams {
        uint256 weightedAvgEntryPrice;
        uint256 sigmaIndexSizeUSD; // Sum of all increases and decreases in index size USD
    }

    // Trade Request -> Sent by user
    struct RequestInput {
        address indexToken;
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        uint256 orderPrice;
        uint256 maxSlippage;
        uint256 executionFee;
        bool isLong;
        bool isLimit;
        bool isIncrease;
        bool shouldWrap;
    }

    // Request -> Constructed by Router
    struct RequestData {
        RequestInput input;
        address market;
        address user;
        uint256 requestBlock;
        RequestType requestType;
    }

    // Executed Request
    struct RequestExecution {
        RequestData requestData;
        uint256 indexPrice;
        uint256 collateralPrice;
        address feeReceiver;
        bool isAdl;
    }

    // Request Type Classification
    enum RequestType {
        COLLATERAL_INCREASE,
        COLLATERAL_DECREASE,
        POSITION_INCREASE,
        POSITION_DECREASE,
        CREATE_POSITION
    }

    function getRequestType(RequestInput calldata _trade, Data memory _position, uint256 _collateralDelta)
        external
        pure
        returns (RequestType requestType)
    {
        // Case 1: Position doesn't exist (Create Position)
        if (_position.user == address(0)) {
            require(_trade.isIncrease, "RR: Invalid Decrease");
            require(_trade.sizeDelta != 0, "RR: Size Delta");
            requestType = RequestType.CREATE_POSITION;
        } else if (_trade.sizeDelta == 0) {
            // Case 2: Position exists but sizeDelta is 0 (Collateral Increase / Decrease)
            if (_trade.isIncrease) {
                requestType = RequestType.COLLATERAL_INCREASE;
            } else {
                require(_position.collateralAmount >= _collateralDelta, "RR: CD > CA");
                requestType = RequestType.COLLATERAL_DECREASE;
            }
        } else {
            // Case 3: Position exists and sizeDelta is not 0 (Position Increase / Decrease)
            require(_trade.sizeDelta != 0, "RR: Size Delta");
            if (_trade.isIncrease) {
                requestType = RequestType.POSITION_INCREASE;
            } else {
                require(_position.positionSize >= _trade.sizeDelta, "RR: PS < SD");
                require(_position.collateralAmount >= _collateralDelta, "RR: CD > CA");
                requestType = RequestType.POSITION_DECREASE;
            }
        }
    }

    function generateKey(RequestData memory _request) external pure returns (bytes32 positionKey) {
        positionKey = keccak256(abi.encode(_request.input.indexToken, _request.user, _request.input.isLong));
    }

    function checkLimitPrice(uint256 _price, RequestData memory _request) external pure {
        if (_request.input.isLong) {
            require(_price <= _request.input.orderPrice, "TH: Limit Price");
        } else {
            require(_price >= _request.input.orderPrice, "TH: Limit Price");
        }
    }

    function exists(Data memory _position) external pure returns (bool) {
        return _position.user != address(0);
    }

    // 1x = 100
    function checkLeverage(uint256 _collateralPrice, uint256 _sizeUsd, uint256 _collateral) external pure {
        uint256 collateralUsd = Math.mulDiv(_collateral, _collateralPrice, PRECISION);
        require(collateralUsd <= _sizeUsd, "TH: cUSD > sUSD");
        uint256 leverage = Math.mulDiv(_sizeUsd, LEVERAGE_PRECISION, collateralUsd);
        require(leverage >= MIN_LEVERAGE && leverage <= MAX_LEVERAGE, "TH: Leverage");
    }

    function createRequest(RequestInput calldata _trade, address _market, address _user, RequestType _requestType)
        external
        view
        returns (RequestData memory request)
    {
        request = RequestData({
            input: _trade,
            market: _market,
            user: _user,
            requestBlock: block.number,
            requestType: _requestType
        });
    }

    function generateNewPosition(IMarket _market, IDataOracle _dataOracle, RequestData memory _request, uint256 _price)
        external
        view
        returns (Data memory position)
    {
        // Get Entry Funding & Borrowing Values
        (uint256 longFundingFee, uint256 shortFundingFee, uint256 longBorrowFee, uint256 shortBorrowFee) =
            _market.getCumulativeFees();
        // get Trade Value in USD
        uint256 sizeUsd =
            getTradeValueUsd(_request.input.sizeDelta, _price, _dataOracle.getBaseUnits(_request.input.indexToken));
        position = Data({
            market: _market,
            indexToken: _request.input.indexToken,
            collateralToken: _request.input.collateralToken,
            user: _request.user,
            collateralAmount: _request.input.collateralDelta,
            positionSize: _request.input.sizeDelta,
            isLong: _request.input.isLong,
            realisedPnl: 0,
            borrowingParams: BorrowingParams(0, block.timestamp, longBorrowFee, shortBorrowFee),
            fundingParams: FundingParams(0, 0, block.timestamp, longFundingFee, shortFundingFee),
            pnlParams: PnLParams(_price, sizeUsd)
        });
    }

    function getPnl(Data memory _position, uint256 _price, uint256 _baseUnit) external pure returns (int256 pnl) {
        // Get the Entry Value (WAEP * Position Size)
        uint256 entryValue = Math.mulDiv(_position.pnlParams.weightedAvgEntryPrice, _position.positionSize, _baseUnit);
        // Get the Current Value (Price * Position Size)
        uint256 currentValue = Math.mulDiv(_price, _position.positionSize, _baseUnit);
        // Return the difference
        if (_position.isLong) {
            pnl = int256(currentValue) - int256(entryValue);
        } else {
            pnl = int256(entryValue) - int256(currentValue);
        }
    }

    /// @dev Need to adjust for decimals
    function getTradeValueUsd(uint256 _sizeDelta, uint256 _signedPrice, uint256 _baseUnit)
        public
        pure
        returns (uint256 tradeValueUsd)
    {
        tradeValueUsd = Math.mulDiv(_sizeDelta, _signedPrice, _baseUnit);
    }

    function isLiquidatable(
        IDataOracle _dataOracle,
        Position.Data memory _position,
        uint256 _collateralPrice,
        uint256 _indexPrice,
        uint256 liquidationFeeUsd
    ) public view returns (bool) {
        uint256 collateralValueUsd = Math.mulDiv(_position.collateralAmount, _collateralPrice, PRECISION);
        uint256 totalFeesOwedUsd = getTotalFeesOwedUsd(_position.market, _dataOracle, _position, _indexPrice);
        uint256 indexBaseUnit = _dataOracle.getBaseUnits(_position.indexToken);
        int256 pnl = Pricing.calculatePnL(_position, _indexPrice, indexBaseUnit);
        uint256 losses = liquidationFeeUsd + totalFeesOwedUsd;
        if (pnl < 0) {
            losses += uint256(-pnl);
        }
        if (collateralValueUsd <= losses) {
            return true;
        } else {
            return false;
        }
    }

    // Calculates the liquidation fee in Collateral Tokens
    function calculateLiquidationFee(IPriceOracle _priceOracle, uint256 _liquidationFeeUsd, address _token)
        external
        view
        returns (uint256 liquidationFee)
    {
        uint256 price = _priceOracle.getPrice(_token);
        liquidationFee = Math.mulDiv(_liquidationFeeUsd, PRECISION, price);
    }

    function createAdlOrder(Data memory _position, uint256 _sizeDelta, uint256 _indexPrice, uint256 _collateralPrice)
        external
        view
        returns (RequestExecution memory request)
    {
        // calculate collateral delta from size delta
        uint256 collateralDelta = Math.mulDiv(_position.collateralAmount, _sizeDelta, _position.positionSize);
        request = RequestExecution({
            requestData: RequestData({
                input: RequestInput({
                    indexToken: _position.indexToken,
                    collateralToken: _position.collateralToken,
                    collateralDelta: collateralDelta,
                    sizeDelta: _sizeDelta,
                    orderPrice: 0,
                    maxSlippage: 0,
                    executionFee: 0,
                    isLong: _position.isLong,
                    isLimit: false,
                    isIncrease: false,
                    shouldWrap: false
                }),
                market: address(_position.market),
                user: _position.user,
                requestBlock: block.number,
                requestType: RequestType.POSITION_DECREASE
            }),
            indexPrice: _indexPrice,
            collateralPrice: _collateralPrice,
            feeReceiver: address(0),
            isAdl: true
        });
    }

    function convertIndexAmountToCollateral(
        uint256 _indexAmount,
        uint256 _indexPrice,
        uint256 _baseUnit,
        uint256 _collateralPrice
    ) public pure returns (uint256 collateralAmount) {
        uint256 indexUsd = Math.mulDiv(_indexAmount, _indexPrice, _baseUnit);
        collateralAmount = Math.mulDiv(indexUsd, PRECISION, _collateralPrice);
    }

    function getTotalFeesOwedUsd(IMarket _market, IDataOracle _dataOracle, Data memory _position, uint256 _price)
        public
        view
        returns (uint256 totalFeesOwedUsd)
    {
        uint256 baseUnits = _dataOracle.getBaseUnits(_position.indexToken);

        uint256 borrowingFeeOwed = Borrowing.getTotalPositionFeesOwed(_market, _position);
        uint256 borrowingFeeUsd = Math.mulDiv(borrowingFeeOwed, _price, baseUnits);

        (, uint256 fundingFeeOwed) = Funding.getTotalPositionFees(_market, _position);
        uint256 fundingValueUsd = Math.mulDiv(fundingFeeOwed, _price, baseUnits);

        totalFeesOwedUsd = borrowingFeeUsd + fundingValueUsd;
    }

    function getMarketKey(address _indexToken) external pure returns (bytes32 marketKey) {
        marketKey = keccak256(abi.encode(_indexToken));
    }
}
