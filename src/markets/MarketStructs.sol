// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;
// q - can we use smaller data types anywhere to save on gas

library MarketStructs {
    struct Market {
        address indexToken;
        address market;
        bytes32 marketKey; // Note Use where applicable to save on gas
    }

    // q - can we pack bools to save on gas
    struct PositionRequest {
        uint256 requestIndex;
        bool isLimit;
        address indexToken; // used to derive which market
        address user;
        uint256 collateralDelta;
        uint256 sizeDelta;
        uint256 requestBlock;
        uint256 orderPrice; // Price for limit order
        uint256 maxSlippage; // 1e18 = 100% (0.03% default = 0.0003e18)
        bool isLong;
        bool isIncrease; // increase or decrease position
    }

    struct BorrowParams {
        uint256 feesOwed;
        uint256 lastBorrowUpdate;
        uint256 lastLongCumulativeBorrowFee; // borrow fee at last for longs
        uint256 lastShortCumulativeBorrowFee; // borrow fee at entry for shorts
    }

    struct FundingParams {
        uint256 feesEarned; // fees earned by the position in index tokens
        uint256 feesOwed; // fees owed by the position in index tokens
        uint256 lastFundingUpdate; // last time funding was updated
        uint256 lastLongCumulativeFunding; // last cumulative funding rate for longs
        uint256 lastShortCumulativeFunding; // last cumulative funding rate for shorts
    }

    struct PnLParams {
        uint256 weightedAvgEntryPrice;
        uint256 sigmaIndexSizeUSD; // Sum of all increases and decreases in index size USD
        uint256 leverage;
    }

    struct Position {
        uint256 index; // position in array
        bytes32 market; // can get index token from market ?
        address indexToken; // collateralToken is only WUSDC
        address user;
        uint256 collateralAmount; // vs size = leverage
        uint256 positionSize; // position size in index tokens, value fluctuates in USD giving PnL
        bool isLong; // will determine token used
        int256 realisedPnl;
        BorrowParams borrowParams;
        FundingParams fundingParams;
        PnLParams pnlParams;
        uint256 entryTimestamp;
    }

    struct ExecutionParams {
        PositionRequest positionRequest;
        uint256 signedBlockPrice;
        address feeReceiver;
    }
}
