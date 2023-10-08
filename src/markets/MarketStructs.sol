// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

library MarketStructs {
    enum RequestType {
        COLLATERAL,
        SIZE,
        REGULAR
    }

    struct Market {
        address indexToken;
        address stablecoin;
        address market;
    }

    struct PositionRequest {
        uint256 requestIndex;
        bool isMarketOrder;
        address indexToken; // used to derive which market
        address user;
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        RequestType requestType;
        uint256 requestBlock;
        uint256 acceptablePrice;
        bool isLong;
    }

    struct DecreasePositionRequest {
        uint256 requestIndex;
        address user;
        address indexToken;
        address collateralToken;
        uint256 collateralDelta; // size delta = collateral delta * position leverage
        uint256 sizeDelta; // collateral delta = size delta / position leverage
        RequestType requestType;
        uint256 requestBlock;
        uint256 acceptablePrice;
        bool isLong;
        bool isMarketOrder;
    }

    struct Position {
        bytes32 market; // can get index token from market ?
        address indexToken;
        address collateralToken;
        address user;
        uint256 collateralAmount; // vs size = leverage
        uint256 positionSize; // position size in index tokens, value fluctuates in USD giving PnL
        bool isLong; // will determine token used
        int256 realisedPnl;
        int256 fundingFees; // negative or positive, pay or earn
        uint256 entryLongCumulativeFunding;
        uint256 entryShortCumulativeFunding;
        uint256 entryLongCumulativeBorrowFee; // borrow fee at entry for longs
        uint256 entryShortCumulativeBorrowFee; // borrow fee at entry for shorts
        uint256 entryTime;
        uint256 averagePricePerToken; // average price paid per 1 token in size in USD
    }

    struct Swap {
        address tokenA;
        address tokenB;
        uint256 tokenASupplied;
        uint256 tokenBReceived;
    }
}
