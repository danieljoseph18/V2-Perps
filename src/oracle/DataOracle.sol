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
import {IMarketMaker} from "../markets/interfaces/IMarketMaker.sol";
import {Market} from "../structs/Market.sol";
import {Block} from "./Block.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract DataOracle is RoleValidation {
    using EnumerableSet for EnumerableSet.UintSet;

    IMarketMaker public marketMaker;
    address public priceOracle;

    mapping(uint256 _index => Market.Data) public markets;
    mapping(bytes32 => bool) public isMarket;
    mapping(address => uint256) private baseUnits;

    mapping(uint256 blockNumber => Block.Data data) public blockData;
    EnumerableSet.UintSet private dataRequests;

    uint256 private marketEndIndex;

    event BlockDataRequested(uint256 indexed blockNumber);

    constructor(address _marketMaker, address _priceOracle, address _roleStorage) RoleValidation(_roleStorage) {
        marketMaker = IMarketMaker(_marketMaker);
        priceOracle = _priceOracle;
    }
    /// @dev Don't use a for loop here.

    function setMarkets(Market.Data[] memory _markets) external onlyAdmin {
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

    function requestBlockData(uint256 _blockNumber) external onlyAdmin {
        if (!dataRequests.contains(_blockNumber)) {
            dataRequests.add(_blockNumber);
            emit BlockDataRequested(_blockNumber);
        }
    }

    function setBlockData(Block.Data memory _data) external onlyAdmin {
        require(dataRequests.contains(_data.blockNumber), "DO: Block Data Not Requested");
        require(_data.isValid, "DO: Is Valid Must Be True");
        dataRequests.remove(_data.blockNumber);
        blockData[_data.blockNumber] = _data;
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
    // wrong -> get net pnl first arg is index token
    // market is wrong
    // should return named var

    function getNetPnl(Market.Data memory _market) public view returns (int256 netPnl) {
        require(isMarket[_market.marketKey], "DO: Invalid Market");
        netPnl = Pricing.getNetPnL(_market.indexToken, address(marketMaker), address(this), address(priceOracle), true)
            + Pricing.getNetPnL(_market.indexToken, address(marketMaker), address(this), address(priceOracle), false);
    }

    /// @dev To convert to usd, needs to be 1e18 DPs
    function getCumulativeNetPnl(uint256 _blockNumber) external view returns (int256 totalPnl) {
        Block.Data memory data = blockData[_blockNumber];
        require(data.isValid, "DO: Invalid Block Number");
        totalPnl = int256(data.cumulativePnl);
    }

    function getBaseUnits(address _token) external view returns (uint256) {
        return baseUnits[_token];
    }
}
