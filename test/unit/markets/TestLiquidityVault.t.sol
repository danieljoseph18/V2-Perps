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

contract TestDeployment is Test {
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

    modifier mintUsdc(address _to) {
        usdc.mint(_to, LARGE_AMOUNT);
        _;
    }

    /**
     * ================ Adding Liquidity ================
     */

    /**
     * Invariants:
     * - Liquidity should be wrapped to WUSDC from USDC
     * - Can't be reentrancy attacked
     * - Can't add more liquidity than I own
     * - Can't add liquidity for another account without permission
     * - Fee is charged correctly
     * - Liquidity is minted correctly
     * - Liquidity is added to the vault
     * - Fees are accumulated in the right place
     */

    //     Logs:
    //   Error: a == b not satisfied [uint]
    //         Left: 0
    //        Right: 999999999999999999999900000000
    //   Error: a > b not satisfied [uint]
    //     Value a: 0
    //     Value b: 0

    function testLiqVaultAddLiquidityWorks() public mintUsdc(OWNER) {
        vm.startPrank(OWNER);
        usdc.approve(address(liquidityVault), LARGE_AMOUNT);
        liquidityVault.addLiquidity(100e6);
        assertEq(liquidityVault.poolAmounts(), 100e6 * CONVERSION_RATE);
        assertEq(usdc.balanceOf(OWNER), LARGE_AMOUNT - 100e6);
        assertGt(marketToken.balanceOf(OWNER), 0);
        assertGt(liquidityVault.accumulatedFees(), 0);
        vm.stopPrank();
    }

    function testLiqVaultLpTokenPriceAfterAddingLiquidity() public mintUsdc(OWNER) {
        vm.startPrank(OWNER);
        usdc.approve(address(liquidityVault), LARGE_AMOUNT);
        liquidityVault.addLiquidity(100e6);
        vm.stopPrank();
        console.log(liquidityVault.getLiquidityTokenPrice());
    }

    function testLiqVaultRemoveLiquidityWorks() public mintUsdc(OWNER) {
        vm.startPrank(OWNER);
        usdc.approve(address(liquidityVault), LARGE_AMOUNT);
        liquidityVault.addLiquidity(100e6);
        uint256 mintAmount = marketToken.balanceOf(OWNER);
        uint256 usdcBalBefore = usdc.balanceOf(OWNER);

        marketToken.approve(address(liquidityVault), mintAmount);
        liquidityVault.removeLiquidity(mintAmount);

        assertGt(usdc.balanceOf(OWNER), usdcBalBefore);
        assertEq(marketToken.balanceOf(OWNER), 0);
        vm.stopPrank();
    }
}
