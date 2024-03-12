// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
import {MarketMaker, IMarketMaker} from "../../../src/markets/MarketMaker.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage} from "../../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {Processor} from "../../../src/router/Processor.sol";
import {Router} from "../../../src/router/Router.sol";
import {Deposit} from "../../../src/markets/Deposit.sol";
import {Withdrawal} from "../../../src/markets/Withdrawal.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {Pool} from "../../../src/markets/Pool.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Fee} from "../../../src/libraries/Fee.sol";
import {Position} from "../../../src/positions/Position.sol";
import {Market, IMarket} from "../../../src/markets/Market.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";

contract TestFunding is Test {
    RoleStorage roleStorage;
    GlobalMarketConfig globalMarketConfig;
    MarketMaker marketMaker;
    IPriceFeed priceFeed; // Deployed in Helper Config
    TradeStorage tradeStorage;
    ReferralStorage referralStorage;
    Processor processor;
    Router router;
    address OWNER;
    Market market;

    address weth;
    address usdc;
    bytes32 ethPriceId;
    bytes32 usdcPriceId;

    bytes[] tokenUpdateData;
    uint256[] allocations;

    address USER = makeAddr("USER");

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;
        globalMarketConfig = contracts.globalMarketConfig;
        marketMaker = contracts.marketMaker;
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
            assetType: Oracle.AssetType.CRYPTO,
            pool: Oracle.UniswapPool({
                token0: weth,
                token1: usdc,
                poolAddress: address(0),
                poolType: Oracle.PoolType.UNISWAP_V3
            })
        });
        Pool.VaultConfig memory wethVaultDetails = Pool.VaultConfig({
            longToken: weth,
            shortToken: usdc,
            longBaseUnit: 1e18,
            shortBaseUnit: 1e6,
            feeScale: 0.03e18,
            feePercentageToOwner: 0.2e18,
            minTimeToExpiration: 1 minutes,
            priceFeed: address(priceFeed),
            processor: address(processor),
            poolOwner: OWNER,
            feeDistributor: OWNER,
            name: "WETH/USDC",
            symbol: "WETH/USDC"
        });
        marketMaker.createNewMarket(wethVaultDetails, weth, ethPriceId, wethData);
        vm.stopPrank();
        address wethMarket = marketMaker.tokenToMarkets(weth);
        market = Market(payable(wethMarket));
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
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, input, tokenUpdateData);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit(market, depositKey, 0);

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
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, input, tokenUpdateData);
        depositKey = market.getDepositRequestAtIndex(0).key;
        processor.executeDeposit(market, depositKey, 0);
        vm.stopPrank();
        vm.startPrank(OWNER);
        uint256 allocation = 10000;
        uint256 encodedAllocation = allocation << 240;
        allocations.push(encodedAllocation);
        market.setAllocationsWithBits(allocations);
        assertEq(market.getAllocation(weth), 10000);
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
     * skewScale: 1_000_000e18 // 1 Mil USD
     */
    function testVelocityCalculationForDifferentSkews() public setUpMarkets {
        // Different Skews
        int256 heavyLong = 500_000e30;
        int256 heavyShort = -500_000e30;
        int256 balancedLong = 1000e30;
        int256 balancedShort = -1000e30;
        // Calculate Heavy Long Velocity
        int256 heavyLongVelocity = Funding.getCurrentVelocity(market, weth, heavyLong);
        /**
         * proportional skew = $500,000 / $1,000,000 = 0.5
         * bounded skew = 0.5
         * velocity = 0.5 / 0.0003 = 1666.66 (rec)
         */
        int256 expectedHeavyLongVelocity = 0.00015e18;
        assertEq(heavyLongVelocity, expectedHeavyLongVelocity);
        // Calculate Heavy Short Velocity
        int256 heavyShortVelocity = Funding.getCurrentVelocity(market, weth, heavyShort);
        int256 expectedHeavyShortVelocity = -0.00015e18;
        assertEq(heavyShortVelocity, expectedHeavyShortVelocity);
        // Calculate Balanced Long Velocity
        int256 balancedLongVelocity = Funding.getCurrentVelocity(market, weth, balancedLong);
        int256 expectedBalancedLongVelocity = 0.0000003e18;
        assertEq(balancedLongVelocity, expectedBalancedLongVelocity);
        // Calculate Balanced Short Velocity
        int256 balancedShortVelocity = Funding.getCurrentVelocity(market, weth, balancedShort);
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
        processor.executePosition(orderKey, OWNER, tradingEnabled, tokenUpdateData, weth, 0);

        int256 skew = Funding.calculateSkewUsd(market, weth);
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
        processor.executePosition(orderKey, OWNER, tradingEnabled, tokenUpdateData, weth, 0);

        skew = Funding.calculateSkewUsd(market, weth);
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
        processor.executePosition(orderKey, OWNER, tradingEnabled, tokenUpdateData, weth, 0);

        skew = Funding.calculateSkewUsd(market, weth);
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
        processor.executePosition(orderKey, OWNER, tradingEnabled, tokenUpdateData, weth, 0);

        skew = Funding.calculateSkewUsd(market, weth);
        assertEq(skew, -50_000e18);
    }
}
