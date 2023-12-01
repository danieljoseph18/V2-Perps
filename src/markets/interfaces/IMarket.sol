// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../MarketStructs.sol";

interface IMarket {
    function initialise(
        uint256 _maxFundingVelocity,
        uint256 _skewScale,
        int256 _maxFundingRate,
        int256 _minFundingRate,
        uint256 _borrowingFactor,
        uint256 _borrowingExponent,
        bool _feeForSmallerSide,
        uint256 _priceImpactFactor,
        uint256 _priceImpactExponent
    ) external;
    function setFundingConfig(
        uint256 _maxFundingVelocity,
        uint256 _skewScale,
        int256 _maxFundingRate,
        int256 _minFundingRate
    ) external;
    function setBorrowingConfig(uint256 _borrowingFactor, uint256 _borrowingExponent, bool _feeForSmallerSide)
        external;
    function setPriceImpactConfig(uint256 _priceImpactFactor, uint256 _priceImpactExponent) external;
    function updateFundingRate(int256 _positionSizeUSD, bool _isLong) external;
    function updateBorrowingRate(bool _isLong) external;
    function updateTotalWAEP(uint256 _price, int256 _sizeDeltaUsd, bool _isLong) external;
    function getMarketParameters() external view returns (uint256, uint256, uint256, uint256);
    function getPrice(address _token) external view returns (uint256);
    function getMarketKey() external view returns (bytes32);
    function longCumulativeFundingFees() external view returns (uint256);
    function shortCumulativeFundingFees() external view returns (uint256);
    function longCumulativeBorrowFee() external view returns (uint256);
    function shortCumulativeBorrowFee() external view returns (uint256);
    function priceImpactFactor() external view returns (uint256);
    function priceImpactExponent() external view returns (uint256);
    function MAX_PRICE_IMPACT() external view returns (int256);
    function lastFundingUpdateTime() external view returns (uint256);
    function fundingRateVelocity() external view returns (int256);
    function fundingRate() external view returns (int256);
    function maxFundingRate() external view returns (int256);
    function minFundingRate() external view returns (int256);
    function skewScale() external view returns (uint256);
    function maxFundingVelocity() external view returns (uint256);
    function borrowingFactor() external view returns (uint256);
    function borrowingExponent() external view returns (uint256);
    function lastBorrowUpdateTime() external view returns (uint256);
    function longBorrowingRate() external view returns (uint256);
    function shortBorrowingRate() external view returns (uint256);
    function longTotalWAEP() external view returns (uint256);
    function shortTotalWAEP() external view returns (uint256);
    function longSizeSumUSD() external view returns (uint256);
    function shortSizeSumUSD() external view returns (uint256);
    function indexToken() external view returns (address);
}
