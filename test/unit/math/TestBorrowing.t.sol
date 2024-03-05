// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
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
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {Order} from "../../../src/positions/Order.sol";

contract TestBorrowing is Test {
    using stdStorage for StdStorage;

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
     * Config:
     * - Factor: 0.000000035e18 or 0.0000035% per second
     * - Exponent: 1
     */
    function testCalculateBorrowFeesSinceUpdateForDifferentDistances(uint256 _distance) public {
        _distance = bound(_distance, 1, 3650000 days); // 10000 years
        uint256 rate = 0.000000035e18;
        vm.warp(block.timestamp + _distance);
        vm.roll(block.number + 1);
        uint256 lastUpdate = block.timestamp - _distance;
        uint256 computedVal = Borrowing.calculateFeesSinceUpdate(rate, lastUpdate);
        assertEq(computedVal, rate * _distance);
    }

    /**
     * For Position, Need:
     * borrowParams.feesOwed, positionSize, isLong, borrowParams.lastCumulatives
     *
     * For state, Need:
     * market, indexPrice, indexBaseUnit, collateralBaseUnit, collateralPrice,
     *
     */
    function testCalculatingTotalFeesOwedInCollateralTokens(uint256 _collateral, uint256 _leverage)
        public
        setUpMarkets
    {
        Order.ExecutionState memory state;
        state.market = IMarket(marketMaker.tokenToMarkets(weth));
        // Open a position to alter the borrowing rate
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

        vm.prank(OWNER);
        processor.executePosition(
            tradeStorage.getOrderAtIndex(0, false),
            OWNER,
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true}),
            tokenUpdateData,
            weth,
            0
        );
        // Get the current rate

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Create an arbitrary position
        _collateral = bound(_collateral, 1, 100_000 ether);
        _leverage = bound(_leverage, 1, 100);
        uint256 positionSize = _collateral * _leverage;
        Position.Data memory position = Position.Data(
            state.market,
            weth,
            USER,
            weth,
            _collateral,
            positionSize,
            2500e18,
            true,
            Position.BorrowingParams(0, 0, 0, 0),
            Position.FundingParams(0, 0, 0, 0, 0),
            bytes32(0),
            bytes32(0)
        );

        // state necessary Variables
        state.indexPrice = 2500e18;
        state.indexBaseUnit = 1e18;
        state.collateralBaseUnit = 1e18;
        state.collateralPrice = 2500e18;

        // Calculate Fees Owed
        uint256 feesOwed = Borrowing.getTotalCollateralFeesOwed(position, state);
        // Index Tokens == Collateral Tokens
        uint256 expectedFees = ((state.market.getBorrowingRate(weth, true) * 1 days) * positionSize) / 1e18;
        assertEq(feesOwed, expectedFees);
    }

    function testCalculatingTotalFeesOwedInCollateralTokensWithExistingCumulative(
        uint256 _collateral,
        uint256 _leverage
    ) public setUpMarkets {
        Order.ExecutionState memory state;
        state.market = IMarket(marketMaker.tokenToMarkets(weth));
        // Open a position to alter the borrowing rate
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

        vm.prank(OWNER);
        processor.executePosition(
            tradeStorage.getOrderAtIndex(0, false),
            OWNER,
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true}),
            tokenUpdateData,
            weth,
            0
        );
        // Get the current rate

        // Set the Cumulative Borrow Fees To 1e18
        // marketStorage -> borrowing -> longCumulativeBorrowFee
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(Market.getCumulativeBorrowFees.selector, weth, true),
            abi.encode(uint256(1e18)) // Mock return value
        );
        assertEq(state.market.getCumulativeBorrowFees(weth, true), 1e18);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Create an arbitrary position
        _collateral = bound(_collateral, 1, 100_000 ether);
        _leverage = bound(_leverage, 1, 100);
        uint256 positionSize = _collateral * _leverage;
        Position.Data memory position = Position.Data(
            state.market,
            weth,
            USER,
            weth,
            _collateral,
            positionSize,
            2500e18,
            true,
            Position.BorrowingParams(0, 0, 1e18, 0),
            Position.FundingParams(0, 0, 0, 0, 0),
            bytes32(0),
            bytes32(0)
        );

        uint256 bonusCumulative = 0.000003e18;

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(Market.getCumulativeBorrowFees.selector, weth, true),
            abi.encode(uint256(1e18) + bonusCumulative) // Mock return value
        );

        // state necessary Variables
        state.indexPrice = 2500e18;
        state.indexBaseUnit = 1e18;
        state.collateralBaseUnit = 1e18;
        state.collateralPrice = 2500e18;

        // Calculate Fees Owed
        uint256 feesOwed = Borrowing.getTotalCollateralFeesOwed(position, state);
        // Index Tokens == Collateral Tokens
        uint256 expectedFees =
            (((state.market.getBorrowingRate(weth, true) * 1 days) + bonusCumulative) * positionSize) / 1e18;
        assertEq(feesOwed, expectedFees);
    }

    function testBorrowingRateCalculationBasic() public setUpMarkets {
        // Open a position to alter the borrowing rate
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

        vm.prank(OWNER);
        processor.executePosition(
            tradeStorage.getOrderAtIndex(0, false),
            OWNER,
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true}),
            tokenUpdateData,
            weth,
            0
        );

        // Fetch the borrowing rate
        uint256 borrowingRate = market.getBorrowingRate(weth, true);
        // Calculate the expected borrowing rate
        // 3.4330185397149488e-12
        uint256 expectedRate = 0.000000000003433018e18;
        // Cross check
        assertEq(borrowingRate, expectedRate);
    }
}
