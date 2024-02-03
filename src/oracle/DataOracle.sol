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
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract DataOracle is IDataOracle, RoleValidation {
    using EnumerableSet for EnumerableSet.UintSet;

    IMarketMaker public marketMaker;
    IPriceOracle public priceOracle;

    uint256 public immutable LONG_BASE_UNIT;
    uint256 public immutable SHORT_BASE_UNIT;

    struct BlockData {
        bool isValid;
        uint256 blockNumber;
        uint256 blockTimestamp;
        uint256 cumulativeNetPnl; // Across all markets
        uint256 longMarketTokenPrice;
        uint256 shortMarketTokenPrice;
    }

    mapping(address => bool) public isMarket;
    mapping(address => uint256) private baseUnits;

    mapping(uint256 blockNumber => BlockData data) public blockData;
    mapping(uint256 _blockNumber => mapping(address _token => uint256 _price)) public tokenPrices;
    EnumerableSet.UintSet private dataRequests;

    event BlockDataRequested(uint256 indexed blockNumber);

    constructor(
        address _marketMaker,
        address _priceOracle,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit,
        address _roleStorage
    ) RoleValidation(_roleStorage) {
        marketMaker = IMarketMaker(_marketMaker);
        priceOracle = IPriceOracle(_priceOracle);
        LONG_BASE_UNIT = _longBaseUnit;
        SHORT_BASE_UNIT = _shortBaseUnit;
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

    function setBlockData(BlockData memory _data) external onlyAdmin {
        require(dataRequests.contains(_data.blockNumber), "DO: Block Data Not Requested");
        require(_data.isValid, "DO: Is Valid Must Be True");
        dataRequests.remove(_data.blockNumber);
        blockData[_data.blockNumber] = _data;
    }

    // wrong -> get net pnl first arg is index token
    // market is wrong
    // should return named var

    function getNetPnl(IMarket _market, uint256 _blockNumber) public view returns (int256 netPnl) {
        require(isMarket[address(_market)], "DO: Invalid Market");
        BlockData memory data = blockData[_blockNumber];
        require(data.isValid, "DO: Invalid Block Number");
        address indexToken = _market.indexToken();
        uint256 indexPrice = tokenPrices[_blockNumber][indexToken];
        uint256 indexBaseUnit = baseUnits[indexToken];
        netPnl = Pricing.getNetPnL(_market, indexPrice, indexBaseUnit, true)
            + Pricing.getNetPnL(_market, indexPrice, indexBaseUnit, false);
    }

    /// @dev To convert to usd, needs to be 1e18 DPs
    function getCumulativeNetPnl(uint256 _blockNumber) external view returns (int256 totalPnl) {
        BlockData memory data = blockData[_blockNumber];
        require(data.isValid, "DO: Invalid Block Number");
        totalPnl = int256(data.cumulativeNetPnl);
    }

    function getBaseUnits(address _token) external view returns (uint256) {
        return baseUnits[_token];
    }
}
