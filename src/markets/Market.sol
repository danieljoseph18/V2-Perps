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

import {IMarket} from "./interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Vault} from "./Vault.sol";
import {IMarketMaker} from "./interfaces/IMarketMaker.sol";
import {Pool} from "./Pool.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract Market is Vault, IMarket {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for uint256;
    using SignedMath for int256;

    EnumerableSet.AddressSet private indexTokens;

    // Each Asset's storage is tracked through this mapping
    mapping(address => MarketStorage) public marketStorage;

    /**
     *  ========================= Constructor  =========================
     */
    constructor(
        Pool.VaultConfig memory _vaultConfig,
        Config memory _tokenConfig,
        address _indexToken,
        address _roleStorage
    ) Vault(_vaultConfig, _roleStorage) {
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 10000 << 240;
        _addToken(_tokenConfig, _indexToken, allocations);
    }

    function addToken(Config memory _config, address _indexToken, uint256[] calldata _newAllocations)
        external
        onlyMarketMaker
    {
        _addToken(_config, _indexToken, _newAllocations);
    }

    function removeToken(address _indexToken, uint256[] calldata _newAllocations) external onlyAdmin {
        require(indexTokens.contains(_indexToken), "Market: Token does not exist");
        indexTokens.remove(_indexToken);
        _setAllocationsWithBits(_newAllocations);
        delete marketStorage[_indexToken];
        emit TokenRemoved(_indexToken);
    }

    /**
     *  ========================= Market State Functions  =========================
     */
    function updateConfig(Config memory _config, address _indexToken) external onlyConfigurator {
        marketStorage[_indexToken].config = _config;
        emit MarketConfigUpdated(_indexToken, _config);
    }

    function updateAdlState(address _indexToken, bool _isFlaggedForAdl, bool _isLong) external onlyProcessor {
        if (_isLong) {
            marketStorage[_indexToken].config.adl.flaggedLong = _isFlaggedForAdl;
        } else {
            marketStorage[_indexToken].config.adl.flaggedShort = _isFlaggedForAdl;
        }
        emit AdlStateUpdated(_indexToken, _isFlaggedForAdl);
    }

    /// @dev Called for every position entry / exit
    // Rate can be lagging if lack of updates to positions
    // @audit -> Should only be called for execution, not requests
    // Pricing data must be accurate
    function updateFundingRate(address _indexToken, uint256 _indexPrice, uint256 _indexBaseUnit)
        external
        nonReentrant
        onlyProcessor
    {
        FundingValues memory funding = marketStorage[_indexToken].funding;

        // Calculate the skew in USD
        int256 skewUsd = Funding.calculateSkewUsd(this, _indexToken, _indexPrice, _indexBaseUnit);

        // Calculate the current funding velocity
        funding.fundingRateVelocity = Funding.getCurrentVelocity(this, _indexToken, skewUsd);

        // Calculate the current funding rate
        (funding.fundingRate, funding.fundingAccruedUsd) = Funding.recompute(this, _indexToken, _indexPrice);

        // Update storage
        funding.lastFundingUpdate = block.timestamp.toUint48();

        marketStorage[_indexToken].funding = funding;

        emit FundingUpdated(funding.fundingRate, funding.fundingRateVelocity, funding.fundingAccruedUsd);
    }

    // Function to calculate borrowing fees per second
    /*
        borrowing factor * (open interest in usd) ^ (borrowing exponent factor) / (pool usd)
    */

    /// @dev Call every time OI is updated (trade open / close)
    // Needs fix -> Should be for both sides
    // @audit
    function updateBorrowingRate(
        address _indexToken,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _longTokenPrice,
        uint256 _longBaseUnit,
        uint256 _shortTokenPrice,
        uint256 _shortBaseUnit,
        bool _isLong
    ) external nonReentrant onlyProcessor {
        BorrowingValues memory borrowing = marketStorage[_indexToken].borrowing;
        // If time elapsed = 0, return
        uint48 lastUpdate = borrowing.lastBorrowUpdate;

        // update cumulative fees with current borrowing rate
        if (_isLong) {
            borrowing.longCumulativeBorrowFees +=
                Borrowing.calculateFeesSinceUpdate(borrowing.longBorrowingRate, lastUpdate);
            borrowing.longBorrowingRate = Borrowing.calculateRate(
                this,
                _indexToken,
                _indexPrice,
                _indexBaseUnit,
                _longTokenPrice,
                _shortTokenPrice,
                _longBaseUnit,
                _shortBaseUnit,
                true
            );
        } else {
            borrowing.shortCumulativeBorrowFees +=
                Borrowing.calculateFeesSinceUpdate(borrowing.shortBorrowingRate, lastUpdate);
            borrowing.shortBorrowingRate = Borrowing.calculateRate(
                this,
                _indexToken,
                _indexPrice,
                _indexBaseUnit,
                _longTokenPrice,
                _shortTokenPrice,
                _longBaseUnit,
                _shortBaseUnit,
                false
            );
        }
        borrowing.lastBorrowUpdate = uint48(block.timestamp);

        // Update Storage
        marketStorage[_indexToken].borrowing = borrowing;

        emit BorrowingRatesUpdated(_indexToken, borrowing.longBorrowingRate, borrowing.shortBorrowingRate);
    }

    /// @dev Updates Weighted Average Entry Price => Used to Track PNL For a Market
    function updateAverageEntryPrice(address _indexToken, uint256 _price, int256 _sizeDelta, bool _isLong)
        external
        onlyProcessor
    {
        require(_price != 0, "Market: Price is 0");
        if (_sizeDelta == 0) return; // No Change

        PnlValues memory pnl = marketStorage[_indexToken].pnl;

        if (_isLong) {
            pnl.longAverageEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
                pnl.longAverageEntryPrice, marketStorage[_indexToken].openInterest.longOpenInterest, _sizeDelta, _price
            );
        } else {
            pnl.shortAverageEntryPrice = Pricing.calculateWeightedAverageEntryPrice(
                pnl.shortAverageEntryPrice,
                marketStorage[_indexToken].openInterest.shortOpenInterest,
                _sizeDelta,
                _price
            );
        }

        // Update Storage
        marketStorage[_indexToken].pnl = pnl;

        emit AverageEntryPriceUpdated(_indexToken, pnl.longAverageEntryPrice, pnl.shortAverageEntryPrice);
    }

    /// @dev Only Order Processor
    function updateOpenInterest(address _indexToken, uint256 _indexTokenAmount, bool _isLong, bool _shouldAdd)
        external
        onlyProcessor
    {
        if (_shouldAdd) {
            _isLong
                ? marketStorage[_indexToken].openInterest.longOpenInterest += _indexTokenAmount
                : marketStorage[_indexToken].openInterest.shortOpenInterest += _indexTokenAmount;
        } else {
            _isLong
                ? marketStorage[_indexToken].openInterest.longOpenInterest -= _indexTokenAmount
                : marketStorage[_indexToken].openInterest.shortOpenInterest -= _indexTokenAmount;
        }
        emit OpenInterestUpdated(
            _indexToken,
            marketStorage[_indexToken].openInterest.longOpenInterest,
            marketStorage[_indexToken].openInterest.shortOpenInterest
        );
    }

    function updateImpactPool(address _indexToken, int256 _priceImpactUsd) external onlyProcessor {
        _priceImpactUsd > 0
            ? marketStorage[_indexToken].impactPool += _priceImpactUsd.abs()
            : marketStorage[_indexToken].impactPool -= _priceImpactUsd.abs();
    }

    /**
     *  ========================= Allocations  =========================
     */
    function setAllocationsWithBits(uint256[] memory _allocations) external onlyStateKeeper {
        _setAllocationsWithBits(_allocations);
    }

    function _setAllocationsWithBits(uint256[] memory _allocations) internal {
        address[] memory assets = indexTokens.values();
        uint256 assetLen = assets.length;

        uint256 total = 0;
        uint256 allocationIndex = 0;

        for (uint256 i = 0; i < _allocations.length; ++i) {
            for (uint256 bitIndex = 0; bitIndex < 16; ++bitIndex) {
                if (allocationIndex >= assetLen) {
                    break;
                }

                // Calculate the bit position for the current allocation
                uint256 startBit = 240 - (bitIndex * 16);
                uint256 allocation = (_allocations[i] >> startBit) & BITMASK_16;
                total += allocation;

                // Ensure that the allocationIndex does not exceed the bounds of the markets array
                if (allocationIndex < assetLen) {
                    marketStorage[assets[allocationIndex]].allocationPercentage = allocation;
                    ++allocationIndex;
                }
            }
        }

        require(total == TOTAL_ALLOCATION, "StateUpdater: Invalid Cumulative Allocation");
    }

    function _addToken(Config memory _config, address _indexToken, uint256[] memory _newAllocations) internal {
        require(!indexTokens.contains(_indexToken), "Market: Token already exists");
        indexTokens.add(_indexToken);
        _setAllocationsWithBits(_newAllocations);
        marketStorage[_indexToken].config = _config;
        marketStorage[_indexToken].funding.lastFundingUpdate = block.timestamp.toUint48();
        marketStorage[_indexToken].borrowing.lastBorrowUpdate = block.timestamp.toUint48();
        emit TokenAdded(_indexToken, _config);
    }

    /**
     *  ========================= Getters  =========================
     */
    function getCumulativeBorrowFees(address _indexToken) external view returns (uint256 longFees, uint256 shortFees) {
        return (getCumulativeBorrowFee(_indexToken, true), getCumulativeBorrowFee(_indexToken, false));
    }

    function getCumulativeBorrowFee(address _indexToken, bool _isLong) public view returns (uint256) {
        return _isLong
            ? marketStorage[_indexToken].borrowing.longCumulativeBorrowFees
            : marketStorage[_indexToken].borrowing.shortCumulativeBorrowFees;
    }

    function getLastFundingUpdate(address _indexToken) external view returns (uint48) {
        return marketStorage[_indexToken].funding.lastFundingUpdate;
    }

    function getFundingRates(address _indexToken) external view returns (int256, int256) {
        return (marketStorage[_indexToken].funding.fundingRate, marketStorage[_indexToken].funding.fundingRateVelocity);
    }

    function getFundingAccrued(address _indexToken) external view returns (int256) {
        return marketStorage[_indexToken].funding.fundingAccruedUsd;
    }

    function getLastBorrowingUpdate(address _indexToken) external view returns (uint48) {
        return marketStorage[_indexToken].borrowing.lastBorrowUpdate;
    }

    function getBorrowingRate(address _indexToken, bool _isLong) external view returns (uint256) {
        return _isLong
            ? marketStorage[_indexToken].borrowing.longBorrowingRate
            : marketStorage[_indexToken].borrowing.shortBorrowingRate;
    }

    function getConfig(address _indexToken) external view returns (Config memory) {
        return marketStorage[_indexToken].config;
    }

    function getBorrowingConfig(address _indexToken) external view returns (BorrowingConfig memory) {
        return marketStorage[_indexToken].config.borrowing;
    }

    function getFundingConfig(address _indexToken) external view returns (FundingConfig memory) {
        return marketStorage[_indexToken].config.funding;
    }

    function getImpactConfig(address _indexToken) external view returns (ImpactConfig memory) {
        return marketStorage[_indexToken].config.impact;
    }

    function getAdlConfig(address _indexToken) external view returns (AdlConfig memory) {
        return marketStorage[_indexToken].config.adl;
    }

    function getReserveFactor(address _indexToken) external view returns (uint256) {
        return marketStorage[_indexToken].config.reserveFactor;
    }

    function getMaxLeverage(address _indexToken) external view returns (uint32) {
        return marketStorage[_indexToken].config.maxLeverage;
    }

    function getMaxPnlFactor(address _indexToken) external view returns (uint256) {
        return marketStorage[_indexToken].config.adl.maxPnlFactor;
    }

    function getAllocation(address _indexToken) external view returns (uint256) {
        return marketStorage[_indexToken].allocationPercentage;
    }

    function getOpenInterest(address _indexToken, bool _isLong) external view returns (uint256) {
        return _isLong
            ? marketStorage[_indexToken].openInterest.longOpenInterest
            : marketStorage[_indexToken].openInterest.shortOpenInterest;
    }

    function getAverageEntryPrice(address _indexToken, bool _isLong) external view returns (uint256) {
        return _isLong
            ? marketStorage[_indexToken].pnl.longAverageEntryPrice
            : marketStorage[_indexToken].pnl.shortAverageEntryPrice;
    }

    function getImpactPool(address _indexToken) external view returns (uint256) {
        return marketStorage[_indexToken].impactPool;
    }
}
