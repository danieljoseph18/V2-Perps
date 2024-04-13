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

contract TestVaultAccounting is Test {
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
        market = Market(
            payable(
                marketFactory.executeNewMarket(
                    marketFactory.getMarketRequestKey(request.owner, request.indexTokenTicker)
                )
            )
        );
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

    struct TokenBalances {
        uint256 marketBalanceBefore;
        uint256 executorBalanceBefore;
        uint256 referralStorageBalanceBefore;
        uint256 marketBalanceAfter;
        uint256 executorBalanceAfter;
        uint256 referralStorageBalanceAfter;
    }

    struct VaultTest {
        uint256 sizeDelta;
        uint256 collateralDelta;
        uint256 leverage;
        uint256 tier;
        uint256 collateralPrice;
        uint256 collateralBaseUnit;
        bytes32 key;
        address collateralToken;
        uint256 positionFee;
        uint256 feeForExecutor;
        uint256 affiliateRebate;
        bool isLong;
        bool shouldWrap;
    }

    // Request a new fuzzed postition
    // Cache the expected accounting values for each contract
    // Execute the position
    // Compare the expected values to the actual values
    function testCreateNewPositionAccounting(VaultTest memory _vaultTest) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        TokenBalances memory tokenBalances;
        _vaultTest.leverage = bound(_vaultTest.leverage, 1, 90);
        _vaultTest.tier = bound(_vaultTest.tier, 0, 2);
        // Set a random fee tier
        vm.startPrank(OWNER);
        referralStorage.registerCode(bytes32(bytes("CODE")));
        referralStorage.setReferrerTier(OWNER, _vaultTest.tier);
        vm.stopPrank();
        // Use the code from the USER
        vm.prank(USER);
        referralStorage.setTraderReferralCodeByUser(bytes32(bytes("CODE")));

        if (_vaultTest.isLong) {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            _vaultTest.collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(3000e30, 1e18);
            _vaultTest.collateralToken = weth;
            _vaultTest.collateralPrice = 3000e30;
            _vaultTest.collateralBaseUnit = 1e18;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: _vaultTest.collateralDelta,
                sizeDelta: _vaultTest.sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _vaultTest.shouldWrap,
                triggerAbove: false
            });
            if (_vaultTest.shouldWrap) {
                vm.prank(USER);
                router.createPositionRequest{value: _vaultTest.collateralDelta + 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(USER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            _vaultTest.collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(1e30, 1e6);
            _vaultTest.collateralToken = usdc;
            _vaultTest.collateralPrice = 1e30;
            _vaultTest.collateralBaseUnit = 1e6;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: _vaultTest.collateralDelta,
                sizeDelta: _vaultTest.sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(USER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Cache State of the Vault
        tokenBalances.marketBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(address(market));
        tokenBalances.executorBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        tokenBalances.referralStorageBalanceBefore =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));
        // Execute Request
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);

        // Cache State of the Vault
        tokenBalances.marketBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(address(market));
        tokenBalances.executorBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        tokenBalances.referralStorageBalanceAfter =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));

        // Check the Vault Accounting
        // 1. Calculate afterFeeAmount and check that the marketCollateral after = before + afterFeeAmount
        // 2. Check exector balance after has increased by feeForExecutor
        // 3. Check referralStorage balance increased by affiliateReward

        // Calculate the expected market delta
        (_vaultTest.positionFee, _vaultTest.feeForExecutor) = Position.calculateFee(
            tradeStorage,
            _vaultTest.sizeDelta,
            input.collateralDelta,
            _vaultTest.collateralPrice,
            _vaultTest.collateralBaseUnit
        );

        // Calculate & Apply Fee Discount for Referral Code
        (_vaultTest.positionFee, _vaultTest.affiliateRebate,) =
            Referral.applyFeeDiscount(referralStorage, USER, _vaultTest.positionFee);

        // Market should equal --> collateral + position fee

        // Check the market balance
        assertEq(
            tokenBalances.marketBalanceAfter,
            tokenBalances.marketBalanceBefore + input.collateralDelta - _vaultTest.feeForExecutor
                - _vaultTest.affiliateRebate,
            "Market Balance"
        );
        // Check the executor balance
        assertEq(
            tokenBalances.executorBalanceAfter,
            tokenBalances.executorBalanceBefore + _vaultTest.feeForExecutor,
            "Executor Balance"
        );
        // Check the referralStorage balance
        assertEq(
            tokenBalances.referralStorageBalanceAfter,
            tokenBalances.referralStorageBalanceBefore + _vaultTest.affiliateRebate,
            "Referral Storage Balance"
        );
    }

    function testIncreasePositionAccounting(VaultTest memory _vaultTest) public setUpMarkets {
        // Create Request
        Position.Input memory input;
        TokenBalances memory tokenBalances;
        _vaultTest.leverage = bound(_vaultTest.leverage, 1, 90);
        _vaultTest.tier = bound(_vaultTest.tier, 0, 2);
        // Set a random fee tier
        vm.startPrank(OWNER);
        referralStorage.registerCode(bytes32(bytes("CODE")));
        referralStorage.setReferrerTier(OWNER, _vaultTest.tier);
        vm.stopPrank();
        // Use the code from the USER
        vm.prank(USER);
        referralStorage.setTraderReferralCodeByUser(bytes32(bytes("CODE")));

        uint256 collateralDelta;

        if (_vaultTest.isLong) {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(3000e30, 1e18);
            _vaultTest.collateralToken = weth;
            _vaultTest.collateralPrice = 3000e30;
            _vaultTest.collateralBaseUnit = 1e18;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _vaultTest.sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _vaultTest.shouldWrap,
                triggerAbove: false
            });
            if (_vaultTest.shouldWrap) {
                vm.prank(USER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(USER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(1e30, 1e6);
            _vaultTest.collateralToken = usdc;
            _vaultTest.collateralPrice = 1e30;
            _vaultTest.collateralBaseUnit = 1e6;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _vaultTest.sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(USER);
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

        // Cache State of the Vault
        tokenBalances.marketBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(address(market));
        tokenBalances.executorBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        tokenBalances.referralStorageBalanceBefore =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));

        // Create Increase Request
        if (_vaultTest.isLong) {
            if (_vaultTest.shouldWrap) {
                vm.prank(USER);
                router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(USER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            vm.startPrank(USER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, key, bytes32(0), OWNER);

        // Cache State of the Vault
        tokenBalances.marketBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(address(market));
        tokenBalances.executorBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        tokenBalances.referralStorageBalanceAfter =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));

        // Check the Vault Accounting
        // 1. Calculate afterFeeAmount and check that the marketCollateral after = before + afterFeeAmount
        // 2. Check exector balance after has increased by feeForExecutor
        // 3. Check referralStorage balance increased by affiliateReward

        // Calculate the expected market delta
        (uint256 positionFee, uint256 feeForExecutor) = Position.calculateFee(
            tradeStorage,
            _vaultTest.sizeDelta,
            input.collateralDelta,
            _vaultTest.collateralPrice,
            _vaultTest.collateralBaseUnit
        );

        // Calculate & Apply Fee Discount for Referral Code
        uint256 affiliateRebate;
        (positionFee, affiliateRebate,) = Referral.applyFeeDiscount(referralStorage, USER, positionFee);

        // Market should equal --> collateral + position fee

        // Check the market balance
        assertEq(
            tokenBalances.marketBalanceAfter,
            tokenBalances.marketBalanceBefore + input.collateralDelta - feeForExecutor - affiliateRebate,
            "Market Balance"
        );
        // Check the executor balance
        assertEq(
            tokenBalances.executorBalanceAfter, tokenBalances.executorBalanceBefore + feeForExecutor, "Executor Balance"
        );
        // Check the referralStorage balance
        assertEq(
            tokenBalances.referralStorageBalanceAfter,
            tokenBalances.referralStorageBalanceBefore + affiliateRebate,
            "Referral Storage Balance"
        );
    }

    function testDecreasePositionAccounting(VaultTest memory _vaultTest, uint256 _decreasePercentage)
        public
        setUpMarkets
    {
        _decreasePercentage = bound(_decreasePercentage, 0.001e18, 1e18);
        // Create Request
        Position.Input memory input;
        TokenBalances memory tokenBalances;
        _vaultTest.leverage = bound(_vaultTest.leverage, 1, 90);
        _vaultTest.tier = bound(_vaultTest.tier, 0, 2);
        // Set a random fee tier
        vm.startPrank(OWNER);
        referralStorage.registerCode(bytes32(bytes("CODE")));
        referralStorage.setReferrerTier(OWNER, _vaultTest.tier);
        vm.stopPrank();
        // Use the code from the USER
        vm.prank(USER);
        referralStorage.setTraderReferralCodeByUser(bytes32(bytes("CODE")));

        if (_vaultTest.isLong) {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            _vaultTest.collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(3000e30, 1e18);
            _vaultTest.collateralToken = weth;
            _vaultTest.collateralPrice = 3000e30;
            _vaultTest.collateralBaseUnit = 1e18;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: _vaultTest.collateralDelta,
                sizeDelta: _vaultTest.sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _vaultTest.shouldWrap,
                triggerAbove: false
            });
            if (_vaultTest.shouldWrap) {
                vm.prank(USER);
                router.createPositionRequest{value: _vaultTest.collateralDelta + 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                vm.startPrank(USER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createPositionRequest{value: 0.01 ether}(
                    market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            _vaultTest.sizeDelta = bound(_vaultTest.sizeDelta, 210e30, 1_000_000e30);
            _vaultTest.collateralDelta = (_vaultTest.sizeDelta / _vaultTest.leverage).fromUsd(1e30, 1e6);
            _vaultTest.collateralToken = usdc;
            _vaultTest.collateralPrice = 1e30;
            _vaultTest.collateralBaseUnit = 1e6;
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: _vaultTest.collateralDelta,
                sizeDelta: _vaultTest.sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });

            vm.startPrank(USER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createPositionRequest{value: 0.01 ether}(
                market, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        _vaultTest.key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, _vaultTest.key, bytes32(0), OWNER);

        // Cache State of the Vault
        tokenBalances.marketBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(address(market));
        tokenBalances.executorBalanceBefore = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        tokenBalances.referralStorageBalanceBefore =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));

        // Get the Position's collateral
        Position.Data memory position =
            tradeStorage.getPosition(keccak256(abi.encode(input.ticker, USER, input.isLong)));
        uint256 collateral = position.collateral.fromUsd(_vaultTest.collateralPrice, _vaultTest.collateralBaseUnit);

        // Get position pnl
        uint256 pnl = uint256(
            Position.getPositionPnl(position.size, position.weightedAvgEntryPrice, 3000e30, 1e18, input.isLong)
        ).fromUsd(_vaultTest.collateralPrice, _vaultTest.collateralBaseUnit);

        // Create Decrease Request
        input.isIncrease = false;
        if (_decreasePercentage < 0.99e18) {
            input.collateralDelta = collateral * _decreasePercentage / 1e18;
            input.sizeDelta = _vaultTest.sizeDelta * _decreasePercentage / 1e18;
            pnl = pnl * _decreasePercentage / 1e18;
        } else {
            input.collateralDelta = collateral;
        }
        vm.prank(USER);
        router.createPositionRequest{value: 0.01 ether}(market, input, Position.Conditionals(false, false, 0, 0, 0, 0));

        // Execute Request
        _vaultTest.key = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        positionManager.executePosition(market, _vaultTest.key, bytes32(0), OWNER);

        // Cache State of the Vault
        tokenBalances.marketBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(address(market));
        tokenBalances.executorBalanceAfter = IERC20(_vaultTest.collateralToken).balanceOf(OWNER);
        tokenBalances.referralStorageBalanceAfter =
            IERC20(_vaultTest.collateralToken).balanceOf(address(referralStorage));

        // Check the Vault Accounting
        // 1. Calculate afterFeeAmount and check that the marketCollateral after = before + afterFeeAmount
        // 2. Check exector balance after has increased by feeForExecutor
        // 3. Check referralStorage balance increased by affiliateReward

        // Calculate the expected market delta
        (_vaultTest.positionFee, _vaultTest.feeForExecutor) = Position.calculateFee(
            tradeStorage,
            _vaultTest.sizeDelta,
            input.collateralDelta,
            _vaultTest.collateralPrice,
            _vaultTest.collateralBaseUnit
        );

        // Calculate & Apply Fee Discount for Referral Code
        (_vaultTest.positionFee, _vaultTest.affiliateRebate,) =
            Referral.applyFeeDiscount(referralStorage, USER, _vaultTest.positionFee);

        // Check the market balance
        assertApproxEqAbs(
            tokenBalances.marketBalanceAfter,
            tokenBalances.marketBalanceBefore + input.collateralDelta + pnl,
            0.5e18,
            "Market Balance"
        );
        // Check the executor balance
        assertEq(
            tokenBalances.executorBalanceAfter,
            tokenBalances.executorBalanceBefore + _vaultTest.feeForExecutor,
            "Executor Balance"
        );
        // Check the referralStorage balance
        assertEq(
            tokenBalances.referralStorageBalanceAfter,
            tokenBalances.referralStorageBalanceBefore + _vaultTest.affiliateRebate,
            "Referral Storage Balance"
        );
    }
}
