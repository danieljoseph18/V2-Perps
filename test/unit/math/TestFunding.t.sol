// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2} from "forge-std/Test.sol";
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
import {Position} from "../../../src/positions/Position.sol";
import {IMarket} from "../../../src/markets/interfaces/IMarket.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";

contract TestFunding is Test {
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
    uint256[] allocations;

    address USER = makeAddr("USER");

    function setUp() public {
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
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
        vm.deal(USER, 1_000_000 ether);
        MockUSDC(usdc).mint(USER, 1_000_000_000e6);
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
            assetType: Oracle.AssetType.CRYPTO
        });
        marketMaker.createNewMarket(weth, ethPriceId, wethData);
        vm.stopPrank();
        // Construct the deposit input
        Deposit.Input memory input = Deposit.Input({
            owner: OWNER,
            tokenIn: weth,
            amountIn: 20_000 ether,
            executionFee: 0.01 ether,
            shouldWrap: true
        });
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(input, tokenUpdateData);
        bytes32 depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit(depositKey, 0);

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
        vm.startPrank(OWNER);
        address wethMarket = marketMaker.tokenToMarkets(weth);
        stateUpdater.syncMarkets();
        uint256 allocation = 10000;
        uint256 encodedAllocation = allocation << 240;
        allocations.push(encodedAllocation);
        stateUpdater.setAllocationsWithBits(allocations);
        assertEq(IMarket(wethMarket).percentageAllocation(), 10000);
        vm.stopPrank();
        _;
    }

    /**
     * Need To Test:
     * - Velocity Calculation
     * - Calculation of Accumulated Fees for Market
     * - Calculation of Accumulated Fees for Position
     * - Calculation of Funding Rate
     * - Calculation of Fees Since Update
     */

    /**
     * Config:
     * maxVelocity: 0.0003e18, // 0.03%
     * maxRate: 0.03e18, // 3%
     * minRate: -0.03e18, // -3%
     * skewScale: 1_000_000e18 // 1 Mil USD
     */
    function testVelocityCalculationForDifferentSkews() public setUpMarkets {
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));
        // Different Skews
        int256 heavyLong = 500_000e18;
        int256 heavyShort = -500_000e18;
        int256 balancedLong = 1000e18;
        int256 balancedShort = -1000e18;
        // Calculate Heavy Long Velocity
        int256 heavyLongVelocity = Funding.calculateVelocity(market, heavyLong);
        int256 expectedHeavyLongVelocity = 0.00015e18;
        assertEq(heavyLongVelocity, expectedHeavyLongVelocity);
        // Calculate Heavy Short Velocity
        int256 heavyShortVelocity = Funding.calculateVelocity(market, heavyShort);
        int256 expectedHeavyShortVelocity = -0.00015e18;
        assertEq(heavyShortVelocity, expectedHeavyShortVelocity);
        // Calculate Balanced Long Velocity
        int256 balancedLongVelocity = Funding.calculateVelocity(market, balancedLong);
        int256 expectedBalancedLongVelocity = 0.0000003e18;
        assertEq(balancedLongVelocity, expectedBalancedLongVelocity);
        // Calculate Balanced Short Velocity
        int256 balancedShortVelocity = Funding.calculateVelocity(market, balancedShort);
        int256 expectedBalancedShortVelocity = -0.0000003e18;
        assertEq(balancedShortVelocity, expectedBalancedShortVelocity);
    }

    function testSkewCalculationForDifferentSkews() public setUpMarkets {
        // open and execute a long to skew it long
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
        // Execute the Position
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});

        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));
        int256 skew = Funding.calculateSkewUsd(market, 2500e18, 1e18);
        assertEq(skew, 10_000e18);

        // open and execute a short to skew it short
        input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 2000e6,
            sizeDelta: 8 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(USER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
        // Execute the Position
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        skew = Funding.calculateSkewUsd(market, 2500e18, 1e18);
        assertEq(skew, -10_000e18);

        // open and execute a long to balance it
        input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
        // Execute the Position
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        skew = Funding.calculateSkewUsd(market, 2500e18, 1e18);
        assertEq(skew, 0);

        // open and execute a short to heavily skew
        input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 10_000e6,
            sizeDelta: 20 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 0.01 ether}(input, tokenUpdateData);
        // Execute the Position
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        skew = Funding.calculateSkewUsd(market, 2500e18, 1e18);
        assertEq(skew, -50_000e18);
    }

    /**
     * Velocity: 3000600000000
     */
    function testCalculationOfNonUpdatedFeesWithSkewLong() public setUpMarkets {
        // Open a position to skew the funding long

        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);

        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});

        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        // Pass some time
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));
        vm.warp(block.timestamp + 100 seconds);
        vm.roll(block.number + 1);
        // get the fees since update and compare with expected values
        (uint256 feesEarned, uint256 feesOwed) = Funding.getFeesSinceLastMarketUpdate(market, true);
        assertEq(feesEarned, 0);
        assertEq(feesOwed, 14852970000000000);
    }

    /**
     * Velocity: -5998800000000
     */
    function testCalculationOfNonUpdatedFeesWithSkewShort() public setUpMarkets {
        // Open a position to skew the funding short
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 2000e6,
            sizeDelta: 8 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(USER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});

        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));

        // Pass some time
        vm.warp(block.timestamp + 100 seconds);
        vm.roll(block.number + 1);
        // get the fees since update and compare with expected values
        (uint256 feesEarned, uint256 feesOwed) = Funding.getFeesSinceLastMarketUpdate(market, false);
        assertEq(feesEarned, 0);
        assertEq(feesOwed, 29694060000000000);
    }

    /**
     * Velocity: 3000600000000
     * maxRate: 0.03e18, // 3%
     */
    function testCalculationOfNonUpdatedFeesWithBoundaryCrossLong() public setUpMarkets {
        // Open a position to skew the funding long

        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);

        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});

        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        // Pass enough time to get to the boundary
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // get the fees since update and compare with expected values
        (uint256 feesEarned, uint256 feesOwed) = Funding.getFeesSinceLastMarketUpdate(market, true);
        assertEq(feesEarned, 0);
        assertEq(feesOwed, 2.4420149940006e21);
    }

    /**
     * function calculateSeriesSum(n,a,d){
     *         return ((n/2) * ((2*a) + ((n - 1) * d)));
     *     }
     */

    /**
     * Velocity: -5998800000000
     * minRate: -0.03e18, // 3%
     */
    function testCalculationOfNonUpdatedFeesWithBoundaryCrossShort() public setUpMarkets {
        // Open a position to skew the funding short
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 2000e6,
            sizeDelta: 8 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(USER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});

        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));

        // Pass enough time
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // get the fees since update and compare with expected values
        (uint256 feesEarned, uint256 feesOwed) = Funding.getFeesSinceLastMarketUpdate(market, false);
        assertEq(feesEarned, 0);
        assertEq(feesOwed, 2.5169699969988e21);
    }

    function testCalculationOfNonUpdatedFeesWhenAlreadyAtLongBoundary() public setUpMarkets {
        // Open a position to skew the funding long

        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);

        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});

        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        // Pass enough time
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // Update the market's funding rate
        vm.prank(address(processor));
        market.updateFundingRate(2500e18, 1e18);

        // Pass some time
        vm.warp(block.timestamp + 100 seconds);
        vm.roll(block.number + 1);

        // get the fees since update and compare with expected values
        (uint256 feesEarned, uint256 feesOwed) = Funding.getFeesSinceLastMarketUpdate(market, true);
        assertEq(feesEarned, 0);
        assertEq(feesOwed, 3000000000000000000);
    }

    function testCalculationOfNonUpdatedFeesWhenAlreadyAtShortBoundary() public setUpMarkets {
        // Open a position to skew the funding short
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 2000e6,
            sizeDelta: 8 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(USER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});

        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));

        // Pass enough time to reach boundary
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Update the market's funding rate
        vm.prank(address(processor));
        market.updateFundingRate(2500e18, 1e18);

        // Pass some time
        vm.warp(block.timestamp + 100 seconds);
        vm.roll(block.number + 1);

        // get the fees since update and compare with expected values
        (uint256 feesEarned, uint256 feesOwed) = Funding.getFeesSinceLastMarketUpdate(market, false);
        assertEq(feesEarned, 0);
        assertEq(feesOwed, 3000000000000000000);
    }

    /**
     * Rate: 300060000000000
     * Velocity: -2999400000000
     * Funding Until Flip: 15159090000000000
     * Funding After Flip: -14835150000000000
     */
    function testCalculationOfNonUpdatedFeesWithSignFlipLongToShort() public setUpMarkets {
        // Open a position to skew the funding long
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);

        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});

        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        // Pass enough time
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));
        vm.warp(block.timestamp + 100);
        vm.roll(block.number + 1);

        // Open a short position to flip the sign
        input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 2000e6,
            sizeDelta: 8 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(USER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        // Pass some time
        vm.warp(block.timestamp + 200 seconds);
        vm.roll(block.number + 1);

        // get the fees since update and compare with expected values
        (uint256 feesEarned, uint256 feesOwed) = Funding.getFeesSinceLastMarketUpdate(market, false);
        assertEq(feesEarned, 15159090000000000);
        assertEq(feesOwed, 14835150000000000);
    }

    /**
     * Funding Rate: 300060000000000
     * Velocity: -2999400000000
     */
    function testCalculationOfNonUpdatedFeesWithSignFlipAndBoundaryCross() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);

        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});

        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        // Pass enough time
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));
        vm.warp(block.timestamp + 100);
        vm.roll(block.number + 1);

        // Open a short position to flip the sign
        input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 2000e6,
            sizeDelta: 8 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(USER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        int256 fundingRate = market.fundingRate();
        int256 fundingVelocity = market.fundingRateVelocity();

        console2.log("Funding Rate: ", fundingRate);
        console2.log("Funding Velocity: ", fundingVelocity);

        // Pass enough time for boundary cross
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // get the fees since update and compare with expected values
        (uint256 feesEarned, uint256 feesOwed) = Funding.getFeesSinceLastMarketUpdate(market, false);
        /**
         * fundingUntilFlip: 15159090000000000
         * fundingUntilBoundary: 150043793758200000000
         * fundingAfterBoundary: 2.28891e+21
         */
        assertEq(feesEarned, 15159090000000000);
        assertEq(feesOwed, 2.4389537937582e21);
    }
}
