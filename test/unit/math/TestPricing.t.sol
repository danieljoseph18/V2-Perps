// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
import {Market, IMarket} from "../../../src/markets/Market.sol";
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
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {Pricing} from "../../../src/libraries/Pricing.sol";
import {Order} from "../../../src/positions/Order.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

contract TestPricing is Test {
    using SignedMath for int256;

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
     * Test:
     * - PNL Calculations
     * - WAEP Calculations
     * - Market PNL Calculations
     * - Decrease Position PNL Calculations
     */
    // @fail
    function testCalculatePnlForAPositionLong(uint256 _price) public setUpMarkets {
        // Construct a Position
        _price = bound(_price, 2000e18, 3000e18);

        Position.Data memory position = Position.Data(
            market,
            weth,
            USER,
            weth,
            0.5 ether,
            8 ether,
            2500e18,
            block.timestamp,
            market.getFundingAccrued(weth),
            true,
            Position.BorrowingParams(0, 0, 0),
            bytes32(0),
            bytes32(0)
        );
        // Check the PNL vs the expected PNL
        int256 pnl = Pricing.calculatePnL(position, _price, 1e18);
        uint256 entryValue = mulDiv(8 ether, 2500e18, 1e18);
        uint256 currentValue = mulDiv(8 ether, _price, 1e18);
        int256 expectedPnl = int256(currentValue) - int256(entryValue);
        assertEq(pnl, expectedPnl);
    }

    // @fail
    function testCalculatePnlForPositionShort(uint256 _price) public setUpMarkets {
        // Construct a Position
        _price = bound(_price, 2000e18, 3000e18);

        Position.Data memory position = Position.Data(
            market,
            weth,
            USER,
            usdc,
            2500e6,
            8 ether,
            2500e18,
            block.timestamp,
            market.getFundingAccrued(weth),
            false,
            Position.BorrowingParams(0, 0, 0),
            bytes32(0),
            bytes32(0)
        );
        // Check the PNL vs the expected PNL
        int256 pnl = Pricing.calculatePnL(position, _price, 1e18);
        uint256 entryValue = mulDiv(8 ether, 2500e18, 1e18);
        uint256 currentValue = mulDiv(8 ether, _price, 1e18);
        int256 expectedPnl = int256(entryValue) - int256(currentValue);
        assertEq(pnl, expectedPnl);
    }

    function testWaepIsCorrectlyCalculatedForAnArrayOfPrices(
        uint256 _prevAverageEntryPrice,
        uint256 _totalIndexSize,
        int256 _sizeDelta,
        uint256 _indexPrice
    ) public {
        _totalIndexSize = bound(_totalIndexSize, 1, 1_000_000_000_000e18);
        _indexPrice = bound(_indexPrice, 1e18, 10e18);
        _prevAverageEntryPrice = bound(_prevAverageEntryPrice, 1e18, 10e18);
        _sizeDelta = bound(_sizeDelta, -int256(_totalIndexSize), int256(_totalIndexSize));

        uint256 expectedWAEP;
        if (_sizeDelta <= 0) {
            if (_sizeDelta.abs() == _totalIndexSize) {
                expectedWAEP = 0;
            } else {
                expectedWAEP = _prevAverageEntryPrice;
            }
        } else {
            uint256 nextIndexSize = _totalIndexSize + _sizeDelta.abs();
            uint256 nextTotalEntryValue = (_prevAverageEntryPrice * _totalIndexSize) + (_indexPrice * _sizeDelta.abs());
            expectedWAEP = nextTotalEntryValue / nextIndexSize;
        }

        uint256 actualWAEP =
            Pricing.calculateWeightedAverageEntryPrice(_prevAverageEntryPrice, _totalIndexSize, _sizeDelta, _indexPrice);
        assertEq(actualWAEP, expectedWAEP, "Calculated WAEP does not match expected WAEP");
    }

    // MarketUtils.getOpenInterestUsd
    // MarketUtils.getTotalEntryValueUsd
    // @fail
    function testGettingThePnlForAnEntireMarketLong(
        uint256 _longOpenInterest,
        uint256 _longAverageEntryPrice,
        uint256 _indexPrice
    ) public setUpMarkets {
        // Bound the inputs
        _longOpenInterest = bound(_longOpenInterest, 1e18, 1_000_000_000e18);
        _longAverageEntryPrice = bound(_longAverageEntryPrice, 1e18, 10e18);
        _indexPrice = bound(_indexPrice, 1e18, 10e18);
        // Update the storage of the market to vary the oi and entry value
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getOpenInterest.selector, weth, true),
            abi.encode(_longOpenInterest)
        );

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getAverageEntryPrice.selector, weth, true),
            abi.encode(_longAverageEntryPrice)
        );

        // fuzz to test expected vs actual values
        uint256 indexValue = mulDiv(_longOpenInterest, _indexPrice, 1e18);
        uint256 entryValue = mulDiv(_longAverageEntryPrice, _longOpenInterest, 1e18);
        int256 expectedPnl = int256(indexValue) - int256(entryValue);
        int256 actualPnl = Pricing.getPnl(market, weth, _indexPrice, 1e18, true);
        assertEq(actualPnl, expectedPnl, "Calculated PNL does not match expected PNL");
    }

    // @fail
    function testGettingThePnlForAnEntireMarketShort(
        uint256 _shortOpenInterest,
        uint256 _shortAverageEntryPrice,
        uint256 _indexPrice
    ) public setUpMarkets {
        // Bound the inputs
        _shortOpenInterest = bound(_shortOpenInterest, 1e18, 1_000_000_000e18);
        _shortAverageEntryPrice = bound(_shortAverageEntryPrice, 1e18, 10e18);
        _indexPrice = bound(_indexPrice, 1e18, 10e18);
        // Update the storage of the market to vary the oi and entry value
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getOpenInterest.selector, weth, false),
            abi.encode(_shortOpenInterest)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getAverageEntryPrice.selector, weth, false),
            abi.encode(_shortAverageEntryPrice)
        );

        // fuzz to test expected vs actual values
        uint256 indexValue = mulDiv(_shortOpenInterest, _indexPrice, 1e18);
        uint256 entryValue = mulDiv(_shortAverageEntryPrice, _shortOpenInterest, 1e18);
        int256 expectedPnl = int256(entryValue) - int256(indexValue);
        int256 actualPnl = Pricing.getPnl(market, weth, _indexPrice, 1e18, false);
        assertEq(actualPnl, expectedPnl, "Calculated PNL does not match expected PNL");
    }

    // @fail
    function testGettingTheCombinedPnlForAnEntireMarket(
        uint256 _longOpenInterest,
        uint256 _longAverageEntryPrice,
        uint256 _shortOpenInterest,
        uint256 _shortAverageEntryPrice,
        uint256 _indexPrice
    ) public setUpMarkets {
        // Bound the inputs
        _longOpenInterest = bound(_longOpenInterest, 1e18, 1_000_000_000e18);
        _longAverageEntryPrice = bound(_longAverageEntryPrice, 1e18, 10e18);
        _shortOpenInterest = bound(_shortOpenInterest, 1e18, 1_000_000_000e18);
        _shortAverageEntryPrice = bound(_shortAverageEntryPrice, 1e18, 10e18);
        _indexPrice = bound(_indexPrice, 1e18, 10e18);
        // Update the storage of the market to vary the oi and entry value
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getOpenInterest.selector, weth, true),
            abi.encode(_longOpenInterest)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getAverageEntryPrice.selector, weth, true),
            abi.encode(_longAverageEntryPrice)
        );

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getOpenInterest.selector, weth, false),
            abi.encode(_shortOpenInterest)
        );

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getAverageEntryPrice.selector, weth, false),
            abi.encode(_shortAverageEntryPrice)
        );
        // fuzz to test expected vs actual values
        int256 longPnl = int256(mulDiv(_longOpenInterest, _indexPrice, 1e18))
            - int256(mulDiv(_longAverageEntryPrice, _longOpenInterest, 1e18));
        int256 shortPnl = int256(mulDiv(_shortAverageEntryPrice, _shortOpenInterest, 1e18))
            - int256(mulDiv(_shortOpenInterest, _indexPrice, 1e18));
        int256 expectedPnl = longPnl + shortPnl;

        int256 actualPnl = Pricing.getNetPnl(market, weth, _indexPrice, 1e18);
        assertEq(actualPnl, expectedPnl, "Calculated PNL does not match expected PNL");
    }

    // @fail
    function testCalculationForDecreasePositionPnl(
        uint256 _sizeDelta,
        uint256 _averageEntryPrice,
        uint256 _indexPrice,
        uint256 _collateralPrice
    ) public {
        // Adjust bounds to ensure meaningful test values
        _sizeDelta = bound(_sizeDelta, 1e18, 1_000_000_000e18);
        _averageEntryPrice = bound(_averageEntryPrice, 1e18, 10e18);
        _indexPrice = bound(_indexPrice, 1e18, 10e18);
        _collateralPrice = bound(_collateralPrice, 1e18, 10e18);

        // Calculate the expected PNL in USD terms
        int256 expectedPnlUsd =
            int256(mulDiv(_sizeDelta, _indexPrice, 1e18)) - int256(mulDiv(_sizeDelta, _averageEntryPrice, 1e18));

        // Directly use the `getDecreasePositionPnl` function to get the PNL in collateral terms
        int256 actualPnlCollateral = Pricing.getDecreasePositionPnl(
            1e18, _sizeDelta, _averageEntryPrice, _indexPrice, 1e18, _collateralPrice, true
        );

        // Convert the expected PNL from USD to collateral tokens. This step aligns with how `getDecreasePositionPnl` function works.
        int256 expectedPnlCollateral = expectedPnlUsd > 0
            ? int256(mulDiv(uint256(expectedPnlUsd), 1e18, _collateralPrice))
            : -int256(mulDiv(uint256(-expectedPnlUsd), 1e18, _collateralPrice));

        // Assert that the actual PNL in collateral matches the expected PNL in collateral, considering the conversion and rounding
        assertEq(
            actualPnlCollateral,
            expectedPnlCollateral,
            "Calculated PNL in collateral does not match expected PNL in collateral."
        );
    }
}
