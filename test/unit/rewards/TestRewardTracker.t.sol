// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket, Market} from "src/markets/Market.sol";
import {IVault, Vault} from "src/markets/Vault.sol";
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

contract TestRewardTracker is Test {
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

    modifier distributeFees() {
        // Transfer Weth and Usdc to the vault
        vm.startPrank(USER);
        deal(weth, USER, 1000 ether);
        deal(usdc, USER, 300_000_000e6);
        WETH(weth).transfer(address(vault), 1000 ether);
        IERC20(usdc).transfer(address(vault), 300_000_000e6);
        vm.stopPrank();
        vm.startPrank(address(tradeStorage));
        vault.accumulateFees(1000 ether, true);
        vault.accumulateFees(300_000_000e6, false);
        vm.stopPrank();
        Vault(payable(address(vault))).batchWithdrawFees();
        _;
    }

    /**
     * Test the regular individual contracts --> test the global singleton as a different file
     * 1. Test Staking
     * 2. Test Unstaking
     * 3. Test Calculating Rewards
     * 4. Test Claiming Rewards
     */
    function test_users_can_stake_tokens(uint256 _amountToStake) public setUpMarkets {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, 0);
        vm.stopPrank();
        // ensure the staked balance == staked amount
        assertEq(rewardTracker.balanceOf(USER), _amountToStake);
    }

    function test_users_can_unstake_staked_tokens(uint256 _amountToStake, uint256 _percentageToUnstake)
        public
        setUpMarkets
    {
        // bound input
        _amountToStake = bound(_amountToStake, 100, 1_000_000_000 ether);
        _percentageToUnstake = bound(_percentageToUnstake, 1, 100);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, 0);
        vm.stopPrank();
        // ensure the staked balance == staked amount
        assertEq(rewardTracker.balanceOf(USER), _amountToStake);

        // unstake some of the staked tokens
        uint256 amountToUnstake = _amountToStake * _percentageToUnstake / 100;
        vm.startPrank(USER);
        rewardTracker.approve(address(rewardTracker), amountToUnstake);
        bytes32[] memory empty;
        rewardTracker.unstake(address(vault), amountToUnstake, empty);
        vm.stopPrank();
        // ensure the staked balance == staked amount
        assertEq(rewardTracker.balanceOf(USER), _amountToStake - amountToUnstake);
    }

    function test_tokens_per_interval_updates_with_fee_withdrawal() public setUpMarkets distributeFees {
        (uint256 ethTokensPerInterval, uint256 usdcTokensPerInterval) = rewardTracker.tokensPerInterval(address(vault));
        assertNotEq(ethTokensPerInterval, 0);
        assertNotEq(usdcTokensPerInterval, 0);
    }

    function test_users_can_claim_rewards_for_different_intervals(uint256 _amountToStake, uint256 _timeToPass)
        public
        setUpMarkets
        distributeFees
    {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, 0);
        vm.stopPrank();

        _timeToPass = bound(_timeToPass, 1 minutes, 3650 days);

        skip(_timeToPass);

        uint256 ethBalance = IERC20(weth).balanceOf(USER);
        uint256 usdcBalance = IERC20(usdc).balanceOf(USER);

        vm.prank(USER);
        (uint256 ethClaimed, uint256 usdcClaimed) = rewardTracker.claim(address(vault), USER);

        assertNotEq(ethClaimed, 0, "Amount is Zero");
        assertNotEq(usdcClaimed, 0, "Amount is Zero");

        assertEq(IERC20(weth).balanceOf(USER), ethBalance + ethClaimed, "Invalid Claim");
        assertEq(IERC20(usdc).balanceOf(USER), usdcBalance + usdcClaimed, "Invalid Claim");
    }

    function test_claimable_returns_the_actual_claimable_value(uint256 _amountToStake, uint256 _timeToPass)
        public
        setUpMarkets
        distributeFees
    {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, 0);
        vm.stopPrank();

        _timeToPass = bound(_timeToPass, 1 minutes, 3650 days);

        skip(_timeToPass);

        uint256 ethBalance = IERC20(weth).balanceOf(USER);
        uint256 usdcBalance = IERC20(usdc).balanceOf(USER);

        rewardTracker.updateRewards(address(vault));
        (uint256 claimableEth, uint256 claimableUsdc) = rewardTracker.claimable(USER, address(vault));

        vm.prank(USER);
        (uint256 ethClaimed, uint256 usdcClaimed) = rewardTracker.claim(address(vault), USER);

        assertEq(claimableEth, ethClaimed, "Invalid Claimable");
        assertEq(claimableUsdc, usdcClaimed, "Invalid Claimable");

        assertEq(IERC20(weth).balanceOf(USER), ethBalance + ethClaimed, "Invalid Claim");
        assertEq(IERC20(usdc).balanceOf(USER), usdcBalance + usdcClaimed, "Invalid Claim");
    }

    function test_users_can_lock_staked_tokens(uint256 _amountToStake, uint256 _tier)
        public
        setUpMarkets
        distributeFees
    {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        _tier = bound(_tier, 1, 5);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint8(_tier));
        vm.stopPrank();
        // ensure the staked balance == staked amount
        assertEq(rewardTracker.balanceOf(USER), _amountToStake);
        assertEq(rewardTracker.lockedAmounts(USER), _amountToStake);

        GlobalRewardTracker.LockData memory lock = rewardTracker.getLockAtIndex(USER, 0);
        assertEq(lock.depositAmount, _amountToStake, "Lock Amount");
        assertEq(lock.tier, _tier, "Lock Tier");
        assertEq(lock.owner, USER, "Lock Owner");
        assertEq(lock.lockedAt, block.timestamp, "Locked At Date");

        uint256 timeToUnlock;
        if (_tier == 1) {
            timeToUnlock = 1 hours;
        } else if (_tier == 2) {
            timeToUnlock = 30 days;
        } else if (_tier == 3) {
            timeToUnlock = 90 days;
        } else if (_tier == 4) {
            timeToUnlock = 180 days;
        } else if (_tier == 5) {
            timeToUnlock = 365 days;
        }

        assertEq(lock.unlockDate, block.timestamp + timeToUnlock, "Unlock Date");
    }

    function test_users_cant_unlock_staked_tokens_before_the_lock_ends(uint256 _amountToStake, uint256 _tier)
        public
        setUpMarkets
        distributeFees
    {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        _tier = bound(_tier, 1, 5);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint8(_tier));
        vm.stopPrank();

        bytes32 lockKey = rewardTracker.getLockKeyAtIndex(USER, 0);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = lockKey;
        // Try and unlock
        vm.prank(USER);
        vm.expectRevert();
        rewardTracker.unstake(address(vault), _amountToStake, keys);
    }

    function test_users_cant_transfer_locked_tokens_before_the_lock_ends(
        uint256 _amountToStake,
        uint256 _tier,
        uint256 _amountToTransfer
    ) public setUpMarkets {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        _tier = bound(_tier, 1, 5);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint8(_tier));
        vm.stopPrank();

        _amountToTransfer = bound(_amountToTransfer, 1, rewardTracker.balanceOf(USER));

        bytes32 lockKey = rewardTracker.getLockKeyAtIndex(USER, 0);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = lockKey;
        // Try and unlock
        vm.prank(USER);
        vm.expectRevert();
        rewardTracker.transfer(OWNER, _amountToTransfer);
    }

    function test_users_can_unstake_after_locks_end(uint256 _amountToStake, uint256 _tier)
        public
        setUpMarkets
        distributeFees
    {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        _tier = bound(_tier, 1, 5);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint8(_tier));
        vm.stopPrank();

        bytes32 lockKey = rewardTracker.getLockKeyAtIndex(USER, 0);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = lockKey;

        uint256 timeToUnlock;
        if (_tier == 1) {
            timeToUnlock = 1 hours;
        } else if (_tier == 2) {
            timeToUnlock = 30 days;
        } else if (_tier == 3) {
            timeToUnlock = 90 days;
        } else if (_tier == 4) {
            timeToUnlock = 180 days;
        } else if (_tier == 5) {
            timeToUnlock = 365 days;
        }

        skip(timeToUnlock);

        // Try and unlock
        vm.prank(USER);
        rewardTracker.unstake(address(vault), _amountToStake, keys);

        assertEq(rewardTracker.balanceOf(USER), 0);
        assertEq(rewardTracker.lockedAmounts(USER), 0);
        assertEq(vault.balanceOf(USER), _amountToStake);

        GlobalRewardTracker.LockData memory lock = rewardTracker.getLockData(lockKey);

        assertEq(lock.depositAmount, 0, "Lock Amount");
        assertEq(lock.tier, 0, "Lock Tier");
        assertEq(lock.owner, address(0), "Lock Owner");
        assertEq(lock.lockedAt, 0, "Locked At Date");
        assertEq(lock.unlockDate, 0, "Unlock Date");
    }

    function test_users_can_still_claim_rewards_from_locked_tokens(
        uint256 _amountToStake,
        uint256 _tier,
        uint256 _timeToPass
    ) public setUpMarkets distributeFees {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        _tier = bound(_tier, 1, 5);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint8(_tier));
        vm.stopPrank();

        _timeToPass = bound(_timeToPass, 1 minutes, 3650 days);

        skip(_timeToPass);

        uint256 ethBalance = IERC20(weth).balanceOf(USER);
        uint256 usdcBalance = IERC20(usdc).balanceOf(USER);

        vm.prank(USER);
        (uint256 ethClaimed, uint256 usdcClaimed) = rewardTracker.claim(address(vault), USER);

        assertNotEq(ethClaimed, 0, "Amount is Zero");
        assertNotEq(usdcClaimed, 0, "Amount is Zero");

        assertEq(IERC20(weth).balanceOf(USER), ethBalance + ethClaimed, "Invalid Claim");
        assertEq(IERC20(usdc).balanceOf(USER), usdcBalance + usdcClaimed, "Invalid Claim");
    }
}
