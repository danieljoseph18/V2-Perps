// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

library Market {
    struct Data {
        bool exists;
        bytes32 marketKey;
        address indexToken;
        uint8 riskFactor; // 1 - 100 (1 = extreme risk, 100 = no risk)
        Config config;
        Funding funding;
        Borrowing borrowing;
        Pricing pricing;
    }

    struct Config {
        uint256 maxFundingVelocity;
        uint256 skewScale;
        int256 maxFundingRate;
        int256 minFundingRate;
        uint256 borrowingFactor;
        uint256 borrowingExponent;
        bool feeForSmallerSide;
        uint256 priceImpactFactor;
        uint256 priceImpactExponent;
    }

    struct Funding {
        uint32 lastFundingUpdateTime;
        int256 fundingRate;
        int256 fundingRateVelocity;
        uint256 longCumulativeFundingFees;
        uint256 shortCumulativeFundingFees;
    }

    struct Borrowing {
        uint32 lastBorrowUpdateTime;
        uint256 longCumulativeBorrowFees;
        uint256 shortCumulativeBorrowFees;
        uint256 longBorrowingRatePerSecond;
        uint256 shortBorrowingRatePerSecond;
    }

    struct Pricing {
        uint256 longTotalWAEP;
        uint256 shortTotalWAEP;
        uint256 longSizeSumUSD;
        uint256 shortSizeSumUSD;
        uint256 longOpenInterest; // in index tokens
        uint256 shortOpenInterest; // in index tokens
        uint256 maxOpenInterestUSD;
    }
}
