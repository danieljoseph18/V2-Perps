// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket} from "src/markets/Market.sol";
import {IVault} from "src/markets/Vault.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {IPriceFeed} from "src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage, ITradeStorage} from "src/positions/TradeStorage.sol";
import {ReferralStorage} from "src/referrals/ReferralStorage.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {Router} from "src/router/Router.sol";
import {WETH} from "src/tokens/WETH.sol";
import {Oracle} from "src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Position} from "src/positions/Position.sol";
import {MarketUtils} from "src/markets/MarketUtils.sol";
import {GlobalRewardTracker} from "src/rewards/GlobalRewardTracker.sol";
import {FeeDistributor} from "src/rewards/FeeDistributor.sol";
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {Referral} from "src/referrals/Referral.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";
import {PriceImpact} from "src/libraries/PriceImpact.sol";
import {Execution} from "src/positions/Execution.sol";
import {Funding} from "src/libraries/Funding.sol";
import {Borrowing} from "src/libraries/Borrowing.sol";
import {Pool} from "src/markets/Pool.sol";
import {Units} from "src/libraries/Units.sol";
import {Casting} from "src/libraries/Casting.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";
import {MarketId} from "src/types/MarketId.sol";

contract TestBorrowing is Test {
    using MathUtils for uint256;
    using Units for uint256;
    using Casting for int256;

    MarketFactory marketFactory;
    MockPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    TradeEngine tradeEngine;
    Router router;
    address OWNER;
    IMarket market;
    IVault vault;
    FeeDistributor feeDistributor;
    GlobalRewardTracker rewardTracker;

    address weth;
    address usdc;
    address link;

    MarketId marketId;

    string ethTicker = "ETH";
    string usdcTicker = "USDC";
    string[] tickers;

    address USER = makeAddr("USER");
    address USER1 = makeAddr("USER1");
    address USER2 = makeAddr("USER2");

    uint8[] precisions;
    uint16[] variances;
    uint48[] timestamps;
    uint64[] meds;

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();

        marketFactory = contracts.marketFactory;
        priceFeed = MockPriceFeed(address(contracts.priceFeed));
        referralStorage = contracts.referralStorage;
        positionManager = contracts.positionManager;
        router = contracts.router;
        market = contracts.market;
        tradeStorage = contracts.tradeStorage;
        tradeEngine = contracts.tradeEngine;
        feeDistributor = contracts.feeDistributor;
        OWNER = contracts.owner;
        (weth, usdc, link,,,,,,,) = deploy.activeNetworkConfig();
        tickers.push(ethTicker);
        tickers.push(usdcTicker);
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
    }

    receive() external payable {}

    modifier setUpMarkets() {
        vm.deal(OWNER, 2_000_000 ether);
        MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);
        vm.deal(USER, 2_000_000 ether);
        MockUSDC(usdc).mint(USER, 1_000_000_000e6);
        vm.deal(USER1, 2_000_000 ether);
        MockUSDC(usdc).mint(USER1, 1_000_000_000e6);
        vm.deal(USER2, 2_000_000 ether);
        MockUSDC(usdc).mint(USER2, 1_000_000_000e6);
        vm.prank(USER);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.prank(USER1);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.prank(USER2);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.startPrank(OWNER);
        WETH(weth).deposit{value: 1_000_000 ether}();
        IMarketFactory.Input memory input = IMarketFactory.Input({
            isMultiAsset: true,
            indexTokenTicker: "ETH",
            marketTokenName: "BRRR",
            marketTokenSymbol: "BRRR",
            strategy: IPriceFeed.SecondaryStrategy({
                exists: false,
                feedType: IPriceFeed.FeedType.CHAINLINK,
                feedAddress: address(0),
                feedId: bytes32(0),
                merkleProof: new bytes32[](0)
            })
        });
        marketFactory.createNewMarket{value: 0.01 ether}(input);
        // Set Prices
        precisions.push(0);
        precisions.push(0);
        variances.push(0);
        variances.push(0);
        timestamps.push(uint48(block.timestamp));
        timestamps.push(uint48(block.timestamp));
        meds.push(3000);
        meds.push(1);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
        marketId = marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);
        bytes memory encodedPnl = priceFeed.encodePnl(0, address(market), uint48(block.timestamp), 0);
        priceFeed.updatePnl(encodedPnl);
        vm.stopPrank();
        vault = market.getVault(marketId);
        tradeStorage = ITradeStorage(market.tradeStorage());
        rewardTracker = GlobalRewardTracker(address(vault.rewardTracker()));
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(marketId, OWNER, weth, 20_000 ether, 0.01 ether, 0, true);
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(marketId, OWNER, usdc, 50_000_000e6, 0.01 ether, 0, false);
        positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);
        vm.stopPrank();
        _;
    }

    /**
     * =================================== Duplicates ===================================
     */

    /**
     * This function stores an average of the "lastCumulativeBorrowFee" for all positions combined.
     * It's used to track the average borrowing fee for all positions.
     * The average is calculated by taking the old average
     *
     * w_new = (w_last * (1 - p)) + (f_current * p)
     *
     * w_new: New weighted average entry cumulative fee
     * w_last: Last weighted average entry cumulative fee
     * f_current: The current cumulative fee on the market.
     * p: The proportion of the new position size relative to the total open interest.
     */
    function getNextAverageCumulative(string memory _ticker, int256 _sizeDeltaUsd, bool _isLong)
        public
        view
        returns (uint256 nextAverageCumulative)
    {
        // Get the abs size delta
        uint256 absSizeDelta = _sizeDeltaUsd.abs();
        // Get the Open Interest
        uint256 openInterestUsd = market.getOpenInterest(marketId, _ticker, _isLong);
        // Get the current cumulative fee on the market
        uint256 currentCumulative = market.getCumulativeBorrowFee(marketId, _ticker, _isLong)
            + Borrowing.calculatePendingFees(marketId, market, _ticker, _isLong);
        // Get the last weighted average entry cumulative fee
        uint256 lastCumulative = market.getAverageCumulativeBorrowFee(marketId, _ticker, _isLong);
        // If OI before is 0, or last cumulative = 0, return current cumulative
        if (openInterestUsd == 0 || lastCumulative == 0) return currentCumulative;
        // If Position is Decrease
        if (_sizeDeltaUsd < 0) {
            // If full decrease, reset the average cumulative
            if (absSizeDelta == openInterestUsd) return 0;
            // Else, the cumulative shouldn't change
            else return lastCumulative;
        }
        // If this point in execution is reached -> calculate the next average cumulative
        // Get the percentage of the new position size relative to the total open interest
        // Relative Size = (absSizeDelta / openInterestUsd)
        uint256 relativeSize = absSizeDelta.divWad(openInterestUsd);
        // Calculate the new weighted average entry cumulative fee
        /**
         * lastCumulative.mul(PRECISION - relativeSize) + currentCumulative.mul(relativeSize);
         */
        nextAverageCumulative = lastCumulative.mulWad(1e18 - relativeSize) + currentCumulative.mulWad(relativeSize);
    }

    /**
     * =================================== Tests ===================================
     */
    function test_calculating_borrow_fees_since_update(uint256 _distance) public {
        _distance = bound(_distance, 1, 3650000 days); // 10000 years
        uint256 rate = 0.001e18;
        vm.warp(block.timestamp + _distance);
        vm.roll(block.number + 1);
        uint256 lastUpdate = block.timestamp - _distance;

        uint256 computedVal = Borrowing.calculateFeesSinceUpdate(rate, lastUpdate);
        assertEq(computedVal, (rate * _distance) / 86400, "Unmatched Values");
    }

    function test_calculating_total_fees_owed_with_no_existing_cumulative(uint256 _collateral, uint256 _leverage)
        public
        setUpMarkets
    {
        Execution.Prices memory borrowPrices;
        // Open a position to alter the borrowing rate
        Position.Input memory input = Position.Input({
            ticker: ethTicker,
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
            triggerAbove: false
        });
        vm.prank(USER);
        router.createPositionRequest{value: 0.51 ether}(
            marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
        );

        vm.prank(OWNER);
        positionManager.executePosition{value: 0.01 ether}(
            marketId, tradeStorage.getOrderAtIndex(marketId, 0, false), bytes32(0), OWNER
        );
        // Get the current rate

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Create an arbitrary position
        _collateral = bound(_collateral, 1e30, 300_000_000e30);
        _leverage = bound(_leverage, 1, 100);
        uint256 positionSize = (_collateral * _leverage) / 1e30;

        Position.Data memory position = Position.Data(
            ethTicker,
            USER,
            weth,
            true,
            uint48(block.timestamp),
            _collateral,
            positionSize,
            3000e30,
            Position.FundingParams(market.getFundingAccrued(marketId, ethTicker), 0),
            Position.BorrowingParams(0, 0, 0),
            bytes32(0),
            bytes32(0)
        );

        // state necessary Variables
        borrowPrices.indexPrice = 3000e30;
        borrowPrices.indexBaseUnit = 1e18;
        borrowPrices.collateralBaseUnit = 1e18;
        borrowPrices.collateralPrice = 3000e30;

        // Calculate Fees Owed
        uint256 feesOwed = Position.getTotalBorrowFees(marketId, market, position, borrowPrices);
        // Index Tokens == Collateral Tokens
        uint256 expectedFees = (((market.getBorrowingRate(marketId, ethTicker, true) * 1 days) * positionSize) / 1e18)
            .mulDiv(borrowPrices.collateralBaseUnit, borrowPrices.collateralPrice);
        assertEq(feesOwed, expectedFees);
    }

    function test_calculating_total_fees_owed_with_cumulative(uint256 _collateral, uint256 _leverage)
        public
        setUpMarkets
    {
        Execution.Prices memory borrowPrices;

        // Create an arbitrary position
        _collateral = bound(_collateral, 1, 100_000 ether);
        _leverage = bound(_leverage, 1, 100);
        uint256 positionSize = (_collateral * _leverage) * 3000e30 / 1e18;
        Position.Data memory position = Position.Data(
            ethTicker,
            USER,
            weth,
            true,
            uint48(block.timestamp),
            _collateral,
            positionSize,
            3000e30,
            Position.FundingParams(market.getFundingAccrued(marketId, ethTicker), 0),
            Position.BorrowingParams(0, 1e18, 0), // Set entry cumulative to 1e18
            bytes32(0),
            bytes32(0)
        );

        // Amount the user should be charged for
        uint256 bonusCumulative = 0.000003e18;

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getCumulativeBorrowFee.selector, marketId, ethTicker, true),
            abi.encode(1e18 + bonusCumulative) // Mock return value
        );

        // state necessary Variables
        borrowPrices.indexPrice = 3000e30;
        borrowPrices.indexBaseUnit = 1e18;
        borrowPrices.collateralBaseUnit = 1e18;
        borrowPrices.collateralPrice = 3000e30;

        // Calculate Fees Owed
        uint256 feesOwed = Position.getTotalBorrowFees(marketId, market, position, borrowPrices);
        // Index Tokens == Collateral Tokens
        uint256 expectedFees = MathUtils.mulDiv(bonusCumulative, positionSize, 1e18);
        expectedFees = MathUtils.mulDiv(expectedFees, borrowPrices.collateralBaseUnit, borrowPrices.collateralPrice);
        assertEq(feesOwed, expectedFees);
    }

    struct BorrowCache {
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        uint256 maxOi;
        uint256 actualRate;
        uint256 expectedRate;
    }

    function test_borrowing_rate_calculation(uint256 _openInterest, bool _isLong) public setUpMarkets {
        BorrowCache memory cache;
        cache.collateralPrice = _isLong ? 3000e30 : 1e30;
        cache.collateralBaseUnit = _isLong ? 1e18 : 1e6;
        cache.maxOi = MarketUtils.getMaxOpenInterest(
            marketId, market, vault, ethTicker, cache.collateralPrice, cache.collateralBaseUnit, _isLong
        );
        _openInterest = bound(_openInterest, 0, cache.maxOi);

        // Mock the open interest and available open interest on the market
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, ethTicker, _isLong),
            abi.encode(_openInterest) // Mock return value
        );
        // compare with the actual rate

        cache.actualRate = Borrowing.calculateRate(
            marketId, market, vault, ethTicker, cache.collateralPrice, cache.collateralBaseUnit, _isLong
        );
        // calculate the expected rate
        cache.expectedRate = MathUtils.mulDiv(market.getBorrowScale(marketId), _openInterest, cache.maxOi);
        // Check off by 1 for round down
        assertApproxEqAbs(cache.actualRate, cache.expectedRate, 1, "Unmatched Values");
    }

    function test_get_next_average_cumulative_calculation_long(
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

        // mock the rate
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, ethTicker, true),
            abi.encode(_openInterest)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getCumulativeBorrowFee.selector, marketId, ethTicker, true),
            abi.encode(_lastCumulative)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getAverageCumulativeBorrowFee.selector, marketId, ethTicker, true),
            abi.encode(_prevAverageCumulative)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getBorrowingRate.selector, marketId, ethTicker, true),
            abi.encode(uint64(_borrowingRate))
        );

        // Pass some time
        vm.warp(block.timestamp + 1000 seconds);
        vm.roll(block.number + 1);
        // expected value

        uint256 currentCumulative = _lastCumulative + (1000 * uint256(uint64(_borrowingRate)));

        uint256 absSizeDelta = _sizeDelta < 0 ? uint256(-_sizeDelta) : uint256(_sizeDelta);

        uint256 ev;
        if (_openInterest == 0 || _prevAverageCumulative == 0) {
            ev = currentCumulative;
        } else if (_sizeDelta < 0 && absSizeDelta == _openInterest) {
            ev = 0;
        } else if (_sizeDelta <= 0) {
            ev = _prevAverageCumulative;
        } else {
            // If this point in execution is reached -> calculate the next average cumulative
            // Get the percentage of the new position size relative to the total open interest
            uint256 relativeSize = MathUtils.mulDiv(absSizeDelta, 1e18, _openInterest);
            // Calculate the new weighted average entry cumulative fee

            ev = MathUtils.mulDiv(_prevAverageCumulative, 1e18 - relativeSize, 1e18)
                + MathUtils.mulDiv(currentCumulative, relativeSize, 1e18);
        }

        // test calculation value vs expected
        uint256 nextAverageCumulative = getNextAverageCumulative(ethTicker, _sizeDelta, true);
        // assert eq
        assertEq(nextAverageCumulative, ev, "Unmatched Values");
    }

    function test_getting_the_total_fees_owed_by_a_market(
        uint256 _cumulativeFee,
        uint256 _avgCumulativeFee,
        uint256 _openInterest
    ) public setUpMarkets {
        vm.assume(_cumulativeFee < 1e30);
        vm.assume(_avgCumulativeFee < _cumulativeFee);
        vm.assume(_openInterest < 1_000_000_000_000e30);

        // mock the previous cumulative
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getCumulativeBorrowFee.selector, marketId, ethTicker, true),
            abi.encode(_cumulativeFee)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getAverageCumulativeBorrowFee.selector, marketId, ethTicker, true),
            abi.encode(_avgCumulativeFee)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, ethTicker, true),
            abi.encode(_openInterest)
        );
        // Assert Eq EV vs Actual
        uint256 val = Borrowing.getTotalFeesOwedByMarket(marketId, market, true);

        uint256 ev = MathUtils.mulDiv(_cumulativeFee - _avgCumulativeFee, _openInterest, 1e18);

        assertEq(val, ev, "Unmatched Values");
    }
}
