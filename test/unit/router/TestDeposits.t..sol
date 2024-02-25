// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
import {LiquidityVault} from "../../../src/liquidity/LiquidityVault.sol";
import {MarketMaker} from "../../../src/markets/MarketMaker.sol";
import {StateUpdater} from "../../../src/markets/StateUpdater.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage} from "../../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {Processor} from "../../../src/router/Processor.sol";
import {Router} from "../../../src/router/Router.sol";
import {Deposit} from "../../../src/liquidity/Deposit.sol";
import {Withdrawal} from "../../../src/liquidity/Withdrawal.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {Pool} from "../../../src/liquidity/Pool.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Fee} from "../../../src/libraries/Fee.sol";

contract TestDeposits is Test {
    RoleStorage roleStorage;
    GlobalMarketConfig globalMarketConfig;
    LiquidityVault liquidityVault;
    MarketMaker marketMaker;
    StateUpdater stateUpdater;
    IPriceFeed priceFeed; // Deployed in Helper Config
    TradeStorage tradeStorage;
    ReferralStorage referralStorage;
    Processor processor;
    Router router;
    address OWNER;

    address weth;
    address usdc;
    bytes32 ethPriceId;
    bytes32 usdcPriceId;

    bytes[] tokenUpdateData;

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;
        globalMarketConfig = contracts.globalMarketConfig;
        liquidityVault = contracts.liquidityVault;
        marketMaker = contracts.marketMaker;
        stateUpdater = contracts.stateUpdater;
        priceFeed = contracts.priceFeed;
        tradeStorage = contracts.tradeStorage;
        referralStorage = contracts.referralStorage;
        processor = contracts.processor;
        router = contracts.router;
        OWNER = contracts.owner;
        ethPriceId = deploy.ethPriceId();
        usdcPriceId = deploy.usdcPriceId();
        weth = deploy.weth();
        usdc = deploy.usdc();
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // Set Update Data
        bytes memory wethUpdateData = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 250000, 50, -2, 250000, 50, uint64(block.timestamp), uint64(block.timestamp)
        );
        bytes memory usdcUpdateData = priceFeed.createPriceFeedUpdateData(
            usdcPriceId, 1, 0, 0, 1, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        tokenUpdateData.push(wethUpdateData);
        tokenUpdateData.push(usdcUpdateData);
    }

    receive() external payable {}

    modifier setUpMarkets() {
        vm.deal(OWNER, 1_000_000 ether);
        MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);
        vm.startPrank(OWNER);
        WETH(weth).deposit{value: 50 ether}();
        Oracle.Asset memory wethData = Oracle.Asset({
            isValid: true,
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            priceSpread: 0.1e18,
            priceProvider: Oracle.PriceProvider.PYTH,
            assetType: Oracle.AssetType.CRYPTO,
            pool: Oracle.UniswapPool({
                token0: weth,
                token1: usdc,
                poolAddress: address(0),
                poolType: Oracle.PoolType.UNISWAP_V3
            })
        });
        marketMaker.createNewMarket(weth, ethPriceId, wethData);
        vm.stopPrank();
        _;
    }

    function testCreatingADepositRequest() public setUpMarkets {
        // Construct the deposit input
        Deposit.Input memory input = Deposit.Input({
            owner: OWNER,
            tokenIn: weth,
            amountIn: 0.5 ether,
            executionFee: 0.01 ether,
            shouldWrap: true
        });
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
    }

    function testExecutingADepositRequest() public setUpMarkets {
        // Construct the deposit input
        Deposit.Input memory input = Deposit.Input({
            owner: OWNER,
            tokenIn: weth,
            amountIn: 0.5 ether,
            executionFee: 0.01 ether,
            shouldWrap: true
        });
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
        // Call the execute deposit function with sufficient gas
        bytes32 depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit(depositKey, 0);
    }

    function testDepositWithTinyAmountIn() public setUpMarkets {
        // Construct the deposit input
        Deposit.Input memory input =
            Deposit.Input({owner: OWNER, tokenIn: weth, amountIn: 1 wei, executionFee: 0.01 ether, shouldWrap: true});
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        bytes32 depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        vm.expectRevert();
        processor.executeDeposit(depositKey, 0);
    }

    function testDepositWithTheMinimumAmountIn() public setUpMarkets {
        // Construct the deposit input
        Deposit.Input memory input =
            Deposit.Input({owner: OWNER, tokenIn: weth, amountIn: 1000 wei, executionFee: 0.01 ether, shouldWrap: true});
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        bytes32 depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit(depositKey, 0);
    }

    // Expected Amount = 2.4970005e+25 (base fee + price spread)
    // Received Amount = 2.4970005e+25
    function testDepositWithHugeAmount() public setUpMarkets {
        // Construct the deposit input
        Deposit.Input memory input = Deposit.Input({
            owner: OWNER,
            tokenIn: weth,
            amountIn: 10_000 ether,
            executionFee: 0.01 ether,
            shouldWrap: true
        });
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 10_000.01 ether + 1 gwei}(input, tokenUpdateData);
        bytes32 depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        uint256 balanceBefore = liquidityVault.balanceOf(OWNER);
        vm.prank(OWNER);
        processor.executeDeposit(depositKey, 0);
        uint256 balanceAfter = liquidityVault.balanceOf(OWNER);
        assertGt(balanceAfter, balanceBefore);
    }

    // @audit - Fee values correct?
    function testDynamicFeesOnImbalancedDeposits() public setUpMarkets {
        // Construct the deposit input
        Deposit.Input memory input =
            Deposit.Input({owner: OWNER, tokenIn: weth, amountIn: 1 ether, executionFee: 0.01 ether, shouldWrap: true});
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 1.01 ether + 1 gwei}(input, tokenUpdateData);
        bytes32 depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit(depositKey, 0);
        uint256 balanceBefore = liquidityVault.balanceOf(OWNER);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Calculate the expected amount out
        (Oracle.Price memory longPrices, Oracle.Price memory shortPrices) =
            Oracle.getMarketTokenPrices(priceFeed, priceFeed.lastUpdateBlock());
        Pool.Values memory values = Pool.Values({
            longTokenBalance: liquidityVault.longTokenBalance(),
            shortTokenBalance: liquidityVault.shortTokenBalance(),
            marketTokenSupply: liquidityVault.totalSupply(),
            longBaseUnit: 1e18,
            shortBaseUnit: 1e6
        });
        console.log("LTB: ", liquidityVault.longTokenBalance());
        console.log("STB: ", liquidityVault.shortTokenBalance());
        console.log("MTS: ", liquidityVault.totalSupply());
        Fee.Params memory feeParams =
            Fee.constructFeeParams(liquidityVault, 50000e6, false, values, longPrices, shortPrices, true);
        uint256 expectedFee = Fee.calculateForMarketAction(feeParams);
        console.log("Expected Fee: ", expectedFee);
        uint256 amountMinusFee = 50_000e6 - expectedFee;
        console.log("Amount Minus Fee: ", amountMinusFee);
        uint256 expectedAmountOut =
            Pool.depositTokensToMarketTokens(values, longPrices, shortPrices, amountMinusFee, 0, false);
        console.log("Expected Amount: ", expectedAmountOut);

        // Construct the deposit input
        input = Deposit.Input({
            owner: OWNER,
            tokenIn: usdc,
            amountIn: 50_000e6,
            executionFee: 0.01 ether,
            shouldWrap: false
        });
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        processor.executeDeposit(depositKey, 0);
        vm.stopPrank();
        uint256 balanceAfter = liquidityVault.balanceOf(OWNER);
        console.log("Actual Amount Out: ", balanceAfter - balanceBefore);
    }

    // Bonus Fee = 0.0003995201959207653 (0.04%)
    function testDynamicFeesOnGiganticImbalancedDeposits() public setUpMarkets {
        // Construct the deposit input
        Deposit.Input memory input =
            Deposit.Input({owner: OWNER, tokenIn: weth, amountIn: 1 ether, executionFee: 0.01 ether, shouldWrap: true});
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 1.01 ether + 1 gwei}(input, tokenUpdateData);
        bytes32 depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit(depositKey, 0);
        uint256 balanceBefore = liquidityVault.balanceOf(OWNER);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Construct the deposit input
        input = Deposit.Input({
            owner: OWNER,
            tokenIn: usdc,
            amountIn: 50_000_000e6,
            executionFee: 0.01 ether,
            shouldWrap: false
        });
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        processor.executeDeposit(depositKey, 0);
        vm.stopPrank();
        uint256 amountReceived = liquidityVault.balanceOf(OWNER) - balanceBefore;
        console.log("Actual Amount Out: ", amountReceived);
        // Get the value of market tokens
        (Oracle.Price memory longPrices, Oracle.Price memory shortPrices) =
            Oracle.getMarketTokenPrices(priceFeed, priceFeed.lastUpdateBlock());
        uint256 marketTokenPrice = Pool.getMarketTokenPrice(
            Pool.Values({
                longTokenBalance: liquidityVault.longTokenBalance(),
                shortTokenBalance: liquidityVault.shortTokenBalance(),
                marketTokenSupply: liquidityVault.totalSupply(),
                longBaseUnit: 1e18,
                shortBaseUnit: 1e6
            }),
            longPrices.price + longPrices.confidence,
            shortPrices.price + shortPrices.confidence,
            0
        );
        uint256 valueReceived = (amountReceived * marketTokenPrice) / 1e18;
        console.log("Value Received: ", valueReceived);
    }

    function testCreateDepositWithWethNoWrap() public setUpMarkets {
        // Construct the deposit input
        Deposit.Input memory input =
            Deposit.Input({owner: OWNER, tokenIn: weth, amountIn: 1 ether, executionFee: 0.01 ether, shouldWrap: false});
        // Call the deposit function with sufficient gas
        vm.startPrank(OWNER);
        WETH(weth).approve(address(router), type(uint256).max);
        router.createDeposit{value: 1.01 ether + 1 gwei}(input, tokenUpdateData);
        bytes32 depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        processor.executeDeposit(depositKey, 0);
        vm.stopPrank();
    }
}
