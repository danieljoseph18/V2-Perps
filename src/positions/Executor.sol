// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";

contract Executor {
    // contract for executing trades
    // will be called by the TradeManager
    // will execute trades on the market contract
    // will execute trades on the funding contract
    // will execute trades on the liquidator contract

    address public marketStorage;

    constructor(address _marketStorage) {
        marketStorage = _marketStorage;
    }

    // when executing a trade, store it in MarketStorage
    // update the open interest in MarketStorage

    function _updateOpenInterest(bytes32 _marketKey, uint256 _positionSize, bool _isLong) internal {
        _isLong ? IMarketStorage(marketStorage).addOpenInterest(_marketKey, _positionSize, _isLong) : IMarketStorage(marketStorage).subtractOpenInterest(_marketKey, _positionSize, _isLong);
    }

    // in every action that interacts with Market, call _updateFundingRate();

}