// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
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
import {Market, IMarket} from "../../../src/markets/Market.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {Execution} from "../../../src/positions/Execution.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {MarketUtils} from "../../../src/markets/MarketUtils.sol";

contract TestBorrowing is Test {
    using stdStorage for StdStorage;

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
    bytes32[] assetIds;
    uint256[] compactedPrices;

    Oracle.PriceUpdateData ethPriceData;

    address USER = makeAddr("USER");

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

        assertEq(MarketUtils.getAllocation(market, ethAssetId), 10000);
        vm.stopPrank();
        _;
    }

    function testCalculateBorrowFeesSinceUpdateForDifferentDistances(uint256 _distance) public {
        _distance = bound(_distance, 1, 3650000 days); // 10000 years
        uint256 rate = 0.001e18;
        vm.warp(block.timestamp + _distance);
        vm.roll(block.number + 1);
        uint256 lastUpdate = block.timestamp - _distance;
        uint256 computedVal = Borrowing.calculateFeesSinceUpdate(rate, lastUpdate);
        assertEq(computedVal, (rate * _distance) / 86400, "Unmatched Values");
    }

    function testCalculatingTotalFeesOwedInCollateralTokensNoExistingCumulative(uint256 _collateral, uint256 _leverage)
        public
        setUpMarkets
    {
        Execution.State memory state;
        // Open a position to alter the borrowing rate
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.4e30,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            reverseWrap: true,
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
        router.createPositionRequest{value: 0.51 ether}(input);

        vm.prank(OWNER);
        positionManager.executePosition{value: 0.01 ether}(
            market, tradeStorage.getOrderAtIndex(0, false), OWNER, ethPriceData
        );
        // Get the current rate

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Create an arbitrary position
        _collateral = bound(_collateral, 1, 100_000 ether);
        _leverage = bound(_leverage, 1, 100);
        uint256 positionSize = (_collateral * _leverage) * 2500e30 / 1e18;

        Position.Data memory position = Position.Data(
            ethAssetId,
            USER,
            weth,
            _collateral,
            positionSize,
            2500e30,
            block.timestamp,
            true,
            Position.FundingParams(MarketUtils.getFundingAccrued(market, ethAssetId), 0),
            Position.BorrowingParams(0, 0, 0),
            bytes32(0),
            bytes32(0)
        );

        // state necessary Variables
        state.indexPrice = 2500e30;
        state.indexBaseUnit = 1e18;
        state.collateralBaseUnit = 1e18;
        state.collateralPrice = 2500e30;

        // Calculate Fees Owed
        uint256 feesOwed = Position.getTotalBorrowFees(market, position, state);
        // Index Tokens == Collateral Tokens
        uint256 expectedFees = mulDiv(
            ((MarketUtils.getBorrowingRate(market, ethAssetId, true) * 1 days) * positionSize) / 1e18,
            state.collateralBaseUnit,
            state.collateralPrice
        );
        assertEq(feesOwed, expectedFees);
    }

    function testCalculatingTotalFeesOwedInCollateralTokensWithExistingCumulative(
        uint256 _collateral,
        uint256 _leverage
    ) public setUpMarkets {
        Execution.State memory state;

        // Create an arbitrary position
        _collateral = bound(_collateral, 1, 100_000 ether);
        _leverage = bound(_leverage, 1, 100);
        uint256 positionSize = (_collateral * _leverage) * 2500e30 / 1e18;
        Position.Data memory position = Position.Data(
            ethAssetId,
            USER,
            weth,
            _collateral,
            positionSize,
            2500e30,
            block.timestamp,
            true,
            Position.FundingParams(MarketUtils.getFundingAccrued(market, ethAssetId), 0),
            Position.BorrowingParams(0, 1e18, 0), // Set entry cumulative to 1e18
            bytes32(0),
            bytes32(0)
        );

        // Amount the user should be charged for
        uint256 bonusCumulative = 0.000003e18;

        // get market storage
        IMarket.MarketStorage memory mockedMarketStorage = market.getStorage(ethAssetId);
        mockedMarketStorage.borrowing.longCumulativeBorrowFees = 1e18 + bonusCumulative;

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getStorage.selector, ethAssetId),
            abi.encode(mockedMarketStorage) // Mock return value
        );

        // state necessary Variables
        state.indexPrice = 2500e30;
        state.indexBaseUnit = 1e18;
        state.collateralBaseUnit = 1e18;
        state.collateralPrice = 2500e30;

        // Calculate Fees Owed
        uint256 feesOwed = Position.getTotalBorrowFees(market, position, state);
        // Index Tokens == Collateral Tokens
        uint256 expectedFees = mulDiv(bonusCumulative, positionSize, 1e18);
        expectedFees = mulDiv(expectedFees, state.collateralBaseUnit, state.collateralPrice);
        assertEq(feesOwed, expectedFees);
    }

    /**
     * function calculateRate(
     *     IMarket market,
     *     bytes32 _assetId,
     *     uint256 _collateralPrice,
     *     uint256 _collateralBaseUnit,
     *     bool _isLong
     * ) public view returns (uint256 borrowRatePerDay) {
     *     uint256 factor = mulDiv(
     *         MarketUtils.getOpenInterest(market, _assetId, _isLong),
     *         PRECISION,
     *         MarketUtils.getAvailableOiUsd(market, _assetId, _collateralPrice, _collateralBaseUnit, _isLong)
     *     );
     *     borrowRatePerDay = mulDiv(market.borrowScale(), factor, PRECISION);
     * }
     */
    function testBorrowingRateCalculation(uint256 _openInterest, uint256 _poolBalance, bool _isLong)
        public
        setUpMarkets
    {
        vm.assume(_poolBalance < 100_000 ether);
        uint256 collateralPrice = _isLong ? 2500e30 : 1e30;
        uint256 collateralBaseUnit = _isLong ? 1e18 : 1e6;
        uint256 maxOi = mulDiv(mulDiv(_poolBalance, collateralPrice, collateralBaseUnit), 8, 10);
        vm.assume(_openInterest < maxOi);

        // Mock the open interest and available open interest on the market
        IMarket.MarketStorage memory mockedMarketStorage = market.getStorage(ethAssetId);
        if (_isLong) {
            mockedMarketStorage.openInterest.longOpenInterest = _openInterest;
        } else {
            mockedMarketStorage.openInterest.shortOpenInterest = _openInterest;
        }
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getStorage.selector, ethAssetId),
            abi.encode(mockedMarketStorage) // Mock return value
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.totalAvailableLiquidity.selector, _isLong),
            abi.encode(_poolBalance)
        );
        // calculate the expected rate
        uint256 expectedRate = mulDiv(market.borrowScale(), _openInterest, maxOi);
        // compare with the actual rate
        uint256 actualRate = Borrowing.calculateRate(market, ethAssetId, collateralPrice, collateralBaseUnit, _isLong);
        // Check off by 1 for round down
        assertApproxEqAbs(actualRate, expectedRate, 1, "Unmatched Values");
    }

    function testGetNextAverageCumulativeCalculationLong(
        uint256 _lastCumulative,
        uint256 _prevAverageCumulative,
        uint256 _openInterest,
        int256 _sizeDelta,
        uint256 _borrowingRate
    ) public setUpMarkets {
        // bound inputs
        vm.assume(_lastCumulative < 1000e18);
        vm.assume(_prevAverageCumulative < 1000e18);
        vm.assume(_openInterest < 1_000_000_000_000e30);
        _sizeDelta = bound(_sizeDelta, -int256(_openInterest), int256(_openInterest));
        _borrowingRate = bound(_borrowingRate, 0, 0.1e18);
        // Get Market storage
        IMarket.MarketStorage memory mockedMarketStorage = market.getStorage(ethAssetId);
        mockedMarketStorage.borrowing.longCumulativeBorrowFees = _lastCumulative;
        mockedMarketStorage.borrowing.weightedAvgCumulativeLong = _prevAverageCumulative;
        mockedMarketStorage.openInterest.longOpenInterest = _openInterest;
        mockedMarketStorage.borrowing.longBorrowingRate = _borrowingRate;

        // mock the rate
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getStorage.selector, ethAssetId),
            abi.encode(mockedMarketStorage)
        );

        // Pass some time
        vm.warp(block.timestamp + 1000 seconds);
        vm.roll(block.number + 1);
        // expected value

        uint256 ev = _calculateEv(mockedMarketStorage, _sizeDelta);

        // test calculation value vs expected
        uint256 nextAverageCumulative = Borrowing.getNextAverageCumulative(market, ethAssetId, _sizeDelta, true);
        // assert eq
        assertEq(nextAverageCumulative, ev, "Unmatched Values");
    }

    function _calculateEv(IMarket.MarketStorage memory mockedMarketStorage, int256 _sizeDelta)
        internal
        pure
        returns (uint256 ev)
    {
        uint256 currentCumulative = mockedMarketStorage.borrowing.longCumulativeBorrowFees
            + (1000 * mockedMarketStorage.borrowing.longBorrowingRate);
        uint256 absSizeDelta = _sizeDelta < 0 ? uint256(-_sizeDelta) : uint256(_sizeDelta);
        if (
            mockedMarketStorage.openInterest.longOpenInterest == 0
                || mockedMarketStorage.borrowing.weightedAvgCumulativeLong == 0
        ) {
            ev = currentCumulative;
        } else if (_sizeDelta < 0 && absSizeDelta == mockedMarketStorage.openInterest.longOpenInterest) {
            ev = 0;
        } else if (_sizeDelta < 0) {
            ev = mockedMarketStorage.borrowing.weightedAvgCumulativeLong;
        } else {
            // If this point in execution is reached -> calculate the next average cumulative
            // Get the percentage of the new position size relative to the total open interest
            uint256 relativeSize = mulDiv(absSizeDelta, 1e18, mockedMarketStorage.openInterest.longOpenInterest);
            // Calculate the new weighted average entry cumulative fee
            ev = mulDiv(mockedMarketStorage.borrowing.weightedAvgCumulativeLong, 1e18 - relativeSize, 1e18)
                + mulDiv(currentCumulative, relativeSize, 1e18);
        }
    }

    function testGettingTheTotalFeesOwedByAMarket(
        uint256 _cumulativeFee,
        uint256 _avgCumulativeFee,
        uint256 _openInterest
    ) public setUpMarkets {
        vm.assume(_cumulativeFee < 1e30);
        vm.assume(_avgCumulativeFee < _cumulativeFee);
        vm.assume(_openInterest < 1_000_000_000_000e30);
        // Get market storage
        IMarket.MarketStorage memory mockedMarketStorage = market.getStorage(ethAssetId);
        mockedMarketStorage.borrowing.longCumulativeBorrowFees = _cumulativeFee;
        mockedMarketStorage.borrowing.weightedAvgCumulativeLong = _avgCumulativeFee;
        mockedMarketStorage.openInterest.longOpenInterest = _openInterest;
        // mock the previous cumulative
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getStorage.selector, ethAssetId),
            abi.encode(mockedMarketStorage) // Mock return value
        );
        // Assert Eq EV vs Actual
        uint256 val = Borrowing.getTotalFeesOwedByMarket(market, ethAssetId, true);

        uint256 ev = mulDiv(_cumulativeFee - _avgCumulativeFee, _openInterest, 1e18);

        assertEq(val, ev, "Unmatched Values");
    }

    function testGettingTheTotalFeesOwedByMultipleMarketsReturnsTheSame(
        uint256 _cumulativeFee,
        uint256 _avgCumulativeFee,
        uint256 _openInterest
    ) public setUpMarkets {
        vm.assume(_cumulativeFee < 1e30);
        vm.assume(_avgCumulativeFee < _cumulativeFee);
        vm.assume(_openInterest < 1_000_000_000_000e30);
        // get market storage
        IMarket.MarketStorage memory mockedMarketStorage = market.getStorage(ethAssetId);
        mockedMarketStorage.borrowing.longCumulativeBorrowFees = _cumulativeFee;
        mockedMarketStorage.borrowing.weightedAvgCumulativeLong = _avgCumulativeFee;
        mockedMarketStorage.openInterest.longOpenInterest = _openInterest;
        // mock the previous cumulative
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getStorage.selector, ethAssetId),
            abi.encode(mockedMarketStorage) // Mock return value
        );
        // Assert Eq EV vs Actual
        uint256 val = Borrowing.getTotalFeesOwedByMarkets(market, true);

        uint256 ev = mulDiv(_cumulativeFee - _avgCumulativeFee, _openInterest, 1e18);

        assertEq(val, ev, "Unmatched Values");
    }
}
