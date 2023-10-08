// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../MarketStructs.sol";

interface IMarket {
    function getMarketTokenPrice() external view returns (uint256);
    function getAum() external view returns (uint256 aum);
    function getPrice(address _token) external view returns (uint256);
    function getMarketKey() external view returns (bytes32);
    function getOpenInterest(bool _isLong) external view returns (uint256);
    function getTotalOpenInterest() external view returns (uint256);
    function upkeepNeeded() external view returns (bool);
    function updateFundingRate() external;
    function setFundingConfig(
        uint256 _fundingInterval,
        uint256 _maxFundingVelocity,
        uint256 _skewScale,
        uint256 _maxFundingRate
    ) external;
    function setBorrowingConfig(uint256 _borrowingFactor, uint256 _borrowingExponent, bool _feeForSmallerSide)
        external;
    function calculateBorrowingFees(bool _isLong) external view returns (uint256);
    function getPnL(MarketStructs.Position memory _position) external view returns (int256);
    function getNetPnL(bool _isLong) external view returns (int256);
    function getPriceImpact(MarketStructs.Position memory _position) external view returns (uint256);
    function addLiquidity(uint256 _amount, address _tokenIn) external;
    function removeLiquidity(uint256 _marketTokenAmount, address _tokenOut) external;
    function addLiquidityForAccount(address _account, uint256 _amount, address _tokenIn) external;
    function removeLiquidityForAccount(address _account, uint256 _marketTokenAmount, address _tokenOut) external;
    function setPriceImpactConfig(uint256 _priceImpactFactor, uint256 _priceImpactExponent) external;
    function longCumulativeFundingRate() external view returns (uint256);
    function shortCumulativeFundingRate() external view returns (uint256);
    function longCumulativeBorrowFee() external view returns (uint256);
    function shortCumulativeBorrowFee() external view returns (uint256);
    function updateBorrowingRate(bool _isLong) external;
    function getBorrowingFees(MarketStructs.Position memory _position) external view returns (uint256);
    function getFundingFees(MarketStructs.Position memory _position) external view returns (int256);
    function updateCumulativePricePerToken(uint256 _price, bool _isIncrease, bool _isLong) external;
}
