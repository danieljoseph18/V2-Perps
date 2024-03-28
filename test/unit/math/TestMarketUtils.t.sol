// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {Market, IMarket} from "../../../src/markets/Market.sol";
import {MarketMaker, IMarketMaker} from "../../../src/markets/MarketMaker.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage, ITradeStorage} from "../../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../../../src/router/PositionManager.sol";
import {Router} from "../../../src/router/Router.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Position} from "../../../src/positions/Position.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MarketUtils} from "../../../src/markets/MarketUtils.sol";

contract TestMarketUtils is Test {
    using SignedMath for int256;

    RoleStorage roleStorage;

    MarketMaker marketMaker;
    IPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    Router router;
    address OWNER;
    Market market;
    address feeDistributor;

    address weth;
    address usdc;
    bytes32 ethPriceId;
    bytes32 usdcPriceId;

    bytes[] tokenUpdateData;
    uint256[] allocations;

    address USER = makeAddr("USER");

    bytes32[] assetIds;
    uint256[] compactedPrices;

    Oracle.PriceUpdateData ethPriceData;

    bytes32 ethAssetId = keccak256(abi.encode("ETH"));
    bytes32 usdcAssetId = keccak256(abi.encode("USDC"));

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;

        marketMaker = contracts.marketMaker;
        priceFeed = contracts.priceFeed;
        referralStorage = contracts.referralStorage;
        positionManager = contracts.positionManager;
        router = contracts.router;
        feeDistributor = address(contracts.feeDistributor);
        OWNER = contracts.owner;
        (weth, usdc, ethPriceId, usdcPriceId,,,,) = deploy.activeNetworkConfig();
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
        assetIds.push(ethAssetId);
        assetIds.push(usdcAssetId);

        ethPriceData =
            Oracle.PriceUpdateData({assetIds: assetIds, pythData: tokenUpdateData, compactedPrices: compactedPrices});
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
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            primaryStrategy: Oracle.PrimaryStrategy.PYTH,
            secondaryStrategy: Oracle.SecondaryStrategy.NONE,
            pool: Oracle.UniswapPool({token0: weth, token1: usdc, poolAddress: address(0), poolType: Oracle.PoolType.V3})
        });
        IMarketMaker.MarketRequest memory request = IMarketMaker.MarketRequest({
            owner: OWNER,
            indexTokenTicker: "ETH",
            marketTokenName: "BRRR",
            marketTokenSymbol: "BRRR",
            asset: wethData
        });
        marketMaker.requestNewMarket{value: 0.01 ether}(request);
        // Set primary prices for ref price
        priceFeed.setPrimaryPrices{value: 0.01 ether}(assetIds, tokenUpdateData, compactedPrices);
        // Clear them
        priceFeed.clearPrimaryPrices();
        marketMaker.executeNewMarket(marketMaker.getMarketRequestKey(request.owner, request.indexTokenTicker));
        vm.stopPrank();
        market = Market(payable(marketMaker.tokenToMarket(ethAssetId)));
        tradeStorage = ITradeStorage(market.tradeStorage());
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, OWNER, weth, 20_000 ether, 0.01 ether, true);
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(market, market.getRequestAtIndex(0).key, ethPriceData);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
        positionManager.executeDeposit{value: 0.01 ether}(market, market.getRequestAtIndex(0).key, ethPriceData);
        vm.stopPrank();
        vm.startPrank(OWNER);
        allocations.push(10000 << 240);
        market.setAllocationsWithBits(allocations);
        assertEq(MarketUtils.getAllocation(market, ethAssetId), 10000);
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
            ethAssetId,
            USER,
            weth,
            0.5 ether,
            20_000e30,
            2500e30,
            block.timestamp,
            true,
            Position.FundingParams(MarketUtils.getFundingAccrued(market, ethAssetId), 0),
            Position.BorrowingParams(0, 0, 0),
            bytes32(0),
            bytes32(0)
        );
        // Check the PNL vs the expected PNL
        int256 pnl = Position.getPositionPnl(position.positionSize, position.weightedAvgEntryPrice, _price, 1e18, true);
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
            ethAssetId,
            USER,
            usdc,
            2500e6,
            20_000e30,
            2500e30,
            block.timestamp,
            false,
            Position.FundingParams(MarketUtils.getFundingAccrued(market, ethAssetId), 0),
            Position.BorrowingParams(0, 0, 0),
            bytes32(0),
            bytes32(0)
        );
        // Check the PNL vs the expected PNL
        int256 pnl = Position.getPositionPnl(position.positionSize, position.weightedAvgEntryPrice, _price, 1e18, false);
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

        uint256 actualWaep = MarketUtils.calculateWeightedAverageEntryPrice(
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
        // Get Market Storage
        IMarket.MarketStorage memory mockedMarketStorage;
        {
            mockedMarketStorage.openInterest.longOpenInterest = _longOpenInterest;
            mockedMarketStorage.pnl.longAverageEntryPriceUsd = _longAverageEntryPrice;
        }
        // Update the storage of the market to vary the oi and entry value
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getStorage.selector, ethAssetId),
            abi.encode(mockedMarketStorage)
        );

        // fuzz to test expected vs actual values
        int256 priceDelta = int256(_indexPrice) - int256(_longAverageEntryPrice);
        uint256 entryIndexAmount = mulDiv(_longOpenInterest, 1e18, _longAverageEntryPrice);
        int256 expectedPnl = priceDelta * int256(entryIndexAmount) / 1e18;
        int256 actualPnl = MarketUtils.getMarketPnl(market, ethAssetId, _indexPrice, 1e18, true);
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
        // Get Market Storage
        IMarket.MarketStorage memory mockedMarketStorage;
        {
            mockedMarketStorage.openInterest.shortOpenInterest = _shortOpenInterest;
            mockedMarketStorage.pnl.shortAverageEntryPriceUsd = _shortAverageEntryPrice;
        }
        // Update the storage of the market to vary the oi and entry value
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getStorage.selector, ethAssetId),
            abi.encode(mockedMarketStorage)
        );

        // fuzz to test expected vs actual values
        int256 priceDelta = int256(_indexPrice) - int256(_shortAverageEntryPrice);
        uint256 entryIndexAmount = mulDiv(_shortOpenInterest, 1e18, _shortAverageEntryPrice);
        int256 expectedPnl = -priceDelta * int256(entryIndexAmount) / 1e18;
        int256 actualPnl = MarketUtils.getMarketPnl(market, ethAssetId, _indexPrice, 1e18, false);
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

        IMarket.MarketStorage memory mockedMarketStorage;
        {
            mockedMarketStorage.openInterest.longOpenInterest = _longOpenInterest;
            mockedMarketStorage.openInterest.shortOpenInterest = _shortOpenInterest;
            mockedMarketStorage.pnl.longAverageEntryPriceUsd = _longAverageEntryPrice;
            mockedMarketStorage.pnl.shortAverageEntryPriceUsd = _shortAverageEntryPrice;
        }

        // Update the storage of the market to vary the oi and entry value
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getStorage.selector, ethAssetId),
            abi.encode(mockedMarketStorage)
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

        int256 actualPnl = MarketUtils.getNetMarketPnl(market, ethAssetId, _indexPrice, 1e18);
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

        // Directly use the `getPositionPnl` function to get the PNL in collateral terms
        int256 actualPnlCollateral = Position.getRealizedPnl(
            _sizeDelta, _sizeDelta, _averageEntryPrice, _indexPrice, 1e18, _collateralPrice, 1e18, true
        );

        // Assert that the actual PNL in collateral matches the expected PNL in collateral, considering the conversion and rounding
        assertEq(
            actualPnlCollateral, expectedPnl, "Calculated PNL in collateral does not match expected PNL in collateral."
        );
    }
}
