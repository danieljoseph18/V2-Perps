// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {MarketStructs} from "../MarketStructs.sol";
import {IDataOracle} from "../../oracle/interfaces/IDataOracle.sol";
import {IWUSDC} from "../../token/interfaces/IWUSDC.sol";
import {IMarketToken} from "./IMarketToken.sol";

interface ILiquidityVault {
    // Public State Variables
    function WUSDC() external view returns (IWUSDC);
    function liquidityToken() external view returns (IMarketToken);
    function dataOracle() external view returns (IDataOracle);
    function poolAmounts() external view returns (uint256);
    function accumulatedFees() external view returns (uint256);
    function liquidityFee() external view returns (uint256);
    function isHandler(address handler, address lp) external view returns (bool);
    function reservedAmounts(address _user) external view returns (uint256);
    function totalReserved() external view returns (uint256);

    // External Functions
    function setDataOracle(IDataOracle _dataOracle) external;
    function updateLiquidityFee(uint256 _liquidityFee) external;
    function setIsHandler(address _handler, bool _isHandler) external;
    function addLiquidity(uint256 _amount) external;
    function removeLiquidity(uint256 _marketTokenAmount) external;
    function addLiquidityForAccount(address _account, uint256 _amount) external;
    function removeLiquidityForAccount(address _account, uint256 _liquidityTokenAmount) external;
    function accumulateFees(uint256 _amount) external;
    function transferPositionProfit(address _user, uint256 _amount) external;
    function initialise(IDataOracle _dataOracle, uint256 _liquidityFee) external;
    function updateReservation(address _user, int256 _amount) external;

    // View Functions
    function getLiquidityTokenPrice() external view returns (uint256);
    function getAum() external view returns (uint256);
    function getAumInWusdc() external view returns (uint256);
    function getPrice(address _token) external view returns (uint256);
}
