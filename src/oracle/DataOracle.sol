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

//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {RoleValidation} from "../access/RoleValidation.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {Types} from "../libraries/Types.sol";

contract DataOracle is RoleValidation {
    IMarketStorage public marketStorage;
    address public priceOracle;

    mapping(uint256 _index => Types.Market) public markets;
    mapping(bytes32 => bool) public isMarket;
    mapping(address => uint256) private baseUnits;

    uint256 private marketEndIndex;

    constructor(address _marketStorage, address _priceOracle, address _roleStorage) RoleValidation(_roleStorage) {
        marketStorage = IMarketStorage(_marketStorage);
        priceOracle = _priceOracle;
    }

    function setMarkets(Types.Market[] memory _markets) external onlyAdmin {
        uint32 len = uint32(_markets.length);
        for (uint256 i = 0; i < len;) {
            markets[i] = _markets[i];
            isMarket[_markets[i].marketKey] = true;
            unchecked {
                ++i;
            }
        }
        marketEndIndex = len - 1;
    }

    /// @dev e.g 1e18 = 18 decimal places
    function setBaseUnit(address _token, uint256 _baseUnit) external onlyMarketMaker {
        baseUnits[_token] = _baseUnit;
    }

    function clearBaseUnit(address _token) external onlyMarketMaker {
        delete baseUnits[_token];
    }

    /// @dev Do While loop more efficient than For loop
    function clearMarkets() external onlyAdmin {
        uint256 i = 0;
        do {
            isMarket[markets[i].marketKey] = false;
            delete markets[i];
            unchecked {
                ++i;
            }
        } while (i <= marketEndIndex);
        marketEndIndex = 0;
    }

    function getNetPnl(Types.Market memory _market) public view returns (int256) {
        require(isMarket[_market.marketKey], "DO: Invalid Market");
        return Pricing.getNetPnL(_market.market, address(marketStorage), address(this), address(priceOracle), true)
            + Pricing.getNetPnL(_market.market, address(marketStorage), address(this), address(priceOracle), false);
    }

    /// @dev To convert to usd, needs to be 1e18 DPs
    function getCumulativeNetPnl() external view returns (int256 totalPnl) {
        uint256 i = 0;
        do {
            totalPnl += getNetPnl(markets[i]);
            unchecked {
                ++i;
            }
        } while (i <= marketEndIndex);
    }

    function getBaseUnits(address _token) external view returns (uint256) {
        return baseUnits[_token];
    }
}
