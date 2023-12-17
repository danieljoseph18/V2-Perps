// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import {IMarket} from "./interfaces/IMarket.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

/// @dev Needs Configurator Role
contract GlobalMarketConfig is RoleValidation {
    ILiquidityVault public liquidityVault;
    ITradeStorage public tradeStorage;

    constructor(address _liquidityVault, address _tradeStorage, address _roleStorage) RoleValidation(_roleStorage) {
        liquidityVault = ILiquidityVault(_liquidityVault);
        tradeStorage = ITradeStorage(_tradeStorage);
    }

    /**
     * ========================= Oracle =========================
     */

    function setDataOracle(address _dataOracle) external onlyModerator {
        // set data oracle across all contracts to a new contract address
    }

    function setPriceOracle(address _priceOracle) external onlyModerator {
        // set price oracle across all contracts to a new contract address
    }

    /**
     * ========================= Market Config =========================
     */

    function setMarketFundingConfig(
        address _market,
        uint256 _maxFundingVelocity,
        uint256 _skewScale,
        int256 _maxFundingRate,
        int256 _minFundingRate
    ) external onlyModerator {
        require(_market != address(0), "Market does not exist");
        IMarket(_market).setFundingConfig(_maxFundingVelocity, _skewScale, _maxFundingRate, _minFundingRate);
    }

    function setMarketBorrowingConfig(
        address _market,
        uint256 _borrowingFactor,
        uint256 _borrowingExponent,
        bool _feeForSmallerSide
    ) external onlyModerator {
        require(_market != address(0), "Market does not exist");
        IMarket(_market).setBorrowingConfig(_borrowingFactor, _borrowingExponent, _feeForSmallerSide);
    }

    function setMarketPriceImpactConfig(address _market, uint256 _priceImpactFactor, uint256 _priceImpactExponent)
        external
        onlyModerator
    {
        require(_market != address(0), "Market does not exist");
        IMarket(_market).setPriceImpactConfig(_priceImpactFactor, _priceImpactExponent);
    }

    /**
     * ========================= Trade Config =========================
     */

    /// @dev Used if excessive build up of array keys prevents loop execution
    function setOrderStartIndexValue(uint256 _value) external onlyModerator {
        tradeStorage.setOrderStartIndexValue(_value);
    }

    /**
     * ========================= Fees =========================
     */

    function setLiquidityFee(uint256 _liquidityFee) external onlyModerator {
        liquidityVault.updateLiquidityFee(_liquidityFee);
    }

    function setTradingFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyModerator {
        tradeStorage.setFees(_liquidationFee, _tradingFee);
    }
}
