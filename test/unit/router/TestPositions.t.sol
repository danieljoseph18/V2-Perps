// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {Market, IMarket} from "../../../src/markets/Market.sol";
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
import {mulDiv} from "@prb/math/Common.sol";

contract TestPositions is Test {
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
        vm.deal(USER, 1_000_000 ether);
        MockUSDC(usdc).mint(USER, 1_000_000_000e6);
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

    function testRequestingAPosition(uint256 _sizeDelta, uint256 _leverage, bool _isLong) public setUpMarkets {
        Position.Input memory input;
        _leverage = bound(_leverage, 1, 100);
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 1, 1_000_000e30);
            uint256 collateralDelta = mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.0003e30, // 0.3%
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: true,
                triggerAbove: false
            });
            vm.prank(OWNER);
            router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        } else {
            _sizeDelta = bound(_sizeDelta, 1, 1_000_000e30);
            uint256 collateralDelta = mulDiv(_sizeDelta / _leverage, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.0003e30, // 0.3%
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
    }

    function testExecuteNewPositionFunction(uint256 _sizeDelta, uint256 _leverage, bool _isLong, bool _shouldWrap)
        public
        setUpMarkets
    {
        // Create Request
        Position.Input memory input;
        _leverage = bound(_leverage, 1, 90);
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            uint256 collateralDelta = mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _shouldWrap,
                triggerAbove: false
            });
            if (_shouldWrap) {
                vm.prank(OWNER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            uint256 collateralDelta = mulDiv(_sizeDelta / _leverage, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);
    }

    function testIncreasingAnExistingPosition(
        uint256 _sizeDelta1,
        uint256 _sizeDelta2,
        uint256 _leverage1,
        uint256 _leverage2,
        bool _isLong,
        bool _shouldWrap
    ) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        _leverage1 = bound(_leverage1, 1, 90);
        if (_isLong) {
            _sizeDelta1 = bound(_sizeDelta1, 210e30, 1_000_000e30);
            uint256 collateralDelta = mulDiv(_sizeDelta1 / _leverage1, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta1,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _shouldWrap,
                triggerAbove: false
            });
            if (_shouldWrap) {
                vm.prank(OWNER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _sizeDelta1 = bound(_sizeDelta1, 210e30, 1_000_000e30);
            uint256 collateralDelta = mulDiv(_sizeDelta1 / _leverage1, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta1, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);

        // Increase Position

        _leverage2 = bound(_leverage2, 1, 90);

        if (_isLong) {
            _sizeDelta2 = bound(_sizeDelta2, 210e30, 1_000_000e30);
            input.sizeDelta = _sizeDelta2;
            input.collateralDelta = mulDiv(_sizeDelta2 / _leverage2, 1e18, 3000e30);
            if (_shouldWrap) {
                vm.prank(OWNER);
                router.createPositionRequest{value: input.collateralDelta + 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.prank(OWNER);
                router.createPositionRequest{value: 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            }
        } else {
            _sizeDelta2 = bound(_sizeDelta2, 210e30, 1_000_000e30);
            input.sizeDelta = _sizeDelta2;
            input.collateralDelta = mulDiv(_sizeDelta2 / _leverage2, 1e6, 1e30);
            vm.prank(OWNER);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        }

        // Execute Request
        key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);
    }

    function testPositionsAreWipedOnceExecuted(uint256 _sizeDelta, uint256 _leverage, bool _isLong, bool _shouldWrap)
        public
        setUpMarkets
    {
        // Create Request
        Position.Input memory input;
        _leverage = bound(_leverage, 1, 90);
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            uint256 collateralDelta = mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _shouldWrap,
                triggerAbove: false
            });
            if (_shouldWrap) {
                vm.prank(OWNER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            uint256 collateralDelta = mulDiv(_sizeDelta / _leverage, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);

        // Check Existence
        vm.expectRevert();
        key = tradeStorage.getOrderAtIndex(0, false);
    }

    function testExecutingACollateralIncrease(
        uint256 _sizeDelta,
        uint256 _leverage,
        uint256 _collateralDelta,
        bool _isLong,
        bool _shouldWrap
    ) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        uint256 collateralDelta;
        _leverage = bound(_leverage, 2, 90);
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            collateralDelta = mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _shouldWrap,
                triggerAbove: false
            });
            if (_shouldWrap) {
                vm.prank(OWNER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            collateralDelta = mulDiv(_sizeDelta / _leverage, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);

        input.sizeDelta = 0;
        input.collateralDelta = bound(_collateralDelta, 1, collateralDelta);

        // Increase Position
        if (_isLong && _shouldWrap) {
            vm.prank(OWNER);
            router.createPositionRequest{value: input.collateralDelta + 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        } else {
            vm.prank(OWNER);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        }

        // Execute Request
        key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);
    }

    function testExecutingACollateralDecrease(uint256 _sizeDelta, uint256 _leverage, bool _isLong, bool _shouldWrap)
        public
        setUpMarkets
    {
        // Create Request
        Position.Input memory input;
        uint256 collateralDelta;
        _leverage = bound(_leverage, 2, 15);
        if (_isLong) {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            collateralDelta = mulDiv(_sizeDelta / _leverage, 1e18, 3000e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _shouldWrap,
                triggerAbove: false
            });
            if (_shouldWrap) {
                vm.prank(OWNER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _sizeDelta = bound(_sizeDelta, 210e30, 1_000_000e30);
            collateralDelta = mulDiv(_sizeDelta / _leverage, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);

        // Create a decrease request
        input.sizeDelta = 0;
        // Calculate collateral delta
        input.collateralDelta = collateralDelta / 2;
        input.isIncrease = false;
        vm.prank(OWNER);
        router.createPositionRequest{value: 0.01 ether}(market, input, Position.Conditionals(false, false, 0, 0, 0, 0));

        // Execute the request
        key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);
    }

    function testDecreasingAPosition(uint256 _sizeDelta, bool _isLong) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        if (_isLong) {
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: 0.5 ether,
                sizeDelta: 5000e30, // 4x leverage
                limitPrice: 0,
                maxSlippage: 0.03e30, // 3%
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: true,
                triggerAbove: false
            });
            vm.prank(OWNER);
            router.createPositionRequest{value: 0.51 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
        } else {
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: 500e6,
                sizeDelta: 5000e30, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.03e30, // 3%
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);

        _sizeDelta = bound(_sizeDelta, 1e30, 5000e30);

        // Min collateral around 2e6 USDC (0.4% of position)
        // If Size Delta > 99.6% of position, set to full close
        if (_sizeDelta > 4970e30) {
            _sizeDelta = 5000e30;
        }

        // Close Position
        input.collateralDelta = 0;
        input.sizeDelta = _sizeDelta;
        input.isIncrease = false;
        vm.prank(OWNER);
        router.createPositionRequest{value: 0.01 ether}(market, input, Position.Conditionals(false, false, 0, 0, 0, 0));

        // Execute Request
        key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);
    }
}
