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

contract TestFunding is Test {
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

    /**
     * Need To Test:
     * - Velocity Calculation
     * - Calculation of Accumulated Fees for Market
     * - Calculation of Accumulated Fees for Position
     * - Calculation of Funding Rate
     * - Calculation of Fees Since Update
     */

    /**
     * Config:
     * maxVelocity: 0.09e18, // 9%
     * skewScale: 1_000_000e18 // 1 Mil USD
     */
    function testVelocityCalculationForDifferentSkews() public setUpMarkets {
        // Different Skews
        int256 heavyLong = 500_000e30;
        int256 heavyShort = -500_000e30;
        int256 balancedLong = 1000e30;
        int256 balancedShort = -1000e30;
        // Calculate Heavy Long Velocity
        int256 heavyLongVelocity = Funding.getCurrentVelocity(market, ethTicker, heavyLong);
        /**
         * proportional skew = $500,000 / $1,000,000 = 0.5
         * bounded skew = 0.5
         * velocity = 0.5 * 0.09 = 0.045
         */
        int256 expectedHeavyLongVelocity = 0.045e18;
        assertEq(heavyLongVelocity, expectedHeavyLongVelocity);
        // Calculate Heavy Short Velocity
        int256 heavyShortVelocity = Funding.getCurrentVelocity(market, ethTicker, heavyShort);
        /**
         * proportional skew = -$500,000 / $1,000,000 = -0.5
         * bounded skew = -0.5
         * velocity = -0.5 * 0.09 = -0.045
         */
        int256 expectedHeavyShortVelocity = -0.045e18;
        assertEq(heavyShortVelocity, expectedHeavyShortVelocity);
        // Calculate Balanced Long Velocity
        int256 balancedLongVelocity = Funding.getCurrentVelocity(market, ethTicker, balancedLong);
        /**
         * proportional skew = $1,000 / $1,000,000 = 0.001
         * bounded skew = 0.001
         * velocity = 0.001 * 0.09 = 0.00009
         */
        int256 expectedBalancedLongVelocity = 0.00009e18;
        assertEq(balancedLongVelocity, expectedBalancedLongVelocity);
        // Calculate Balanced Short Velocity
        int256 balancedShortVelocity = Funding.getCurrentVelocity(market, ethTicker, balancedShort);
        /**
         * proportional skew = -$1,000 / $1,000,000 = -0.001
         * bounded skew = -0.001
         * velocity = -0.001 * 0.09 = -0.00009
         */
        int256 expectedBalancedShortVelocity = -0.00009e18;
        assertEq(balancedShortVelocity, expectedBalancedShortVelocity);
    }

    function testSkewCalculationForDifferentSkews(uint256 _longOi, uint256 _shortOi) public setUpMarkets {
        _longOi = bound(_longOi, 1e30, 1_000_000_000_000e30); // Bound between $1 and $1 Trillion
        _shortOi = bound(_shortOi, 1e30, 1_000_000_000_000e30); // Bound between $1 and $1 Trillion
        // Get market storage
        IMarket.OpenInterestValues memory openInterest = market.getOpenInterestValues(ethTicker);
        openInterest.longOpenInterest = _longOi;
        openInterest.shortOpenInterest = _shortOi;
        // Mock Fuzz long & short Oi
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterestValues.selector, ethTicker),
            abi.encode(openInterest)
        );
        // Skew should be long oi - short oi
        int256 skew = Funding.calculateSkewUsd(market, ethTicker);
        int256 expectedSkew = int256(_longOi) - int256(_shortOi);
        assertEq(skew, expectedSkew);
    }

    function testGettingTheCurrentFundingRateChangesOverTimeWithVelocity() public setUpMarkets {
        // Get market storage
        IMarket.FundingValues memory funding = market.getFundingValues(ethTicker);
        funding.fundingRate = 0;
        funding.fundingRateVelocity = 0.0025e18;
        funding.lastFundingUpdate = uint48(block.timestamp);
        // Mock an existing rate and velocity
        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getFundingValues.selector, ethTicker), abi.encode(funding)
        );
        // get current funding rate
        int256 currentFundingRate = Funding.getCurrentFundingRate(market, ethTicker);
        /**
         * currentFundingRate = 0 + 0.0025 * (0 / 86,400)
         *                    = 0
         */
        assertEq(currentFundingRate, 0);

        // Pass some time
        vm.warp(block.timestamp + 10_000);
        vm.roll(block.number + 1);

        // get current funding rate
        currentFundingRate = Funding.getCurrentFundingRate(market, ethTicker);
        /**
         * currentFundingRate = 0 + 0.0025 * (10,000 / 86,400)
         *                    = 0 + 0.0025 * 0.11574074
         *                    = 0.00028935185
         */
        assertEq(currentFundingRate, 289351851851851);

        // Pass some time
        vm.warp(block.timestamp + 10_000);
        vm.roll(block.number + 1);

        // get current funding rate
        currentFundingRate = Funding.getCurrentFundingRate(market, ethTicker);
        /**
         * currentFundingRate = 0 + 0.0025 * (20,000 / 86,400)
         *                    = 0 + 0.0025 * 0.23148148
         *                    = 0.0005787037
         */
        assertEq(currentFundingRate, 578703703703703);

        // Pass some time
        vm.warp(block.timestamp + 10_000);
        vm.roll(block.number + 1);

        // get current funding rate
        currentFundingRate = Funding.getCurrentFundingRate(market, ethTicker);

        /**
         * currentFundingRate = 0 + 0.0025 * (30,000 / 86,400)
         *                    = 0 + 0.0025 * 0.34722222
         *                    = 0.00086805555
         */
        assertEq(currentFundingRate, 868055555555555);
    }

    // Test funding trajectory with sign flip
    function testGettingTheCurrentFundingRateIsConsistentAfterASignFlip() public setUpMarkets {
        // Get market storage
        IMarket.FundingValues memory funding = market.getFundingValues(ethTicker);
        funding.fundingRate = -0.0005e18;
        funding.fundingRateVelocity = 0.0025e18;
        funding.lastFundingUpdate = uint48(block.timestamp);

        // Mock an existing negative rate and positive velocity
        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getFundingValues.selector, ethTicker), abi.encode(funding)
        );
        // get current funding rate
        int256 currentFundingRate = Funding.getCurrentFundingRate(market, ethTicker);
        /**
         * currentFundingRate = -0.0005 + 0.0025 * (0 / 86,400)
         *                    = -0.0005
         */
        assertEq(currentFundingRate, -0.0005e18);

        // Pass some time
        vm.warp(block.timestamp + 10_000);
        vm.roll(block.number + 1);

        // get current funding rate
        currentFundingRate = Funding.getCurrentFundingRate(market, ethTicker);
        /**
         * currentFundingRate = -0.0005 + 0.0025 * (10,000 / 86,400)
         *                    = -0.0005 + 0.0025 * 0.11574074
         *                    = -0.0005 + 0.00028935185
         *                    = -0.000210648148148
         */
        assertEq(currentFundingRate, -210648148148149);

        // Pass some time
        vm.warp(block.timestamp + 10_000);
        vm.roll(block.number + 1);

        // get current funding rate
        currentFundingRate = Funding.getCurrentFundingRate(market, ethTicker);
        /**
         * currentFundingRate = -0.0005 + 0.0025 * (20,000 / 86,400)
         *                    = -0.0005 + 0.0025 * 0.23148148
         *                    = -0.0005 + 0.0005787037
         *                    = 0.0000787037037037
         */
        assertEq(currentFundingRate, 78703703703703);

        // Pass some time
        vm.warp(block.timestamp + 10_000);
        vm.roll(block.number + 1);

        // get current funding rate
        currentFundingRate = Funding.getCurrentFundingRate(market, ethTicker);

        /**
         * currentFundingRate = -0.0005 + 0.0025 * (30,000 / 86,400)
         *                    = -0.0005 + 0.0025 * 0.34722222
         *                    = -0.0005 + 0.00086805555
         *                    = 0.0003680555555555
         */
        assertEq(currentFundingRate, 368055555555555);
    }

    struct PositionChange {
        uint256 sizeDelta;
        int256 entryFundingAccrued;
        int256 fundingRate;
        int256 fundingVelocity;
        int256 fundingFeeUsd;
        int256 nextFundingAccrued;
    }

    function testFuzzGetFeeForPositionChange(
        uint256 _sizeDelta,
        int256 _entryFundingAccrued,
        int256 _fundingRate,
        int256 _fundingVelocity
    ) public setUpMarkets {
        PositionChange memory values;

        // Bound the inputs to reasonable ranges
        values.sizeDelta = bound(_sizeDelta, 1e30, 1_000_000e30); // $1 - $1M
        values.entryFundingAccrued = bound(_entryFundingAccrued, -1e30, 1e30); // Between -$1 and $1
        values.fundingRate = bound(_fundingRate, -1e18, 1e18); // Between -100% and 100%
        values.fundingVelocity = bound(_fundingVelocity, -1e18, 1e18); // Between -100% and 100%

        // Get market storage
        IMarket.FundingValues memory funding = market.getFundingValues(ethTicker);
        funding.fundingRate = values.fundingRate;
        funding.fundingRateVelocity = values.fundingVelocity;
        funding.lastFundingUpdate = uint48(block.timestamp);
        funding.fundingAccruedUsd = values.entryFundingAccrued;

        // Mock the necessary market functions
        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getFundingValues.selector, ethTicker), abi.encode(funding)
        );

        // Pass some time
        vm.warp(block.timestamp + 10_000);
        vm.roll(block.number + 1);

        // Call the function with the fuzzed inputs
        (values.fundingFeeUsd, values.nextFundingAccrued) =
            Position.getFundingFeeDelta(market, ethTicker, 2500e30, values.sizeDelta, values.entryFundingAccrued);

        // Assert that the outputs are within expected ranges
        assertEq(
            values.fundingFeeUsd,
            mulDivSigned(int256(values.sizeDelta), values.nextFundingAccrued - values.entryFundingAccrued, 1e30)
        );
    }

    function testFuzzRecompute(
        int256 _fundingRate,
        int256 _fundingVelocity,
        int256 _entryFundingAccrued,
        uint256 _indexPrice
    ) public setUpMarkets {
        // Bound inputs
        _fundingRate = bound(_fundingRate, -1e18, 1e18); // Between -100% and 100%
        _fundingVelocity = bound(_fundingVelocity, -1e18, 1e18); // Between -100% and 100%
        _entryFundingAccrued = bound(_entryFundingAccrued, -1e30, 1e30); // Between -$1 and $1
        _indexPrice = bound(_indexPrice, 100e30, 100_000e30);
        // Get market storage
        IMarket.FundingValues memory funding = market.getFundingValues(ethTicker);
        funding.fundingRate = _fundingRate;
        funding.fundingRateVelocity = _fundingVelocity;
        funding.lastFundingUpdate = uint48(block.timestamp);
        funding.fundingAccruedUsd = _entryFundingAccrued;
        // Mock the necessary market functions
        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getFundingValues.selector, ethTicker), abi.encode(funding)
        );

        vm.warp(block.timestamp + 10_000);
        vm.roll(block.number + 1);

        // Call the function with the fuzzed input
        (int256 nextFundingRate, int256 nextFundingAccruedUsd) = Funding.recompute(market, ethTicker, _indexPrice);

        // Check values are as expected
        console2.log(nextFundingRate);
        console2.log(nextFundingAccruedUsd);
    }
}
