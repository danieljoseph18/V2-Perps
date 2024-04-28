// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {IMarket} from "../../../src/markets/Market.sol";
import {MarketFactory, IMarketFactory} from "../../../src/markets/MarketFactory.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage, ITradeStorage} from "../../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../../../src/router/PositionManager.sol";
import {Router} from "../../../src/router/Router.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Position} from "../../../src/positions/Position.sol";
import {MarketUtils} from "../../../src/markets/MarketUtils.sol";
import {RewardTracker} from "../../../src/rewards/RewardTracker.sol";
import {LiquidityLocker} from "../../../src/rewards/LiquidityLocker.sol";
import {FeeDistributor} from "../../../src/rewards/FeeDistributor.sol";
import {TransferStakedTokens} from "../../../src/rewards/TransferStakedTokens.sol";
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {MathUtils} from "../../../src/libraries/MathUtils.sol";
import {Referral} from "../../../src/referrals/Referral.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Execution} from "../../../src/positions/Execution.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";

contract TestBorrowing is Test {
    using MathUtils for uint256;

    MarketFactory marketFactory;
    MockPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    Router router;
    address OWNER;
    IMarket market;
    FeeDistributor feeDistributor;
    TransferStakedTokens transferStakedTokens;
    RewardTracker rewardTracker;
    LiquidityLocker liquidityLocker;

    address weth;
    address usdc;
    address link;

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
        feeDistributor = contracts.feeDistributor;
        transferStakedTokens = contracts.transferStakedTokens;
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
        IMarketFactory.DeployParams memory request = IMarketFactory.DeployParams({
            isMultiAsset: false,
            owner: OWNER,
            indexTokenTicker: "ETH",
            marketTokenName: "BRRR",
            marketTokenSymbol: "BRRR",
            tokenData: IPriceFeed.TokenData(address(0), 18, IPriceFeed.FeedType.CHAINLINK, false),
            pythData: IMarketFactory.PythData({id: bytes32(0), merkleProof: new bytes32[](0)}),
            stablecoinMerkleProof: new bytes32[](0),
            requestTimestamp: uint48(block.timestamp)
        });
        marketFactory.createNewMarket{value: 0.01 ether}(request);
        // Set Prices
        precisions.push(0);
        precisions.push(0);
        variances.push(100);
        variances.push(100);
        timestamps.push(uint48(block.timestamp));
        timestamps.push(uint48(block.timestamp));
        meds.push(3000);
        meds.push(1);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
        marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);
        market = IMarket(payable(marketFactory.markets(0)));
        bytes memory encodedPnl = priceFeed.encodePnl(0, address(market), uint48(block.timestamp), 0);
        priceFeed.updatePnl(encodedPnl);
        vm.stopPrank();
        tradeStorage = ITradeStorage(market.tradeStorage());
        rewardTracker = RewardTracker(address(market.VAULT().rewardTracker()));
        liquidityLocker = LiquidityLocker(address(rewardTracker.liquidityLocker()));
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, OWNER, weth, 20_000 ether, 0.01 ether, true);
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(market, market.getRequestAtIndex(0).key);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
        positionManager.executeDeposit{value: 0.01 ether}(market, market.getRequestAtIndex(0).key);
        vm.stopPrank();
        _;
    }

    // @audit broken
    function testCalculateBorrowFeesSinceUpdateForDifferentDistances(uint256 _distance) public {
        // _distance = bound(_distance, 1, 3650000 days); // 10000 years
        // uint256 rate = 0.001e18;
        // vm.warp(block.timestamp + _distance);
        // vm.roll(block.number + 1);
        // uint256 lastUpdate = block.timestamp - _distance;
        // // @test - call will no longer exist --> need a new way to query
        // uint256 computedVal = Borrowing.calculateFeesSinceUpdate(rate, lastUpdate);
        // assertEq(computedVal, (rate * _distance) / 86400, "Unmatched Values");
    }

    // @audit broken
    function testCalculatingTotalFeesOwedInCollateralTokensNoExistingCumulative(uint256 _collateral, uint256 _leverage)
        public
        setUpMarkets
    {
        // Execution.Prices memory borrowPrices;
        // // Open a position to alter the borrowing rate
        // Position.Input memory input = Position.Input({
        //     ticker: ethTicker,
        //     collateralToken: weth,
        //     collateralDelta: 0.5 ether,
        //     sizeDelta: 10_000e30,
        //     limitPrice: 0,
        //     maxSlippage: 0.4e30,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: true,
        //     triggerAbove: false
        // });
        // vm.prank(USER);
        // router.createPositionRequest{value: 0.51 ether}(market, input, Position.Conditionals(false, false, 0, 0, 0, 0));

        // vm.prank(OWNER);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), bytes32(0), OWNER
        // );
        // // Get the current rate

        // vm.warp(block.timestamp + 1 days);
        // vm.roll(block.number + 1);

        // // Create an arbitrary position
        // _collateral = bound(_collateral, 1e30, 300_000_000e30);
        // _leverage = bound(_leverage, 1, 100);
        // uint256 positionSize = (_collateral * _leverage) / 1e30;

        // Position.Data memory position = Position.Data(
        //     ethTicker,
        //     USER,
        //     weth,
        //     true,
        //     _collateral,
        //     positionSize,
        //     3000e30,
        //     uint48(block.timestamp),
        //     Position.FundingParams(MarketUtils.getFundingAccrued(market, ethTicker), 0),
        //     Position.BorrowingParams(0, 0, 0),
        //     bytes32(0),
        //     bytes32(0)
        // );

        // // state necessary Variables
        // borrowPrices.indexPrice = 3000e30;
        // borrowPrices.indexBaseUnit = 1e18;
        // borrowPrices.collateralBaseUnit = 1e18;
        // borrowPrices.collateralPrice = 3000e30;

        // // Calculate Fees Owed
        // uint256 feesOwed = Position.getTotalBorrowFees(market, position, borrowPrices);
        // // Index Tokens == Collateral Tokens
        // uint256 expectedFees = (
        //     ((MarketUtils.getBorrowingRate(market, ethTicker, true) * 1 days) * positionSize) / 1e18
        // ).mulDiv(borrowPrices.collateralBaseUnit, borrowPrices.collateralPrice);
        // assertEq(feesOwed, expectedFees);
    }

    // @audit - broken - borrow values
    function testCalculatingTotalFeesOwedInCollateralTokensWithExistingCumulative(
        uint256 _collateral,
        uint256 _leverage
    ) public setUpMarkets {
        // Execution.Prices memory borrowPrices;

        // // Create an arbitrary position
        // _collateral = bound(_collateral, 1, 100_000 ether);
        // _leverage = bound(_leverage, 1, 100);
        // uint256 positionSize = (_collateral * _leverage) * 3000e30 / 1e18;
        // Position.Data memory position = Position.Data(
        //     ethTicker,
        //     USER,
        //     weth,
        //     true,
        //     _collateral,
        //     positionSize,
        //     3000e30,
        //     uint48(block.timestamp),
        //     Position.FundingParams(MarketUtils.getFundingAccrued(market, ethTicker), 0),
        //     Position.BorrowingParams(0, 1e18, 0), // Set entry cumulative to 1e18
        //     bytes32(0),
        //     bytes32(0)
        // );

        // // Amount the user should be charged for
        // uint256 bonusCumulative = 0.000003e18;

        // // get market storage
        // IMarket.BorrowingValues memory borrowing = market.getBorrowingValues(ethTicker);
        // borrowing.longCumulativeBorrowFees = 1e18 + bonusCumulative;

        // vm.mockCall(
        //     address(market),
        //     abi.encodeWithSelector(market.getBorrowingValues.selector, ethTicker),
        //     abi.encode(borrowing) // Mock return value
        // );

        // // state necessary Variables
        // borrowPrices.indexPrice = 3000e30;
        // borrowPrices.indexBaseUnit = 1e18;
        // borrowPrices.collateralBaseUnit = 1e18;
        // borrowPrices.collateralPrice = 3000e30;

        // // Calculate Fees Owed
        // uint256 feesOwed = Position.getTotalBorrowFees(market, position, borrowPrices);
        // // Index Tokens == Collateral Tokens
        // uint256 expectedFees = mulDiv(bonusCumulative, positionSize, 1e18);
        // expectedFees = mulDiv(expectedFees, borrowPrices.collateralBaseUnit, borrowPrices.collateralPrice);
        // assertEq(feesOwed, expectedFees);
    }

    struct BorrowCache {
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        uint256 maxOi;
        uint256 longOi;
        uint256 shortOi;
        uint256 actualRate;
        uint256 expectedRate;
    }

    // @audit - broken --> oi values
    function testBorrowingRateCalculation(uint256 _openInterest, bool _isLong) public setUpMarkets {
        // BorrowCache memory cache;
        // cache.collateralPrice = _isLong ? 3000e30 : 1e30;
        // cache.collateralBaseUnit = _isLong ? 1e18 : 1e6;
        // cache.maxOi =
        //     MarketUtils.getMaxOpenInterest(market, ethTicker, cache.collateralPrice, cache.collateralBaseUnit, _isLong);
        // _openInterest = bound(_openInterest, 0, cache.maxOi);

        // // Mock the open interest and available open interest on the market
        // cache.openInterest = market.getOpenInterestValues(ethTicker);
        // if (_isLong) {
        //     cache.openInterest.longOpenInterest = _openInterest;
        // } else {
        //     cache.openInterest.shortOpenInterest = _openInterest;
        // }
        // vm.mockCall(
        //     address(market),
        //     abi.encodeWithSelector(market.getOpenInterestValues.selector, ethTicker),
        //     abi.encode(cache.openInterest) // Mock return value
        // );
        // // compare with the actual rate
        // // @test - call will no longer exist --> need a new way to query
        // cache.actualRate =
        //     Borrowing.calculateRate(market, ethTicker, cache.collateralPrice, cache.collateralBaseUnit, _isLong);
        // // calculate the expected rate
        // cache.expectedRate = market.borrowScale().percentage(_openInterest, cache.maxOi);
        // // Check off by 1 for round down
        // assertApproxEqAbs(cache.actualRate, cache.expectedRate, 1, "Unmatched Values");
    }

    // @audit - broken - borrow values
    function testGetNextAverageCumulativeCalculationLong(
        uint256 _lastCumulative,
        uint256 _prevAverageCumulative,
        uint256 _openInterest,
        int256 _sizeDelta,
        uint256 _borrowingRate
    ) public setUpMarkets {
        // // bound inputs
        // vm.assume(_lastCumulative < 1000e18);
        // vm.assume(_prevAverageCumulative < 1000e18);
        // vm.assume(_openInterest < 1_000_000_000_000e30);
        // _sizeDelta = bound(_sizeDelta, -int256(_openInterest), int256(_openInterest));
        // _borrowingRate = bound(_borrowingRate, 0, 0.1e18);
        // // Get Market storage
        // IMarket.BorrowingValues memory borrowing = market.getBorrowingValues(ethTicker);
        // IMarket.OpenInterestValues memory openInterest = market.getOpenInterestValues(ethTicker);
        // borrowing.longCumulativeBorrowFees = _lastCumulative;
        // borrowing.weightedAvgCumulativeLong = _prevAverageCumulative;
        // openInterest.longOpenInterest = _openInterest;
        // borrowing.longBorrowingRate = _borrowingRate;

        // // mock the rate
        // vm.mockCall(
        //     address(market),
        //     abi.encodeWithSelector(market.getBorrowingValues.selector, ethTicker),
        //     abi.encode(borrowing)
        // );

        // vm.mockCall(
        //     address(market),
        //     abi.encodeWithSelector(market.getOpenInterestValues.selector, ethTicker),
        //     abi.encode(openInterest)
        // );

        // // Pass some time
        // vm.warp(block.timestamp + 1000 seconds);
        // vm.roll(block.number + 1);
        // // expected value

        // uint256 ev = _calculateEv(borrowing, openInterest, _sizeDelta);

        // // test calculation value vs expected
        // uint256 nextAverageCumulative = Borrowing.getNextAverageCumulative(market, ethTicker, _sizeDelta, true);
        // // assert eq
        // assertEq(nextAverageCumulative, ev, "Unmatched Values");
    }

    // @audit broken
    function _calculateEv(int256 _sizeDelta) internal pure returns (uint256 ev) {
        // uint256 currentCumulative = borrowing.longCumulativeBorrowFees + (1000 * borrowing.longBorrowingRate);
        // uint256 absSizeDelta = _sizeDelta < 0 ? uint256(-_sizeDelta) : uint256(_sizeDelta);
        // if (openInterest.longOpenInterest == 0 || borrowing.weightedAvgCumulativeLong == 0) {
        //     ev = currentCumulative;
        // } else if (_sizeDelta < 0 && absSizeDelta == openInterest.longOpenInterest) {
        //     ev = 0;
        // } else if (_sizeDelta < 0) {
        //     ev = borrowing.weightedAvgCumulativeLong;
        // } else {
        //     // If this point in execution is reached -> calculate the next average cumulative
        //     // Get the percentage of the new position size relative to the total open interest
        //     uint256 relativeSize = mulDiv(absSizeDelta, 1e18, openInterest.longOpenInterest);
        //     // Calculate the new weighted average entry cumulative fee
        //     ev = mulDiv(borrowing.weightedAvgCumulativeLong, 1e18 - relativeSize, 1e18)
        //         + mulDiv(currentCumulative, relativeSize, 1e18);
        // }
    }

    // @audit broken
    function testGettingTheTotalFeesOwedByAMarket(
        uint256 _cumulativeFee,
        uint256 _avgCumulativeFee,
        uint256 _openInterest
    ) public setUpMarkets {
        // vm.assume(_cumulativeFee < 1e30);
        // vm.assume(_avgCumulativeFee < _cumulativeFee);
        // vm.assume(_openInterest < 1_000_000_000_000e30);
        // // Get market storage
        // IMarket.BorrowingValues memory borrowing = market.getBorrowingValues(ethTicker);
        // IMarket.OpenInterestValues memory openInterest = market.getOpenInterestValues(ethTicker);
        // borrowing.longCumulativeBorrowFees = _cumulativeFee;
        // borrowing.weightedAvgCumulativeLong = _avgCumulativeFee;
        // openInterest.longOpenInterest = _openInterest;
        // // mock the previous cumulative
        // vm.mockCall(
        //     address(market),
        //     abi.encodeWithSelector(market.getBorrowingValues.selector, ethTicker),
        //     abi.encode(borrowing) // Mock return value
        // );
        // vm.mockCall(
        //     address(market),
        //     abi.encodeWithSelector(market.getOpenInterestValues.selector, ethTicker),
        //     abi.encode(openInterest) // Mock return value
        // );
        // // Assert Eq EV vs Actual
        // uint256 val = Borrowing.getTotalFeesOwedByMarket(market, ethTicker, true);

        // uint256 ev = mulDiv(_cumulativeFee - _avgCumulativeFee, _openInterest, 1e18);

        // assertEq(val, ev, "Unmatched Values");
    }

    // @audit broken
    function testGettingTheTotalFeesOwedByMultipleMarketsReturnsTheSame(
        uint256 _cumulativeFee,
        uint256 _avgCumulativeFee,
        uint256 _openInterest
    ) public setUpMarkets {
        // vm.assume(_cumulativeFee < 1e30);
        // vm.assume(_avgCumulativeFee < _cumulativeFee);
        // vm.assume(_openInterest < 1_000_000_000_000e30);
        // // get market storage
        // IMarket.BorrowingValues memory borrowing = market.getBorrowingValues(ethTicker);
        // IMarket.OpenInterestValues memory openInterest = market.getOpenInterestValues(ethTicker);
        // borrowing.longCumulativeBorrowFees = _cumulativeFee;
        // borrowing.weightedAvgCumulativeLong = _avgCumulativeFee;
        // openInterest.longOpenInterest = _openInterest;
        // // mock the previous cumulative
        // vm.mockCall(
        //     address(market),
        //     abi.encodeWithSelector(market.getBorrowingValues.selector, ethTicker),
        //     abi.encode(borrowing) // Mock return value
        // );
        // vm.mockCall(
        //     address(market),
        //     abi.encodeWithSelector(market.getOpenInterestValues.selector, ethTicker),
        //     abi.encode(openInterest) // Mock return value
        // );
        // // Assert Eq EV vs Actual
        // uint256 val = Borrowing.getTotalFeesOwedByMarkets(market, true);

        // uint256 ev = mulDiv(_cumulativeFee - _avgCumulativeFee, _openInterest, 1e18);

        // assertEq(val, ev, "Unmatched Values");
    }
}
