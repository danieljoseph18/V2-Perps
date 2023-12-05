// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployV2} from "../../../script/DeployV2.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
import {LiquidityVault} from "../../../src/markets/LiquidityVault.sol";
import {MarketFactory} from "../../../src/markets/MarketFactory.sol";
import {MarketStorage} from "../../../src/markets/MarketStorage.sol";
import {MarketToken} from "../../../src/markets/MarketToken.sol";
import {StateUpdater} from "../../../src/markets/StateUpdater.sol";
import {IMockPriceOracle} from "../../../src/mocks/interfaces/IMockPriceOracle.sol";
import {IMockUSDC} from "../../../src/mocks/interfaces/IMockUSDC.sol";
import {DataOracle} from "../../../src/oracle/DataOracle.sol";
import {Executor} from "../../../src/positions/Executor.sol";
import {Liquidator} from "../../../src/positions/Liquidator.sol";
import {RequestRouter} from "../../../src/positions/RequestRouter.sol";
import {TradeStorage} from "../../../src/positions/TradeStorage.sol";
import {TradeVault} from "../../../src/positions/TradeVault.sol";
import {WUSDC} from "../../../src/token/WUSDC.sol";
import {Roles} from "../../../src/access/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Market} from "../../../src/markets/Market.sol";

contract TestMarketFactory is Test {
    RoleStorage roleStorage;
    GlobalMarketConfig globalMarketConfig;
    LiquidityVault liquidityVault;
    MarketFactory marketFactory;
    MarketStorage marketStorage;
    MarketToken marketToken;
    StateUpdater stateUpdater;
    IMockPriceOracle priceOracle;
    IMockUSDC usdc;
    DataOracle dataOracle;
    Executor executor;
    Liquidator liquidator;
    RequestRouter requestRouter;
    TradeStorage tradeStorage;
    TradeVault tradeVault;
    WUSDC wusdc;

    address public OWNER;
    address public USER = makeAddr("user");

    uint256 public constant LARGE_AMOUNT = 1e30;
    uint256 public constant CONVERSION_RATE = 1e12;

    function setUp() public {
        DeployV2 deploy = new DeployV2();
        DeployV2.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;
        globalMarketConfig = contracts.globalMarketConfig;
        liquidityVault = contracts.liquidityVault;
        marketFactory = contracts.marketFactory;
        marketStorage = contracts.marketStorage;
        marketToken = contracts.marketToken;
        stateUpdater = contracts.stateUpdater;
        priceOracle = contracts.priceOracle;
        usdc = contracts.usdc;
        dataOracle = contracts.dataOracle;
        executor = contracts.executor;
        liquidator = contracts.liquidator;
        requestRouter = contracts.requestRouter;
        tradeStorage = contracts.tradeStorage;
        tradeVault = contracts.tradeVault;
        wusdc = contracts.wusdc;
        OWNER = contracts.owner;
    }

    modifier mintUsdc() {
        usdc.mint(OWNER, LARGE_AMOUNT);
        usdc.mint(USER, LARGE_AMOUNT);
        _;
    }

    function testMarketFactoryLetsUsCreateNewMarkets() public {
        IERC20 indexToken = IERC20(makeAddr("indexToken"));
        address priceFeed = makeAddr("priceFeed");
        marketFactory.createMarket(address(indexToken), priceFeed, 1e18);

        // Get the market info
        bytes32 marketKey = keccak256(abi.encodePacked(address(indexToken)));
        (, address marketAddress,) = marketStorage.markets(marketKey);
        assertNotEq(address(0), marketAddress);

        // Check the market has the correct values
        Market market = Market(marketAddress);
        assertEq(address(indexToken), market.indexToken());
        assertEq(address(marketStorage), address(market.marketStorage()));
        assertEq(address(liquidityVault), address(market.liquidityVault()));
        assertEq(address(tradeStorage), address(market.tradeStorage()));
        assertEq(address(priceOracle), address(market.priceOracle()));
        assertEq(address(wusdc), address(market.WUSDC()));
        assertEq(address(roleStorage), address(market.roleStorage()));
        assertEq(0.0003e18, market.maxFundingVelocity());
        assertEq(1_000_000e18, market.skewScale());
        assertEq(500e16, market.maxFundingRate());
        assertEq(-500e16, market.minFundingRate());
        assertEq(0.000000035e18, market.borrowingFactor());
        assertEq(1, market.borrowingExponent());
        assertEq(false, market.feeForSmallerSide());
        assertEq(0.0000001e18, market.priceImpactFactor());
        assertEq(2, market.priceImpactExponent());
    }
}
