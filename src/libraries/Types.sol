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
library Types {
    // Request Type Classification
    enum RequestType {
        COLLATERAL_INCREASE,
        COLLATERAL_DECREASE,
        POSITION_INCREASE,
        POSITION_DECREASE,
        CREATE_POSITION
    }

    // Market
    struct Market {
        bool exists;
        address indexToken;
        address market;
        bytes32 marketKey; // Note Use where applicable to save on gas
    }

    // Trade Request -> Sent by user
    struct Trade {
        address indexToken;
        uint256 collateralDeltaUSDC;
        uint256 sizeDelta;
        uint256 orderPrice;
        uint256 maxSlippage;
        bool isLong;
        bool isLimit;
        bool isIncrease;
    }

    // Request -> Constructed by Router
    struct Request {
        address indexToken; // used to derive which market
        address user;
        uint256 collateralDelta;
        uint256 sizeDelta;
        uint256 requestBlock;
        uint256 orderPrice; // Price for limit order
        uint256 maxSlippage; // 1e18 = 100% (0.03% default = 0.0003e18)
        bool isLimit;
        bool isLong;
        bool isIncrease; // increase or decrease position
        RequestType requestType;
    }

    // Borrow Component of a Position
    struct Borrow {
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

    // Open Position
    struct Position {
        address market;
        address indexToken; // collateralToken is only WUSDC
        address user;
        uint256 collateralAmount; // vs size = leverage
        uint256 positionSize; // position size in index tokens, value fluctuates in USD giving PnL
        bool isLong; // will determine token used
        int256 realisedPnl;
        Borrow borrow;
        Funding funding;
        PnL pnl;
    }

    // Executed Request
    struct ExecutionParams {
        Request request;
        uint256 price;
        address feeReceiver;
    }
}
