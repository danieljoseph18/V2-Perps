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

import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {IMarket} from "./interfaces/IMarket.sol";

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
    function setMarketConfig(IMarket _market, IMarket.Config memory _config) external onlyModerator {
        require(address(_market) != address(0), "Market does not exist");
        _market.updateConfig(_config);
    }

    /**
     * ========================= Fees =========================
     */
    function updateLiquidityFees(uint256 _minExecutionFee, uint256 _depositFee, uint256 _withdrawalFee)
        external
        onlyModerator
    {
        liquidityVault.updateFees(_minExecutionFee, _depositFee, _withdrawalFee);
    }

    function setTradingFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyModerator {
        tradeStorage.setFees(_liquidationFee, _tradingFee);
    }
}
