// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

library MarketStructs {

    struct Market {
        address indexToken;
        address stablecoin;
        address marketToken;
        address market;
    }

    struct PositionRequest {
        uint256 requestIndex;
        bool isMarketOrder;
        address indexToken;
        address user;
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        uint256 requestBlock;
        uint256 acceptablePrice;
        bool isLong;
    }

    struct DecreasePositionRequest {
        uint256 requestIndex;
        address user;
        address indexToken;
        address collateralToken;
        uint256 sizeDelta;
        uint256 collateralDelta;
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
        uint256 positionSize; // position size in index tokens, value fluctuates giving PnL
        bool isLong; // will determine token used
        int256 realisedPnl;
        int256 fundingFees; // negative or positive, pay or earn
        uint256 entryLongCumulativeFunding;
        uint256 entryShortCumulativeFunding;
        uint256 entryCumulativeBorrowFee; // borrow fee at entry
        uint256 entryTime;
        uint256 averageEntryPrice; // signed price of the index token at request
    }

    struct Swap {
        address tokenA;
        address tokenB;
        uint256 tokenASupplied;
        uint256 tokenBReceived;
    }

}