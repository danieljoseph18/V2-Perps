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
import {Order} from "../../../src/positions/Order.sol";

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

    modifier setUpMarketsDeepLiquidity() {
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

    modifier setUpMarketsShallowLiquidity() {
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
            amountIn: 100 ether,
            executionFee: 0.01 ether,
            shouldWrap: true
        });
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 100.01 ether + 1 gwei}(market, input, tokenUpdateData);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit(market, depositKey, 0);

        // Construct the deposit input
        input = Deposit.Input({
            owner: OWNER,
            tokenIn: usdc,
            amountIn: 250_000e6,
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
    function testPriceImpactValuesDeepLiquidity(uint256 _sizeDelta, uint256 _longOi, uint256 _shortOi)
        public
        setUpMarketsDeepLiquidity
    {
        // bound the inputs to realistic values
        _sizeDelta = bound(_sizeDelta, 1 ether, 50 ether);
        _longOi = bound(_longOi, 0, 10000 ether);
        _shortOi = bound(_shortOi, 0, 10000 ether);

        Position.Request memory request = Position.Request({
            input: Position.Input({
                indexToken: weth,
                collateralToken: weth,
                collateralDelta: 0.5 ether,
                sizeDelta: _sizeDelta,
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
            }),
            market: address(market),
            user: USER,
            requestBlock: block.number,
            requestType: Position.RequestType.POSITION_INCREASE
        });
        // Test negative price impact values

        Order.ExecutionState memory orderState = Order.ExecutionState({
            market: market,
            indexPrice: 2500e18,
            indexBaseUnit: 1e18,
            impactedPrice: 2500.05e18,
            longMarketTokenPrice: 2500e18,
            shortMarketTokenPrice: 1e18,
            sizeDeltaUsd: 0,
            collateralDeltaUsd: 0,
            priceImpactUsd: 0,
            collateralPrice: 1e18,
            collateralBaseUnit: 1e6,
            fee: 0,
            feeDiscount: 0,
            referrer: address(0)
        });

        // Mock call open interest values
        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getOpenInterest.selector, weth, true), abi.encode(_longOi)
        );

        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getOpenInterest.selector, weth, false), abi.encode(_shortOi)
        );

        (orderState.impactedPrice, orderState.priceImpactUsd) =
            PriceImpact.execute(market, priceFeed, request, orderState);
    }

    function testPriceImpactValuesShallowLiquidity(uint256 _sizeDelta, uint256 _longOi, uint256 _shortOi)
        public
        setUpMarketsShallowLiquidity
    {
        // bound the inputs to realistic values
        _sizeDelta = bound(_sizeDelta, 1 ether, 50 ether);
        _longOi = bound(_longOi, 0, 10000 ether);
        _shortOi = bound(_shortOi, 0, 10000 ether);

        Position.Request memory request = Position.Request({
            input: Position.Input({
                indexToken: weth,
                collateralToken: weth,
                collateralDelta: 0.5 ether,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 1e18,
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
            }),
            market: address(market),
            user: USER,
            requestBlock: block.number,
            requestType: Position.RequestType.POSITION_INCREASE
        });
        // Test negative price impact values

        Order.ExecutionState memory orderState = Order.ExecutionState({
            market: market,
            indexPrice: 2500e18,
            indexBaseUnit: 1e18,
            impactedPrice: 2500.05e18,
            longMarketTokenPrice: 2500e18,
            shortMarketTokenPrice: 1e18,
            sizeDeltaUsd: 0,
            collateralDeltaUsd: 0,
            priceImpactUsd: 0,
            collateralPrice: 1e18,
            collateralBaseUnit: 1e6,
            fee: 0,
            feeDiscount: 0,
            referrer: address(0)
        });

        // Mock call open interest values
        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getOpenInterest.selector, weth, true), abi.encode(_longOi)
        );

        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getOpenInterest.selector, weth, false), abi.encode(_shortOi)
        );

        (orderState.impactedPrice, orderState.priceImpactUsd) =
            PriceImpact.execute(market, priceFeed, request, orderState);
    }
}
