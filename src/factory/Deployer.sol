// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Pool} from "../markets/Pool.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {Market, IMarket} from "../markets/Market.sol";
import {Vault, IVault} from "../markets/Vault.sol";
import {TradeStorage, ITradeStorage} from "../positions/TradeStorage.sol";
import {TradeEngine} from "../positions/TradeEngine.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {RewardTracker} from "../rewards/RewardTracker.sol";
import {LiquidityLocker} from "../rewards/LiquidityLocker.sol";

/// @dev - External library to deploy contracts
library Deployer {
    function deployMarket(
        Pool.Config calldata _config,
        IMarketFactory.DeployParams calldata _params,
        address _vault,
        address _weth,
        address _usdc
    ) external returns (address) {
        Market market =
            new Market(_config, _params.owner, _weth, _usdc, _vault, _params.indexTokenTicker, _params.isMultiAsset);
        return address(market);
    }

    function deployVault(IMarketFactory.DeployParams calldata _params, address _weth, address _usdc)
        external
        returns (address)
    {
        Vault vault = new Vault(_params.owner, _weth, _usdc, _params.marketTokenName, _params.marketTokenSymbol);
        return address(vault);
    }

    function deployTradeStorage(
        IMarket _market,
        IVault _vault,
        IReferralStorage _referralStorage,
        IPriceFeed _priceFeed
    ) external returns (address) {
        TradeStorage tradeStorage = new TradeStorage(_market, _vault, _referralStorage, _priceFeed);
        return address(tradeStorage);
    }

    function deployTradeEngine(IMarket market, ITradeStorage tradeStorage) external returns (address) {
        TradeEngine tradeEngine = new TradeEngine(tradeStorage, market);
        return address(tradeEngine);
    }

    function deployRewardTracker(IMarket market, string calldata _marketTokenName, string calldata _marketTokenSymbol)
        external
        returns (address)
    {
        RewardTracker rewardTracker = new RewardTracker(
            market,
            // Prepend Staked Prefix
            string(abi.encodePacked("Staked ", _marketTokenName)),
            string(abi.encodePacked("s", _marketTokenSymbol))
        );
        return address(rewardTracker);
    }

    function deployLiquidityLocker(address _rewardTracker, address _transferStakedTokens, address _weth, address _usdc)
        external
        returns (address)
    {
        LiquidityLocker liquidityLocker = new LiquidityLocker(_rewardTracker, _transferStakedTokens, _weth, _usdc);
        return address(liquidityLocker);
    }
}
