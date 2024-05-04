// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket, Market} from "src/markets/Market.sol";
import {Vault, IVault} from "src/markets/Vault.sol";
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
import {Units} from "src/libraries/Units.sol";
import {Referral} from "src/referrals/Referral.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";
import {PriceImpact} from "src/libraries/PriceImpact.sol";
import {Execution} from "src/positions/Execution.sol";
import {Funding} from "src/libraries/Funding.sol";
import {Borrowing} from "src/libraries/Borrowing.sol";

contract TestVaultExternals is Test {
    using MathUtils for uint256;
    using Units for uint256;

    MarketFactory marketFactory;
    MockPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    Router router;
    address OWNER;
    IMarket market;
    IVault vault;
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
            isMultiAsset: true,
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
        vault = market.VAULT();
        tradeStorage = ITradeStorage(market.tradeStorage());
        rewardTracker = GlobalRewardTracker(address(vault.rewardTracker()));

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

    function test_updating_liquidity_is_only_valid_from_trade_storage(uint256 _amountToUpdate, bool _isLong)
        public
        setUpMarkets
    {
        vm.expectRevert();
        vault.updateLiquidityReservation(_amountToUpdate, _isLong, true);

        uint256 liquidityResBefore = _isLong ? vault.longTokensReserved() : vault.shortTokensReserved();

        vm.prank(address(tradeStorage));
        vault.updateLiquidityReservation(_amountToUpdate, _isLong, true);

        uint256 liquidityResAfter = _isLong ? vault.longTokensReserved() : vault.shortTokensReserved();

        assertEq(liquidityResBefore + _amountToUpdate, liquidityResAfter, "Update failed");
    }

    function test_updating_pool_balance_is_only_valid_from_trade_storage(uint256 _amountToUpdate, bool _isLong)
        public
        setUpMarkets
    {
        _amountToUpdate = bound(_amountToUpdate, 0, type(uint192).max);
        vm.expectRevert();
        vault.updatePoolBalance(_amountToUpdate, _isLong, true);

        uint256 poolBalanceBefore = _isLong ? vault.longTokenBalance() : vault.shortTokenBalance();

        vm.prank(address(tradeStorage));
        vault.updatePoolBalance(_amountToUpdate, _isLong, true);

        uint256 poolBalanceAfter = _isLong ? vault.longTokenBalance() : vault.shortTokenBalance();

        assertEq(poolBalanceBefore + _amountToUpdate, poolBalanceAfter, "Update failed");
    }

    function test_batch_withdrawing_fees(uint256 _wethIn, uint256 _usdcIn) public setUpMarkets {
        _wethIn = bound(_wethIn, 0, 1_000_000 ether);
        _usdcIn = bound(_usdcIn, 0, 100_000_000_000e6);

        // Transfer Weth and Usdc to the vault
        vm.startPrank(USER);
        deal(weth, USER, _wethIn);
        deal(usdc, USER, _usdcIn);
        WETH(weth).transfer(address(vault), _wethIn);
        IERC20(usdc).transfer(address(vault), _usdcIn);
        vm.stopPrank();

        uint256 wethBalanceBefore = WETH(weth).balanceOf(OWNER);
        uint256 usdcBalanceBefore = IERC20(usdc).balanceOf(OWNER);

        // Accumulate fees
        vm.startPrank(address(tradeStorage));
        vault.accumulateFees(_wethIn, true);
        vault.accumulateFees(_usdcIn, false);
        vm.stopPrank();

        uint256 totalWethFees = Vault(payable(address(vault))).longAccumulatedFees();
        uint256 totalUsdcFees = Vault(payable(address(vault))).shortAccumulatedFees();

        uint256 wethToLps = MathUtils.mulDiv(totalWethFees, 0.8e18, 1e18);
        uint256 usdcToLps = MathUtils.mulDiv(totalUsdcFees, 0.8e18, 1e18);

        vm.prank(OWNER);
        Vault(payable(address(vault))).batchWithdrawFees();

        uint256 wethBalanceAfter = WETH(weth).balanceOf(OWNER);
        uint256 usdcBalanceAfter = IERC20(usdc).balanceOf(OWNER);

        assertEq(wethBalanceBefore + totalWethFees - wethToLps, wethBalanceAfter, "Weth withdrawal failed");
        assertEq(usdcBalanceBefore + totalUsdcFees - usdcToLps, usdcBalanceAfter, "Usdc withdrawal failed");
    }
}
