//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {RoleValidation} from "../access/RoleValidation.sol";
import {PricingCalculator} from "../positions/PricingCalculator.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {MarketStructs} from "../markets/MarketStructs.sol";

contract DataOracle is RoleValidation {
    error DataOracle_InvalidMarket();

    IMarketStorage public marketStorage;

    MarketStructs.Market[] public markets;
    mapping(bytes32 => bool) public isMarket;

    constructor(address _marketStorage, address _roleStorage) RoleValidation(_roleStorage) {
        marketStorage = IMarketStorage(_marketStorage);
    }

    function setMarkets(MarketStructs.Market[] memory _markets) external onlyAdmin {
        for (uint256 i = 0; i < _markets.length; i++) {
            markets.push(_markets[i]);
            isMarket[_markets[i].marketKey] = true;
        }
    }

    function clearMarkets() external onlyAdmin {
        for (uint256 i = 0; i < markets.length; i++) {
            isMarket[markets[i].marketKey] = false;
        }
        delete markets;
    }

    // getNetPnL(address _market, address _marketStorage, bytes32 _marketKey, bool _isLong)

    function getNetPnl(MarketStructs.Market memory _market) public view returns (int256) {
        if (!isMarket[_market.marketKey]) revert DataOracle_InvalidMarket();
        return PricingCalculator.getNetPnL(_market.market, address(marketStorage), _market.marketKey, true)
            + PricingCalculator.getNetPnL(_market.market, address(marketStorage), _market.marketKey, false);
    }

    /// @dev To convert to usd, needs to be 1e30 DPs
    function getCumulativeNetPnl() external view returns (int256 totalPnl) {
        for (uint256 i = 0; i < markets.length; i++) {
            totalPnl += getNetPnl(markets[i]);
        }
        return totalPnl;
    }
}
