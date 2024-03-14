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
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
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

    bytes32 ethAssetId = keccak256("ETH");
    bytes32 usdcAssetId = keccak256("USDC");

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
            primaryStrategy: Oracle.PrimaryStrategy.PYTH,
            secondaryStrategy: Oracle.SecondaryStrategy.NONE,
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
        marketMaker.createNewMarket(wethVaultDetails, ethAssetId, ethPriceId, wethData);
        vm.stopPrank();
        address wethMarket = marketMaker.tokenToMarkets(ethAssetId);
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
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, input);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, 0, tokenUpdateData);

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
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, input);
        depositKey = market.getDepositRequestAtIndex(0).key;
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, 0, tokenUpdateData);
        vm.stopPrank();
        vm.startPrank(OWNER);
        uint256 allocation = 10000;
        uint256 encodedAllocation = allocation << 240;
        allocations.push(encodedAllocation);
        market.setAllocationsWithBits(allocations);
        assertEq(market.getAllocation(ethAssetId), 10000);
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
    function testCalculatePnlForAPositionLong(uint256 _price) public setUpMarkets {
        // Construct a Position
        _price = bound(_price, 2000e30, 3000e30);

        Position.Data memory position = Position.Data(
            market,
            ethAssetId,
            USER,
            weth,
            0.5 ether,
            20_000e30,
            2500e30,
            block.timestamp,
            market.getFundingAccrued(ethAssetId),
            true,
            Position.BorrowingParams(0, 0, 0),
            bytes32(0),
            bytes32(0)
        );
        // Check the PNL vs the expected PNL
        int256 pnl = Pricing.getPositionPnl(position, _price, 1e18);
        int256 priceDelta = int256(_price) - int256(position.weightedAvgEntryPrice);
        uint256 entryIndexAmount = mulDiv(position.positionSize, 1e18, position.weightedAvgEntryPrice);
        int256 expectedPnl;
        if (position.isLong) {
            expectedPnl = int256(priceDelta) * int256(entryIndexAmount) / 1e18;
        } else {
            expectedPnl = -int256(priceDelta) * int256(entryIndexAmount) / 1e18;
        }
        assertEq(pnl, expectedPnl);
    }

    function testCalculatePnlForPositionShort(uint256 _price) public setUpMarkets {
        // Construct a Position
        _price = bound(_price, 2000e30, 3000e30);

        Position.Data memory position = Position.Data(
            market,
            ethAssetId,
            USER,
            usdc,
            2500e6,
            20_000e30,
            2500e30,
            block.timestamp,
            market.getFundingAccrued(ethAssetId),
            false,
            Position.BorrowingParams(0, 0, 0),
            bytes32(0),
            bytes32(0)
        );
        // Check the PNL vs the expected PNL
        int256 pnl = Pricing.getPositionPnl(position, _price, 1e18);
        int256 priceDelta = int256(_price) - int256(position.weightedAvgEntryPrice);
        uint256 entryIndexAmount = mulDiv(position.positionSize, 1e18, position.weightedAvgEntryPrice);
        int256 expectedPnl;
        if (position.isLong) {
            expectedPnl = int256(priceDelta) * int256(entryIndexAmount) / 1e18;
        } else {
            expectedPnl = -int256(priceDelta) * int256(entryIndexAmount) / 1e18;
        }
        assertEq(pnl, expectedPnl);
    }

    function testWaepIsCorrectlyCalculatedForAnArrayOfPrices(
        uint256 _prevAverageEntryPrice,
        uint256 _prevPositionSize,
        int256 _sizeDelta,
        uint256 _indexPrice
    ) public {
        _prevPositionSize = bound(_prevPositionSize, 1, 1_000_000_000_000e30);
        _indexPrice = bound(_indexPrice, 1e30, 10e30);
        _prevAverageEntryPrice = bound(_prevAverageEntryPrice, 1e30, 10e30);
        _sizeDelta = bound(_sizeDelta, -int256(_prevPositionSize), int256(_prevPositionSize));

        uint256 expectedWaep;
        if (_sizeDelta <= 0) {
            // If full close, Avg Entry Price is reset to 0
            if (_sizeDelta == -int256(_prevPositionSize)) expectedWaep = 0;
            // Else, Avg Entry Price doesn't change for decrease
            else expectedWaep = _prevAverageEntryPrice;
        } else {
            uint256 newPositionSize = _prevPositionSize + _sizeDelta.abs();

            uint256 numerator = _prevAverageEntryPrice * _prevPositionSize;
            numerator += _indexPrice * _sizeDelta.abs();

            expectedWaep = numerator / newPositionSize;
        }

        uint256 actualWaep = Pricing.calculateWeightedAverageEntryPrice(
            _prevAverageEntryPrice, _prevPositionSize, _sizeDelta, _indexPrice
        );
        assertEq(actualWaep, expectedWaep, "Calculated WAEP does not match expected WAEP");
    }

    // MarketUtils.getOpenInterestUsd
    // MarketUtils.getTotalEntryValueUsd

    function testGettingThePnlForAnEntireMarketLong(
        uint256 _longOpenInterest,
        uint256 _longAverageEntryPrice,
        uint256 _indexPrice
    ) public setUpMarkets {
        // Bound the inputs
        _longOpenInterest = bound(_longOpenInterest, 1e30, 1_000_000_000e30);
        _longAverageEntryPrice = bound(_longAverageEntryPrice, 1e30, 10e30);
        _indexPrice = bound(_indexPrice, 1e30, 10e30);
        // Update the storage of the market to vary the oi and entry value
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getOpenInterest.selector, ethAssetId, true),
            abi.encode(_longOpenInterest)
        );

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getAverageEntryPrice.selector, ethAssetId, true),
            abi.encode(_longAverageEntryPrice)
        );

        // fuzz to test expected vs actual values
        int256 priceDelta = int256(_indexPrice) - int256(_longAverageEntryPrice);
        uint256 entryIndexAmount = mulDiv(_longOpenInterest, 1e18, _longAverageEntryPrice);
        int256 expectedPnl = priceDelta * int256(entryIndexAmount) / 1e18;
        int256 actualPnl = Pricing.getMarketPnl(market, ethAssetId, _indexPrice, 1e18, true);
        assertEq(actualPnl, expectedPnl, "Calculated PNL does not match expected PNL");
    }

    function testGettingThePnlForAnEntireMarketShort(
        uint256 _shortOpenInterest,
        uint256 _shortAverageEntryPrice,
        uint256 _indexPrice
    ) public setUpMarkets {
        // Bound the inputs
        _shortOpenInterest = bound(_shortOpenInterest, 1e30, 1_000_000_000e30);
        _shortAverageEntryPrice = bound(_shortAverageEntryPrice, 1e30, 10e30);
        _indexPrice = bound(_indexPrice, 1e30, 10e30);
        // Update the storage of the market to vary the oi and entry value
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getOpenInterest.selector, ethAssetId, false),
            abi.encode(_shortOpenInterest)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getAverageEntryPrice.selector, ethAssetId, false),
            abi.encode(_shortAverageEntryPrice)
        );

        // fuzz to test expected vs actual values
        int256 priceDelta = int256(_indexPrice) - int256(_shortAverageEntryPrice);
        uint256 entryIndexAmount = mulDiv(_shortOpenInterest, 1e18, _shortAverageEntryPrice);
        int256 expectedPnl = -priceDelta * int256(entryIndexAmount) / 1e18;
        int256 actualPnl = Pricing.getMarketPnl(market, ethAssetId, _indexPrice, 1e18, false);
        assertEq(actualPnl, expectedPnl, "Calculated PNL does not match expected PNL");
    }

    function testGettingTheCombinedPnlForAnEntireMarket(
        uint256 _longOpenInterest,
        uint256 _longAverageEntryPrice,
        uint256 _shortOpenInterest,
        uint256 _shortAverageEntryPrice,
        uint256 _indexPrice
    ) public setUpMarkets {
        // Bound the inputs
        _longOpenInterest = bound(_longOpenInterest, 1e30, 1_000_000_000e30);
        _longAverageEntryPrice = bound(_longAverageEntryPrice, 1e30, 10e30);
        _shortOpenInterest = bound(_shortOpenInterest, 1e30, 1_000_000_000e30);
        _shortAverageEntryPrice = bound(_shortAverageEntryPrice, 1e30, 10e30);
        _indexPrice = bound(_indexPrice, 1e30, 10e30);
        // Update the storage of the market to vary the oi and entry value
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getOpenInterest.selector, ethAssetId, true),
            abi.encode(_longOpenInterest)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getAverageEntryPrice.selector, ethAssetId, true),
            abi.encode(_longAverageEntryPrice)
        );

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getOpenInterest.selector, ethAssetId, false),
            abi.encode(_shortOpenInterest)
        );

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(IMarket.getAverageEntryPrice.selector, ethAssetId, false),
            abi.encode(_shortAverageEntryPrice)
        );
        // fuzz to test expected vs actual values
        int256 longPnl;
        {
            longPnl = (int256(_indexPrice) - int256(_longAverageEntryPrice))
                * int256(mulDiv(_longOpenInterest, 1e18, _longAverageEntryPrice)) / 1e18;
        }
        int256 shortPnl;
        {
            shortPnl = -1 * (int256(_indexPrice) - int256(_shortAverageEntryPrice))
                * int256(mulDiv(_shortOpenInterest, 1e18, _shortAverageEntryPrice)) / 1e18;
        }
        int256 expectedPnl = longPnl + shortPnl;

        int256 actualPnl = Pricing.getNetMarketPnl(market, ethAssetId, _indexPrice, 1e18);
        assertEq(actualPnl, expectedPnl, "Calculated PNL does not match expected PNL");
    }

    function testCalculationForDecreasePositionPnl(
        uint256 _sizeDelta,
        uint256 _averageEntryPrice,
        uint256 _indexPrice,
        uint256 _collateralPrice
    ) public {
        // Adjust bounds to ensure meaningful test values
        _sizeDelta = bound(_sizeDelta, 1e30, 1_000_000_000e30);
        _averageEntryPrice = bound(_averageEntryPrice, 1e30, 10e30);
        _indexPrice = bound(_indexPrice, 1e30, 10e30);
        _collateralPrice = bound(_collateralPrice, 1e30, 10e30);

        // Calculate the expected PNL in USD terms
        int256 priceDelta = int256(_indexPrice) - int256(_averageEntryPrice);
        uint256 entryIndexAmount = mulDiv(_sizeDelta, 1e18, _averageEntryPrice);
        int256 pnlUsd = mulDivSigned(priceDelta, int256(entryIndexAmount), int256(1e18));
        uint256 pnlCollateral = mulDiv(pnlUsd.abs(), 1e18, _collateralPrice);
        int256 expectedPnl = pnlUsd > 0 ? int256(pnlCollateral) : -int256(pnlCollateral);

        // Directly use the `getDecreasePositionPnl` function to get the PNL in collateral terms
        /**
         * uint256 _sizeDeltaUsd,
         *     uint256 _averageEntryPriceUsd,
         *     uint256 _indexPrice,
         *     uint256 _indexBaseUnit,
         *     uint256 _collateralPriceUsd,
         *     uint256 _collateralBaseUnit,
         *     bool _isLong
         */
        int256 actualPnlCollateral = Pricing.getDecreasePositionPnl(
            _sizeDelta, _averageEntryPrice, _indexPrice, 1e18, _collateralPrice, 1e18, true
        );

        // Assert that the actual PNL in collateral matches the expected PNL in collateral, considering the conversion and rounding
        assertEq(
            actualPnlCollateral, expectedPnl, "Calculated PNL in collateral does not match expected PNL in collateral."
        );
    }
}
