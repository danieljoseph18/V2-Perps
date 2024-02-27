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
import {Deposit} from "../../../src/liquidity/Deposit.sol";
import {Withdrawal} from "../../../src/liquidity/Withdrawal.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {Pool} from "../../../src/liquidity/Pool.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Fee} from "../../../src/libraries/Fee.sol";
import {Position} from "../../../src/positions/Position.sol";
import {Market, IMarket} from "../../../src/markets/Market.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";

contract TestPriceImpact is Test {
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
            name: "WETH/USDC",
            symbol: "WETH/USDC",
            priceFeed: address(priceFeed),
            processor: address(processor),
            minTimeToExpiration: 1 minutes,
            feeScale: 0.03e18
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
     * Actual Impacted Price PRB Math: 2551.072469825497887958
     * Expected Impacted Price:        2551.072469825497887958
     * Delta: 0
     *
     * Actual Price Impact PRB Math: -200008000080000000000
     * Expected Price Impact: -200008000080000000000
     * Delta: 0
     */
    function testNegativePriceImpactValues() public setUpMarkets {
        // create a position
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
        vm.prank(OWNER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
        // Fetch request
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Position.Request memory request = tradeStorage.getOrder(orderKey);
        // Test negative price impact values

        (uint256 impactedPrice, int256 priceImpactUsd) = PriceImpact.execute(market, request, 2500.05e18, 1e18);
        uint256 expectedImpactPrice = 2551072469825497887958;
        int256 expectedPriceImpactUsd = -200008000080000000000;
        assertEq(impactedPrice, expectedImpactPrice);
        assertEq(priceImpactUsd, expectedPriceImpactUsd);
    }

    /**
     * Actual ImpactedPrice PRB Math: 2174291105449423058528
     * Expected Impacted Price:       2174291105449423058528
     *
     * Actual Price Impact PRB Math: 7503000300000000000000
     * Expected Price Impact:        7503000300000000000000
     */
    function testPositivePriceImpactValues() public setUpMarkets {
        // create a position
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 5 ether,
            sizeDelta: 40 ether, // $100,000
            limitPrice: 0,
            maxSlippage: 0.99e18,
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
        router.createPositionRequest{value: 5.01 ether}(input, tokenUpdateData);
        // Fetch request
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        // create a position
        input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 1000e6, // $1000
            sizeDelta: 20 ether, // $50,000 - 50x leverage
            limitPrice: 0,
            maxSlippage: 0.01e18,
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
        // Fetch request
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        Position.Request memory request = tradeStorage.getOrder(orderKey);
        // Test positive price impact values

        uint256 impactPool = market.getImpactPool(weth);
        console.log("Impact Pool: ", impactPool);
        (uint256 impactedPrice, int256 priceImpactUsd) = PriceImpact.execute(market, request, 2500.5e18, 1e18);
        int256 expectedPriceImpactUsd = 7503000300000000000000;
        assertEq(priceImpactUsd, expectedPriceImpactUsd);
        uint256 expectedImpactedPrice = 2174291105449423058528;
        assertEq(impactedPrice, expectedImpactedPrice);
    }

    /**
     * Expected Impact Usd: -2501.0001e18
     * Expected Impacted Price: 2564.628536556597726142
     */
    function testPriceImpactForSkewFlip() public setUpMarkets {
        // create a position
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 1000e6, // $1000
            sizeDelta: 20 ether, // $50,000 - 50x leverage
            limitPrice: 0,
            maxSlippage: 0.99e18,
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
        // Fetch request
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        // new pos
        input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 5 ether,
            sizeDelta: 40 ether, // $100,000
            limitPrice: 0,
            maxSlippage: 0.99e18,
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
        router.createPositionRequest{value: 5.01 ether}(input, tokenUpdateData);
        // Fetch request
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        Position.Request memory request = tradeStorage.getOrder(orderKey);
        // Test skew flip price impact values

        (uint256 impactedPrice, int256 priceImpactUsd) = PriceImpact.execute(market, request, 2500.5e18, 1e18);
        int256 expectedPriceImpactUsd = -2501.0001e18;
        assertEq(priceImpactUsd, expectedPriceImpactUsd);
        uint256 expectedImpactedPrice = 2564628536556597726142;
        assertEq(impactedPrice, expectedImpactedPrice);
    }
}
