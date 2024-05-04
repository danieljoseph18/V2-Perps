// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket, IVault} from "src/markets/Market.sol";
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

contract TestDepositWithdrawals is Test {
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

    function test_executing_deposit_requests(uint256 _amountIn, bool _isLongToken, bool _shouldWrap)
        public
        setUpMarkets
    {
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

    function test_executing_withdrawal_requests(
        uint256 _amountIn,
        uint256 _amountOut,
        bool _isLongToken,
        bool _shouldWrap
    ) public setUpMarkets {
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
        IVault marketToken = market.VAULT();
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
