// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket} from "src/markets/Market.sol";
import {Pool} from "src/markets/Pool.sol";
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

contract TestFunding is Test {
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

    GlobalRewardTracker rewardTracker;

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
        variances.push(0);
        variances.push(0);
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
        rewardTracker = GlobalRewardTracker(address(market.VAULT().rewardTracker()));

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
     * maxVelocity: 900, // 9%
     * skewScale: 1_000_000 // 1 Mil USD
     */
    function test_velocity_calculation_for_different_skews() public setUpMarkets {
        // Different Skews
        int256 heavyLong = 500_000e30;
        int256 heavyShort = -500_000e30;
        int256 balancedLong = 1000e30;
        int256 balancedShort = -1000e30;
        // Calculate Heavy Long Velocity
        int256 heavyLongVelocity = Funding.getCurrentVelocity(market, heavyLong, 900, 1_000_000);
        /**
         * proportional skew = $500,000 / $1,000,000 = 0.5
         * bounded skew = 0.5
         * velocity = 0.5 * 0.09 = 0.045
         */
        int256 expectedHeavyLongVelocity = 0.045e18;
        assertEq(heavyLongVelocity, expectedHeavyLongVelocity);
        // Calculate Heavy Short Velocity
        int256 heavyShortVelocity = Funding.getCurrentVelocity(market, heavyShort, 900, 1_000_000);
        /**
         * proportional skew = -$500,000 / $1,000,000 = -0.5
         * bounded skew = -0.5
         * velocity = -0.5 * 0.09 = -0.045
         */
        int256 expectedHeavyShortVelocity = -0.045e18;
        assertEq(heavyShortVelocity, expectedHeavyShortVelocity);
        // Calculate Balanced Long Velocity
        int256 balancedLongVelocity = Funding.getCurrentVelocity(market, balancedLong, 900, 1_000_000);
        /**
         * proportional skew = $1,000 / $1,000,000 = 0.001
         * bounded skew = 0.001
         * velocity = 0.001 * 0.09 = 0.00009
         */
        int256 expectedBalancedLongVelocity = 0.00009e18;
        assertEq(balancedLongVelocity, expectedBalancedLongVelocity);
        // Calculate Balanced Short Velocity
        int256 balancedShortVelocity = Funding.getCurrentVelocity(market, balancedShort, 900, 1_000_000);
        /**
         * proportional skew = -$1,000 / $1,000,000 = -0.001
         * bounded skew = -0.001
         * velocity = -0.001 * 0.09 = -0.00009
         */
        int256 expectedBalancedShortVelocity = -0.00009e18;
        assertEq(balancedShortVelocity, expectedBalancedShortVelocity);
    }

    function test_funding_rate_changes_over_time() public setUpMarkets {
        // Mock an existing rate and velocity
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getFundingRates.selector, ethTicker),
            abi.encode(0, 0.0025e18)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getLastUpdate.selector, ethTicker),
            abi.encode(uint48(block.timestamp))
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

    function test_funding_rate_remains_consistent_after_sign_flip() public setUpMarkets {
        // Mock an existing negative rate and positive velocity
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getFundingRates.selector, ethTicker),
            abi.encode(-0.0005e18, 0.0025e18)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getLastUpdate.selector, ethTicker),
            abi.encode(uint48(block.timestamp))
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

    function test_fuzzing_get_fee_for_position_change(
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
        Pool.Storage memory store = market.getStorage(ethTicker);
        store.fundingRate = int64(values.fundingRate);
        store.fundingRateVelocity = int64(values.fundingVelocity);
        store.lastUpdate = uint48(block.timestamp);
        store.fundingAccruedUsd = values.entryFundingAccrued;

        // Mock the necessary market functions
        vm.mockCall(address(market), abi.encodeWithSelector(market.getStorage.selector, ethTicker), abi.encode(store));

        // Pass some time
        vm.warp(block.timestamp + 10_000);
        vm.roll(block.number + 1);

        // Call the function with the fuzzed inputs
        (values.fundingFeeUsd, values.nextFundingAccrued) =
            Position.getFundingFeeDelta(market, ethTicker, 2500e30, values.sizeDelta, values.entryFundingAccrued);

        // Assert that the outputs are within expected ranges
        assertEq(
            values.fundingFeeUsd,
            MathUtils.mulDivSigned(
                int256(values.sizeDelta), values.nextFundingAccrued - values.entryFundingAccrued, 1e30
            )
        );
    }

    function test_fuzzing_recompute(
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
        Pool.Storage memory store = market.getStorage(ethTicker);
        store.fundingRate = int64(_fundingRate);
        store.fundingRateVelocity = int64(_fundingVelocity);
        store.lastUpdate = uint48(block.timestamp);
        store.fundingAccruedUsd = _entryFundingAccrued;
        // Mock the necessary market functions
        vm.mockCall(address(market), abi.encodeWithSelector(market.getStorage.selector, ethTicker), abi.encode(store));

        vm.warp(block.timestamp + 10_000);
        vm.roll(block.number + 1);

        // Call the function with the fuzzed input
        (int256 nextFundingRate, int256 nextFundingAccruedUsd) = Funding.recompute(market, ethTicker, _indexPrice);

        // Check values are as expected
        console2.log(nextFundingRate);
        console2.log(nextFundingAccruedUsd);
    }
}
