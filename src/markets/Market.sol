// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket, IVault} from "./interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {Funding} from "../libraries/Funding.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {ReentrancyGuard} from "@solmate/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {Vault} from "./Vault.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";

contract Market is Vault, IMarket {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeCast for uint256;
    using SignedMath for int256;

    ITradeStorage public tradeStorage;
    // Max 112 assets per market
    // Fits 16 allocations per uint256
    uint256 private constant MAX_ASSETS = 112;

    EnumerableSet.Bytes32Set private assetIds;
    bool private isInitialized;

    // Each Asset's storage is tracked through this mapping
    mapping(bytes32 assetId => MarketStorage assetStorage) public marketStorage;

    /**
     *  ========================= Constructor  =========================
     */
    constructor(
        IVault.VaultConfig memory _vaultConfig,
        Config memory _tokenConfig,
        bytes32 _assetId,
        address _roleStorage
    ) Vault(_vaultConfig, _roleStorage) {
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 10000 << 240;
        _addToken(_tokenConfig, _assetId, allocations);
    }

    function initialize(ITradeStorage _tradeStorage) external onlyMarketMaker {
        if (isInitialized) revert Market_AlreadyInitialized();
        tradeStorage = _tradeStorage;
        isInitialized = true;
        emit Market_Initialzied();
    }

    function addToken(Config memory _config, bytes32 _assetId, uint256[] calldata _newAllocations)
        external
        onlyMarketMaker
    {
        if (assetIds.length() >= MAX_ASSETS) revert Market_MaxAssetsReached();
        _addToken(_config, _assetId, _newAllocations);
    }

    function removeToken(bytes32 _assetId, uint256[] calldata _newAllocations) external onlyAdmin {
        if (!assetIds.contains(_assetId)) revert Market_TokenDoesNotExist();
        bool success = assetIds.remove(_assetId);
        if (!success) revert Market_FailedToRemoveAssetId();
        _setAllocationsWithBits(_newAllocations);
        delete marketStorage[_assetId];
        emit TokenRemoved(_assetId);
    }

    /**
     *  ========================= Market State Functions  =========================
     */
    function updateConfig(Config memory _config, bytes32 _assetId) external onlyAdmin {
        marketStorage[_assetId].config = _config;
        emit MarketConfigUpdated(_assetId, _config);
    }

    function updateAdlState(bytes32 _assetId, bool _isFlaggedForAdl, bool _isLong) external onlyPositionManager {
        if (_isLong) {
            marketStorage[_assetId].config.adl.flaggedLong = _isFlaggedForAdl;
        } else {
            marketStorage[_assetId].config.adl.flaggedShort = _isFlaggedForAdl;
        }
        emit AdlStateUpdated(_assetId, _isFlaggedForAdl);
    }

    function updateFundingRate(bytes32 _assetId, uint256 _indexPrice) external nonReentrant onlyPositionManager {
        FundingValues memory funding = marketStorage[_assetId].funding;

        // Calculate the skew in USD
        int256 skewUsd = Funding.calculateSkewUsd(this, _assetId);

        // Calculate the current funding velocity
        funding.fundingRateVelocity = Funding.getCurrentVelocity(this, _assetId, skewUsd);

        // Calculate the current funding rate
        (funding.fundingRate, funding.fundingAccruedUsd) = Funding.recompute(this, _assetId, _indexPrice);

        // Update storage
        funding.lastFundingUpdate = block.timestamp.toUint48();

        marketStorage[_assetId].funding = funding;

        emit FundingUpdated(funding.fundingRate, funding.fundingRateVelocity, funding.fundingAccruedUsd);
    }

    function updateBorrowingRate(
        bytes32 _assetId,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) external nonReentrant onlyPositionManager {
        BorrowingValues memory borrowing = marketStorage[_assetId].borrowing;

        if (_isLong) {
            borrowing.longCumulativeBorrowFees +=
                Borrowing.calculateFeesSinceUpdate(borrowing.longBorrowingRate, borrowing.lastBorrowUpdate);
            borrowing.longBorrowingRate = Borrowing.calculateRate(
                this, _assetId, _indexPrice, _indexBaseUnit, _collateralPrice, _collateralBaseUnit, true
            );
        } else {
            borrowing.shortCumulativeBorrowFees +=
                Borrowing.calculateFeesSinceUpdate(borrowing.shortBorrowingRate, borrowing.lastBorrowUpdate);
            borrowing.shortBorrowingRate = Borrowing.calculateRate(
                this, _assetId, _indexPrice, _indexBaseUnit, _collateralPrice, _collateralBaseUnit, false
            );
        }

        borrowing.lastBorrowUpdate = uint48(block.timestamp);

        // Update Storage
        marketStorage[_assetId].borrowing = borrowing;

        emit BorrowingRatesUpdated(_assetId, borrowing.longBorrowingRate, borrowing.shortBorrowingRate);
    }

    function updateAverageEntryPrice(bytes32 _assetId, uint256 _priceUsd, int256 _sizeDeltaUsd, bool _isLong)
        external
        onlyPositionManager
    {
        if (_priceUsd == 0) revert Market_PriceIsZero();
        if (_sizeDeltaUsd == 0) return; // No Change

        PnlValues memory pnl = marketStorage[_assetId].pnl;

        if (_isLong) {
            pnl.longAverageEntryPriceUsd = Pricing.calculateWeightedAverageEntryPrice(
                pnl.longAverageEntryPriceUsd,
                marketStorage[_assetId].openInterest.longOpenInterest,
                _sizeDeltaUsd,
                _priceUsd
            );
        } else {
            pnl.shortAverageEntryPriceUsd = Pricing.calculateWeightedAverageEntryPrice(
                pnl.shortAverageEntryPriceUsd,
                marketStorage[_assetId].openInterest.shortOpenInterest,
                _sizeDeltaUsd,
                _priceUsd
            );
        }

        // Update Storage
        marketStorage[_assetId].pnl = pnl;

        emit AverageEntryPriceUpdated(_assetId, pnl.longAverageEntryPriceUsd, pnl.shortAverageEntryPriceUsd);
    }

    function updateOpenInterest(bytes32 _assetId, uint256 _sizeDeltaUsd, bool _isLong, bool _shouldAdd)
        external
        onlyPositionManager
    {
        // Update the open interest
        if (_shouldAdd) {
            _isLong
                ? marketStorage[_assetId].openInterest.longOpenInterest += _sizeDeltaUsd
                : marketStorage[_assetId].openInterest.shortOpenInterest += _sizeDeltaUsd;
        } else {
            _isLong
                ? marketStorage[_assetId].openInterest.longOpenInterest -= _sizeDeltaUsd
                : marketStorage[_assetId].openInterest.shortOpenInterest -= _sizeDeltaUsd;
        }
        emit OpenInterestUpdated(
            _assetId,
            marketStorage[_assetId].openInterest.longOpenInterest,
            marketStorage[_assetId].openInterest.shortOpenInterest
        );
    }

    function updateImpactPool(bytes32 _assetId, int256 _priceImpactUsd) external onlyPositionManager {
        _priceImpactUsd > 0
            ? marketStorage[_assetId].impactPool += _priceImpactUsd.abs()
            : marketStorage[_assetId].impactPool -= _priceImpactUsd.abs();
    }

    /**
     *  ========================= Allocations  =========================
     */
    function setAllocationsWithBits(uint256[] memory _allocations) external onlyStateKeeper {
        _setAllocationsWithBits(_allocations);
    }

    function _setAllocationsWithBits(uint256[] memory _allocations) internal {
        bytes32[] memory assets = assetIds.values();
        uint256 assetLen = assets.length;

        uint256 total = 0;
        uint256 allocationIndex = 0;

        for (uint256 i = 0; i < _allocations.length; ++i) {
            for (uint256 bitIndex = 0; bitIndex < 16;) {
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
                unchecked {
                    ++bitIndex;
                }
            }
        }

        if (total != TOTAL_ALLOCATION) revert Market_InvalidCumulativeAllocation();
    }

    function _addToken(Config memory _config, bytes32 _assetId, uint256[] memory _newAllocations) internal {
        if (assetIds.contains(_assetId)) revert Market_TokenAlreadyExists();
        bool success = assetIds.add(_assetId);
        if (!success) revert Market_FailedToAddAssetId();
        _setAllocationsWithBits(_newAllocations);
        marketStorage[_assetId].config = _config;
        marketStorage[_assetId].funding.lastFundingUpdate = block.timestamp.toUint48();
        marketStorage[_assetId].borrowing.lastBorrowUpdate = block.timestamp.toUint48();
        emit TokenAdded(_assetId, _config);
    }

    /**
     *  ========================= Getters  =========================
     */
    function getAssetIds() external view returns (bytes32[] memory) {
        return assetIds.values();
    }

    function getAssetsInMarket() external view returns (uint256) {
        return assetIds.length();
    }

    function getCumulativeBorrowFees(bytes32 _assetId) external view returns (uint256 longFees, uint256 shortFees) {
        return (getCumulativeBorrowFee(_assetId, true), getCumulativeBorrowFee(_assetId, false));
    }

    function getCumulativeBorrowFee(bytes32 _assetId, bool _isLong) public view returns (uint256) {
        return _isLong
            ? marketStorage[_assetId].borrowing.longCumulativeBorrowFees
            : marketStorage[_assetId].borrowing.shortCumulativeBorrowFees;
    }

    function getLastFundingUpdate(bytes32 _assetId) external view returns (uint48) {
        return marketStorage[_assetId].funding.lastFundingUpdate;
    }

    function getFundingRates(bytes32 _assetId) external view returns (int256 rate, int256 velocity) {
        return (marketStorage[_assetId].funding.fundingRate, marketStorage[_assetId].funding.fundingRateVelocity);
    }

    function getFundingAccrued(bytes32 _assetId) external view returns (int256) {
        return marketStorage[_assetId].funding.fundingAccruedUsd;
    }

    function getLastBorrowingUpdate(bytes32 _assetId) external view returns (uint48) {
        return marketStorage[_assetId].borrowing.lastBorrowUpdate;
    }

    function getBorrowingRate(bytes32 _assetId, bool _isLong) external view returns (uint256) {
        return _isLong
            ? marketStorage[_assetId].borrowing.longBorrowingRate
            : marketStorage[_assetId].borrowing.shortBorrowingRate;
    }

    function getStorage(bytes32 _assetId) external view returns (MarketStorage memory) {
        return marketStorage[_assetId];
    }

    function getConfig(bytes32 _assetId) external view returns (Config memory) {
        return marketStorage[_assetId].config;
    }

    function getBorrowingConfig(bytes32 _assetId) external view returns (BorrowingConfig memory) {
        return marketStorage[_assetId].config.borrowing;
    }

    function getFundingConfig(bytes32 _assetId) external view returns (FundingConfig memory) {
        return marketStorage[_assetId].config.funding;
    }

    function getImpactConfig(bytes32 _assetId) external view returns (ImpactConfig memory) {
        return marketStorage[_assetId].config.impact;
    }

    function getAdlConfig(bytes32 _assetId) external view returns (AdlConfig memory) {
        return marketStorage[_assetId].config.adl;
    }

    function getReserveFactor(bytes32 _assetId) external view returns (uint256) {
        return marketStorage[_assetId].config.reserveFactor;
    }

    function getMaxLeverage(bytes32 _assetId) external view returns (uint32) {
        return marketStorage[_assetId].config.maxLeverage;
    }

    function getMaxPnlFactor(bytes32 _assetId) external view returns (uint256) {
        return marketStorage[_assetId].config.adl.maxPnlFactor;
    }

    function getAllocation(bytes32 _assetId) external view returns (uint256) {
        return marketStorage[_assetId].allocationPercentage;
    }

    function getOpenInterest(bytes32 _assetId, bool _isLong) external view returns (uint256) {
        return _isLong
            ? marketStorage[_assetId].openInterest.longOpenInterest
            : marketStorage[_assetId].openInterest.shortOpenInterest;
    }

    function getAverageEntryPrice(bytes32 _assetId, bool _isLong) external view returns (uint256) {
        return _isLong
            ? marketStorage[_assetId].pnl.longAverageEntryPriceUsd
            : marketStorage[_assetId].pnl.shortAverageEntryPriceUsd;
    }

    function getAverageCumulativeBorrowFee(bytes32 _assetId, bool _isLong) external view returns (uint256) {
        return _isLong
            ? marketStorage[_assetId].borrowing.weightedAvgCumulativeLong
            : marketStorage[_assetId].borrowing.weightedAvgCumulativeShort;
    }

    function getImpactPool(bytes32 _assetId) external view returns (uint256) {
        return marketStorage[_assetId].impactPool;
    }
}
