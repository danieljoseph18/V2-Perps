// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console} from "forge-std/Test.sol";
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

contract TestDepositWithdrawals is Test {
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
            IPriceFeed.Price({expirationTimestamp: block.timestamp + 1 days, min: 3000e30, med: 30000e30, max: 3000e30});
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

    function testExecutingDepositRequest(uint256 _amountIn, bool _isLongToken, bool _shouldWrap) public setUpMarkets {
        if (_isLongToken) {
            _amountIn = bound(_amountIn, 1, 500_000 ether);
            if (_shouldWrap) {
                vm.prank(OWNER);
                router.createDeposit{value: 0.01 ether + _amountIn}(market, OWNER, weth, _amountIn, 0.01 ether, true);
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createDeposit{value: 0.01 ether}(market, OWNER, weth, _amountIn, 0.01 ether, false);
                vm.stopPrank();
            }
        } else {
            _amountIn = bound(_amountIn, 1, 500_000_000e6);
            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createDeposit{value: 0.01 ether + _amountIn}(market, OWNER, usdc, _amountIn, 0.01 ether, false);
            vm.stopPrank();
        }

        // Execute the Deposit
        bytes32 depositKey = market.getRequestAtIndex(0).key;
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(market, depositKey);
    }

    function testExecutingWithdrawalRequest(uint256 _amountIn, uint256 _amountOut, bool _isLongToken, bool _shouldWrap)
        public
        setUpMarkets
    {
        if (_isLongToken) {
            _amountIn = bound(_amountIn, 1 ether, 500_000 ether);
            if (_shouldWrap) {
                vm.prank(OWNER);
                router.createDeposit{value: 0.01 ether + _amountIn}(market, OWNER, weth, _amountIn, 0.01 ether, true);
            } else {
                vm.startPrank(OWNER);
                WETH(weth).approve(address(router), type(uint256).max);
                router.createDeposit{value: 0.01 ether}(market, OWNER, weth, _amountIn, 0.01 ether, false);
                vm.stopPrank();
            }
        } else {
            _amountIn = bound(_amountIn, 10_000e6, 500_000_000e6);
            _shouldWrap = false;
            vm.startPrank(OWNER);
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            router.createDeposit{value: 0.01 ether + _amountIn}(market, OWNER, usdc, _amountIn, 0.01 ether, false);
            vm.stopPrank();
        }

        // Execute the Deposit
        bytes32 depositKey = market.getRequestAtIndex(0).key;
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(market, depositKey);

        // Create Withdrawal request
        IMarketToken marketToken = market.MARKET_TOKEN();
        _amountOut = bound(_amountOut, 0.1e18, marketToken.balanceOf(OWNER));

        vm.startPrank(OWNER);
        marketToken.approve(address(router), type(uint256).max);
        router.createWithdrawal{value: 0.01 ether}(
            market, OWNER, _isLongToken ? weth : usdc, _amountOut, 0.01 ether, _shouldWrap
        );
        bytes32 withdrawalKey = market.getRequestAtIndex(0).key;
        positionManager.executeWithdrawal{value: 0.01 ether}(market, withdrawalKey);
        vm.stopPrank();
    }
}
