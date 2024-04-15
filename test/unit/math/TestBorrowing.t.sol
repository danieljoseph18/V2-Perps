// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {Market, IMarket, IMarketToken} from "../../../src/markets/Market.sol";
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
import {mulDiv, mulDivSigned} from "@prb/math/Common.sol";
import {MathUtils} from "../../../src/libraries/MathUtils.sol";
import {Referral} from "../../../src/referrals/Referral.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Execution} from "../../../src/positions/Execution.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";

contract TestBorrowing is Test {
    using MathUtils for uint256;

    RoleStorage roleStorage;

    MarketFactory marketFactory;
    MockPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    Router router;
    address OWNER;
    Market market;
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

    IPriceFeed.Price ethPrices;
    IPriceFeed.Price usdcPrices;
    IPriceFeed.Price[] prices;

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;

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
        IMarketFactory.DeployRequest memory request = IMarketFactory.DeployRequest({
            isMultiAsset: false,
            owner: OWNER,
            indexTokenTicker: "ETH",
            marketTokenName: "BRRR",
            marketTokenSymbol: "BRRR",
            baseUnit: 1e18
        });
        marketFactory.requestNewMarket{value: 0.01 ether}(request);
        market = Market(payable(marketFactory.executeNewMarket(marketFactory.getRequestKeys()[0])));
        vm.stopPrank();
        tradeStorage = ITradeStorage(market.tradeStorage());
        rewardTracker = RewardTracker(address(market.rewardTracker()));
        liquidityLocker = LiquidityLocker(address(rewardTracker.liquidityLocker()));
        // Set Prices
        ethPrices =
            IPriceFeed.Price({expirationTimestamp: block.timestamp + 1 days, min: 3000e30, med: 3000e30, max: 3000e30});
        usdcPrices = IPriceFeed.Price({expirationTimestamp: block.timestamp + 1 days, min: 1e30, med: 1e30, max: 1e30});
        prices.push(ethPrices);
        prices.push(usdcPrices);
        bytes32 priceRequestId = keccak256(abi.encode("PRICE REQUEST"));
        bytes32 pnlRequestId = keccak256(abi.encode("PNL REQUEST"));
        priceFeed.updatePrices(priceRequestId, tickers, prices);
        priceFeed.updatePnl(market, 0, pnlRequestId);
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
        router.createPositionRequest{value: 0.51 ether}(market, input, Position.Conditionals(false, false, 0, 0, 0, 0));

        vm.prank(OWNER);
        positionManager.executePosition{value: 0.01 ether}(
            market, tradeStorage.getOrderAtIndex(0, false), bytes32(0), OWNER
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
            _collateral,
            positionSize,
            3000e30,
            uint64(block.timestamp),
            Position.FundingParams(MarketUtils.getFundingAccrued(market, ethTicker), 0),
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
        uint256 feesOwed = Position.getTotalBorrowFees(market, position, borrowPrices);
        // Index Tokens == Collateral Tokens
        uint256 expectedFees = mulDiv(
            ((MarketUtils.getBorrowingRate(market, ethTicker, true) * 1 days) * positionSize) / 1e18,
            borrowPrices.collateralBaseUnit,
            borrowPrices.collateralPrice
        );
        assertEq(feesOwed, expectedFees);
    }

    function testCalculatingTotalFeesOwedInCollateralTokensWithExistingCumulative(
        uint256 _collateral,
        uint256 _leverage
    ) public setUpMarkets {
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
            _collateral,
            positionSize,
            3000e30,
            uint64(block.timestamp),
            Position.FundingParams(MarketUtils.getFundingAccrued(market, ethTicker), 0),
            Position.BorrowingParams(0, 1e18, 0), // Set entry cumulative to 1e18
            bytes32(0),
            bytes32(0)
        );

        // Amount the user should be charged for
        uint256 bonusCumulative = 0.000003e18;

        // get market storage
        IMarket.BorrowingValues memory borrowing = market.getBorrowingValues(ethTicker);
        borrowing.longCumulativeBorrowFees = 1e18 + bonusCumulative;

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getBorrowingValues.selector, ethTicker),
            abi.encode(borrowing) // Mock return value
        );

        // state necessary Variables
        borrowPrices.indexPrice = 3000e30;
        borrowPrices.indexBaseUnit = 1e18;
        borrowPrices.collateralBaseUnit = 1e18;
        borrowPrices.collateralPrice = 3000e30;

        // Calculate Fees Owed
        uint256 feesOwed = Position.getTotalBorrowFees(market, position, borrowPrices);
        // Index Tokens == Collateral Tokens
        uint256 expectedFees = mulDiv(bonusCumulative, positionSize, 1e18);
        expectedFees = mulDiv(expectedFees, borrowPrices.collateralBaseUnit, borrowPrices.collateralPrice);
        assertEq(feesOwed, expectedFees);
    }

    function testBorrowingRateCalculation(uint256 _openInterest, bool _isLong) public setUpMarkets {
        uint256 collateralPrice = _isLong ? 3000e30 : 1e30;
        uint256 collateralBaseUnit = _isLong ? 1e18 : 1e6;
        uint256 maxOi = MarketUtils.getMaxOpenInterest(market, ethTicker, collateralPrice, collateralBaseUnit, _isLong);
        _openInterest = bound(_openInterest, 0, maxOi);

        // Mock the open interest and available open interest on the market
        IMarket.OpenInterestValues memory openInterest = market.getOpenInterestValues(ethTicker);
        if (_isLong) {
            openInterest.longOpenInterest = _openInterest;
        } else {
            openInterest.shortOpenInterest = _openInterest;
        }
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterestValues.selector, ethTicker),
            abi.encode(openInterest) // Mock return value
        );
        // calculate the expected rate
        console2.log("Borrow Scale: ", market.borrowScale());
        console2.log("Open Interest: ", _openInterest);
        console2.log("Max Open Interest: ", maxOi);
        uint256 expectedRate = market.borrowScale().percentage(_openInterest, maxOi);
        // compare with the actual rate
        uint256 actualRate = Borrowing.calculateRate(market, ethTicker, collateralPrice, collateralBaseUnit, _isLong);
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
        IMarket.BorrowingValues memory borrowing = market.getBorrowingValues(ethTicker);
        IMarket.OpenInterestValues memory openInterest = market.getOpenInterestValues(ethTicker);
        borrowing.longCumulativeBorrowFees = _lastCumulative;
        borrowing.weightedAvgCumulativeLong = _prevAverageCumulative;
        openInterest.longOpenInterest = _openInterest;
        borrowing.longBorrowingRate = _borrowingRate;

        // mock the rate
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getBorrowingValues.selector, ethTicker),
            abi.encode(borrowing)
        );

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterestValues.selector, ethTicker),
            abi.encode(openInterest)
        );

        // Pass some time
        vm.warp(block.timestamp + 1000 seconds);
        vm.roll(block.number + 1);
        // expected value

        uint256 ev = _calculateEv(borrowing, openInterest, _sizeDelta);

        // test calculation value vs expected
        uint256 nextAverageCumulative = Borrowing.getNextAverageCumulative(market, ethTicker, _sizeDelta, true);
        // assert eq
        assertEq(nextAverageCumulative, ev, "Unmatched Values");
    }

    function _calculateEv(
        IMarket.BorrowingValues memory borrowing,
        IMarket.OpenInterestValues memory openInterest,
        int256 _sizeDelta
    ) internal pure returns (uint256 ev) {
        uint256 currentCumulative = borrowing.longCumulativeBorrowFees + (1000 * borrowing.longBorrowingRate);
        uint256 absSizeDelta = _sizeDelta < 0 ? uint256(-_sizeDelta) : uint256(_sizeDelta);
        if (openInterest.longOpenInterest == 0 || borrowing.weightedAvgCumulativeLong == 0) {
            ev = currentCumulative;
        } else if (_sizeDelta < 0 && absSizeDelta == openInterest.longOpenInterest) {
            ev = 0;
        } else if (_sizeDelta < 0) {
            ev = borrowing.weightedAvgCumulativeLong;
        } else {
            // If this point in execution is reached -> calculate the next average cumulative
            // Get the percentage of the new position size relative to the total open interest
            uint256 relativeSize = mulDiv(absSizeDelta, 1e18, openInterest.longOpenInterest);
            // Calculate the new weighted average entry cumulative fee
            ev = mulDiv(borrowing.weightedAvgCumulativeLong, 1e18 - relativeSize, 1e18)
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
        IMarket.BorrowingValues memory borrowing = market.getBorrowingValues(ethTicker);
        IMarket.OpenInterestValues memory openInterest = market.getOpenInterestValues(ethTicker);
        borrowing.longCumulativeBorrowFees = _cumulativeFee;
        borrowing.weightedAvgCumulativeLong = _avgCumulativeFee;
        openInterest.longOpenInterest = _openInterest;
        // mock the previous cumulative
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getBorrowingValues.selector, ethTicker),
            abi.encode(borrowing) // Mock return value
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterestValues.selector, ethTicker),
            abi.encode(openInterest) // Mock return value
        );
        // Assert Eq EV vs Actual
        uint256 val = Borrowing.getTotalFeesOwedByMarket(market, ethTicker, true);

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
        IMarket.BorrowingValues memory borrowing = market.getBorrowingValues(ethTicker);
        IMarket.OpenInterestValues memory openInterest = market.getOpenInterestValues(ethTicker);
        borrowing.longCumulativeBorrowFees = _cumulativeFee;
        borrowing.weightedAvgCumulativeLong = _avgCumulativeFee;
        openInterest.longOpenInterest = _openInterest;
        // mock the previous cumulative
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getBorrowingValues.selector, ethTicker),
            abi.encode(borrowing) // Mock return value
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterestValues.selector, ethTicker),
            abi.encode(openInterest) // Mock return value
        );
        // Assert Eq EV vs Actual
        uint256 val = Borrowing.getTotalFeesOwedByMarkets(market, true);

        uint256 ev = mulDiv(_cumulativeFee - _avgCumulativeFee, _openInterest, 1e18);

        assertEq(val, ev, "Unmatched Values");
    }
}
