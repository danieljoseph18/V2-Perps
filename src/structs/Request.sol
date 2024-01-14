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
library Request {
    // Request Type Classification
    enum Type {
        COLLATERAL_INCREASE,
        COLLATERAL_DECREASE,
        POSITION_INCREASE,
        POSITION_DECREASE,
        CREATE_POSITION
    }

    // Trade Request -> Sent by user
    struct Input {
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
    struct Data {
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
        Type requestType;
    }

    // Executed Request
    struct Execution {
        Data requestData;
        uint256 price;
        address feeReceiver;
    }
}
