// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarketStructs} from "../MarketStructs.sol";

interface ILiquidityVault {
    // Setters
    function updateOverCollateralizationPercentage(uint256 _percentage) external;
    function addMarket(MarketStructs.Market memory _market) external;

    // Liquidity
    function addLiquidity(uint256 _amount, address _tokenIn) external;
    function removeLiquidity(uint256 _marketTokenAmount, address _tokenOut) external;
    function addLiquidityForAccount(address _account, uint256 _amount, address _tokenIn) external;
    function removeLiquidityForAccount(address _account, uint256 _liquidityTokenAmount, address _tokenOut) external;

    // Pricing
    function getMarketTokenPrice() external view returns (uint256);
    function getAum() external view returns (uint256 aum);
    function getPrice(address _token) external view returns (uint256);

    // PnL
    function getNetPnL(bool _isLong) external view returns (int256);

    // Open Interest
    function getNetOpenInterest() external view returns (uint256);

    // Fees
    function accumulateBorrowingFees(uint256 _amount) external;
    function accumulateTradingFees(uint256 _amount) external;

    // Allocations
    function updateMarketAllocations() external;

    function updateLiquidityFee(uint256 _fee) external;

    // Getters for state variables
    function collateralToken() external view returns (address);
    function getStablecoin() external view returns (address);
    function getLiquidityToken() external view returns (address);
    function getPoolAmounts(address _token) external view returns (uint256);
    function getMarket(bytes32 _marketKey) external view returns (MarketStructs.Market memory);
    function getMarketAllocation(bytes32 key) external view returns (uint256);
    function getAccumulatedFees() external view returns (uint256);
    function overCollateralizationPercentage() external view returns (uint256);
    function accumulateFundingFees(uint256 _amount, address _account) external;
    function updateState(int256 _netPnL, uint256 _netOpenInterest) external;
    function accumulateFees(uint256 _amount) external;
}
