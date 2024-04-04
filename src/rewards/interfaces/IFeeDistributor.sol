// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../../markets/interfaces/IMarket.sol";

interface IFeeDistributor {
    function pendingRewards(IMarket market) external view returns (uint256 wethAmount, uint256 usdcAmount);
    function distribute(IMarket market) external returns (uint256 wethAmount, uint256 usdcAmount);
    function accumulateFees(uint256 _wethAmount, uint256 _usdcAmount) external;
    function tokensPerInterval(IMarket _market)
        external
        view
        returns (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval);
}
