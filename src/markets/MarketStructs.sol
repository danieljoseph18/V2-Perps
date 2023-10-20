// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

library MarketStructs {
    struct Market {
        address indexToken;
        address stablecoin;
        address market;
        bytes32 marketKey; // Note Use where applicable to save on gas
    }

    struct PositionRequest {
        uint256 requestIndex;
        bool isLimit;
        address indexToken; // used to derive which market
        address user;
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
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
        uint256 feesEarned; // fees earned by the position per token
        uint256 feesOwed; // fees owed by the position per token
        uint256 lastFundingUpdate; // last time funding was updated
        uint256 lastLongCumulativeFunding; // last cumulative funding rate for longs
        uint256 lastShortCumulativeFunding; // last cumulative funding rate for shorts
    }

    struct PnLParams {
        uint256 weightedAvgEntryPrice;
        uint256 sigmaIndexSizeUSD; // Sum of all increases and decreases in index size USD
        uint256 leverage; // Note It's crucial leverage remains constant
    }
    /*
        liqValue = entryValue - (entryValue * (freeCollateral / entryValue))
        weightedAverageEntryPrice = x(indexSizeUSD * entryPrice) / sigmaIndexSizesUSD
        PNL = (Current price of index tokens - Weighted average entry price) * (Total position size / Current price of index tokens)
        RealizedPNL=(Current price − Weighted average entry price)×(Realized position size/Current price)
        int256 pnl = int256(amountToRealize * currentTokenPrice) - int256(amountToRealize * userPos.entryPriceWeighted);
        indexSize = collateralAdded * leverage
    */

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
        PnLParams pnlParams;
        uint256 entryTimestamp;
    }

    struct ExecutionParams {
        PositionRequest positionRequest;
        uint256 signedBlockPrice;
        address executor;
    }
}
