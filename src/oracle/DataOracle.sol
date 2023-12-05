//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {RoleValidation} from "../access/RoleValidation.sol";
import {PricingCalculator} from "../positions/PricingCalculator.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {MarketStructs} from "../markets/MarketStructs.sol";

contract DataOracle is RoleValidation {
    error DataOracle_InvalidMarket();

    IMarketStorage public marketStorage;
    address public priceOracle;

    MarketStructs.Market[] public markets;
    mapping(bytes32 => bool) public isMarket;
    mapping(address => uint256) public baseUnits;

    constructor(address _marketStorage, address _priceOracle, address _roleStorage) RoleValidation(_roleStorage) {
        marketStorage = IMarketStorage(_marketStorage);
        priceOracle = _priceOracle;
    }

    function setMarkets(MarketStructs.Market[] memory _markets) external onlyAdmin {
        for (uint256 i = 0; i < _markets.length; i++) {
            markets.push(_markets[i]);
            isMarket[_markets[i].marketKey] = true;
        }
    }

    /// @dev e.g 1e18 = 18 decimal places
    function setBaseUnit(address _token, uint256 _baseUnit) external onlyMarketMaker {
        baseUnits[_token] = _baseUnit;
    }

    function clearMarkets() external onlyAdmin {
        for (uint256 i = 0; i < markets.length; i++) {
            isMarket[markets[i].marketKey] = false;
        }
        delete markets;
    }

    // function getNetPnL(address _market, address _marketStorage, address _dataOracle, address _priceOracle, bool _isLong)

    function getNetPnl(MarketStructs.Market memory _market) public view returns (int256) {
        if (!isMarket[_market.marketKey]) revert DataOracle_InvalidMarket();
        return PricingCalculator.getNetPnL(
            _market.market, address(marketStorage), address(this), address(priceOracle), true
        )
            + PricingCalculator.getNetPnL(
                _market.market, address(marketStorage), address(this), address(priceOracle), false
            );
    }

    /// @dev To convert to usd, needs to be 1e18 DPs
    function getCumulativeNetPnl() external view returns (int256 totalPnl) {
        for (uint256 i = 0; i < markets.length; i++) {
            totalPnl += getNetPnl(markets[i]);
        }
        return totalPnl;
    }

    function getBaseUnits(address _token) external view returns (uint256) {
        return baseUnits[_token];
    }
}
