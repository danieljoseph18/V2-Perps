// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Pool} from "../markets/Pool.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {Market, IMarket} from "../markets/Market.sol";
import {Vault, IVault} from "../markets/Vault.sol";
import {TradeStorage} from "../positions/TradeStorage.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";

/// @dev - External library to deploy contracts
library Deployer {
    function deployMarket(
        Pool.Config calldata _config,
        IMarketFactory.DeployParams calldata _params,
        address _vault,
        address _weth,
        address _usdc
    ) external returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_params.indexTokenTicker, _params.owner, _params.isMultiAsset));
        Market market = new Market{salt: salt}(
            _config, _params.owner, _weth, _usdc, _vault, _params.indexTokenTicker, _params.isMultiAsset
        );
        return address(market);
    }

    function deployVault(IMarketFactory.DeployParams calldata _params, address _weth, address _usdc)
        external
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(_params.owner, _params.marketTokenName, _params.marketTokenSymbol));
        Vault vault =
            new Vault{salt: salt}(_params.owner, _weth, _usdc, _params.marketTokenName, _params.marketTokenSymbol);
        return address(vault);
    }

    function deployTradeStorage(IMarket market, IVault vault, IReferralStorage referralStorage, IPriceFeed priceFeed)
        external
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(market, vault));
        TradeStorage tradeStorage = new TradeStorage{salt: salt}(market, vault, referralStorage, priceFeed);
        return address(tradeStorage);
    }
}
