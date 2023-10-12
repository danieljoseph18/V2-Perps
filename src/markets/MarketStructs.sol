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
        bool isLimit;
        address indexToken; // used to derive which market
        address user;
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        RequestType requestType;
        uint256 requestBlock;
        uint256 acceptablePrice;
        int256 priceImpact;
        bool isLong;
        bool isIncrease; // increase or decrease position
    }

    struct EntryParams {
        uint256 entryLongCumulativeFunding;
        uint256 entryShortCumulativeFunding;
        uint256 entryLongCumulativeBorrowFee; // borrow fee at entry for longs
        uint256 entryShortCumulativeBorrowFee; // borrow fee at entry for shorts
        uint256 entryTime;
    }

    struct Position {
        uint256 index; // position in array
        bytes32 market; // can get index token from market ?
        address indexToken;
        address collateralToken;
        address user;
        uint256 collateralAmount; // vs size = leverage
        uint256 positionSize; // position size in index tokens, value fluctuates in USD giving PnL
        bool isLong; // will determine token used
        int256 realisedPnl;
        int256 fundingFees; // negative or positive, pay or earn
        EntryParams entryParams;
        uint256 averagePricePerToken; // average price paid per 1 token in size in USD
        // use PRB Geometric Mean or avg ^^
    }

    struct ExecutionParams {
        PositionRequest positionRequest;
        uint256 signedBlockPrice;
        address executor;
    }
}
