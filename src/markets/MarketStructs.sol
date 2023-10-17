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

    struct BorrowParams {
        uint256 entryLongCumulativeBorrowFee; // borrow fee at entry for longs
        uint256 entryShortCumulativeBorrowFee; // borrow fee at entry for shorts
    }

    struct FundingParams {
        uint256 realisedFees; // fees realised by position
        uint256 longFeeDebt; // fees owed by longs per token
        uint256 shortFeeDebt; // fees owed by shorts per token
        uint256 feesEarned; // fees earned by the position per token
        uint256 feesOwed; // fees owed by the position per token
        uint256 lastFundingUpdate; // last time funding was updated
        uint256 lastLongCumulativeFunding; // last cumulative funding rate for longs
        uint256 lastShortCumulativeFunding; // last cumulative funding rate for shorts
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
        BorrowParams borrowParams;
        FundingParams fundingParams;
        uint256 averagePricePerToken; // average price paid per 1 token in size in USD
        // use PRB Geometric Mean or avg ^^
        uint256 entryTimestamp;
    }

    struct ExecutionParams {
        PositionRequest positionRequest;
        uint256 signedBlockPrice;
        address executor;
    }
}
