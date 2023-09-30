// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

library MarketStructs {

    struct Market {
        address indexToken;
        address stablecoin;
        address marketToken;
        address market;
    }

    struct Position {
        bytes32 market; // can get index token from market ?
        address indexToken;
        address user;
        uint256 collateralAmount; // vs size = leverage
        uint256 indexAmount; // collateral is redeemed 1:1 for index tokens at position open, value of index fluctuates, giving PnL
        uint256 positionSize; // size of position in collat tokens (factors leverage)
        bool isLong; // will determine token used
        int256 realisedPnl;
        int256 fundingFees; // negative or positive, pay or earn
        uint256 entryLongCumulativeFunding;
        uint256 entryShortCumulativeFunding;
        uint256 entryTime;
        uint256 entryBlock;
    }

}