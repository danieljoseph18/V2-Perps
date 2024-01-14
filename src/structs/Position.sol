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

/// @dev Library containing all the data types used throughout the protocol
library Position {
    // Open Position
    struct Data {
        bytes32 marketKey;
        address indexToken; // collateralToken is only WUSDC
        address user;
        uint256 collateralAmount; // vs size = leverage
        uint256 positionSize; // position size in index tokens, value fluctuates in USD giving PnL
        bool isLong; // will determine token used
        int256 realisedPnl;
        Borrowing borrowing;
        Funding funding;
        PnL pnl;
    }

    // Borrow Component of a Position
    struct Borrowing {
        uint256 feesOwed;
        uint256 lastBorrowUpdate;
        uint256 lastLongCumulativeBorrowFee; // borrow fee at last for longs
        uint256 lastShortCumulativeBorrowFee; // borrow fee at entry for shorts
    }

    // Funding Component of a Position
    // All Values in Index Tokens
    struct Funding {
        uint256 feesEarned;
        uint256 feesOwed;
        uint256 lastFundingUpdate;
        uint256 lastLongCumulativeFunding;
        uint256 lastShortCumulativeFunding;
    }

    // PnL Component of a Position
    struct PnL {
        uint256 weightedAvgEntryPrice;
        uint256 sigmaIndexSizeUSD; // Sum of all increases and decreases in index size USD
    }
}
