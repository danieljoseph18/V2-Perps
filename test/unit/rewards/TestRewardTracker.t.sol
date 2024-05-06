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
import {MarketId} from "src/types/MarketId.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";

contract TestRewardTracker is Test {
    using MathUtils for uint256;
    using Units for uint256;

    MarketFactory marketFactory;
    MockPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    TradeEngine tradeEngine;
    Router router;
    address OWNER;
    IMarket market;
    IVault vault;
    FeeDistributor feeDistributor;
    GlobalRewardTracker rewardTracker;

    address weth;
    address usdc;
    address link;

    MarketId marketId;

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
        market = contracts.market;
        tradeStorage = contracts.tradeStorage;
        tradeEngine = contracts.tradeEngine;
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
        IMarketFactory.Input memory input = IMarketFactory.Input({
            isMultiAsset: true,
            indexTokenTicker: "ETH",
            marketTokenName: "BRRR",
            marketTokenSymbol: "BRRR",
            strategy: IPriceFeed.SecondaryStrategy({
                exists: false,
                feedType: IPriceFeed.FeedType.CHAINLINK,
                feedAddress: address(0),
                feedId: bytes32(0),
                merkleProof: new bytes32[](0)
            })
        });
        marketFactory.createNewMarket{value: 0.01 ether}(input);
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
        marketId = marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);
        bytes memory encodedPnl = priceFeed.encodePnl(0, address(market), uint48(block.timestamp), 0);
        priceFeed.updatePnl(encodedPnl);
        vm.stopPrank();
        vault = market.getVault(marketId);
        tradeStorage = ITradeStorage(market.tradeStorage());
        rewardTracker = GlobalRewardTracker(address(vault.rewardTracker()));
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(marketId, OWNER, weth, 20_000 ether, 0.01 ether, 0, true);
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(marketId, OWNER, usdc, 50_000_000e6, 0.01 ether, 0, false);
        positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);
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
        vm.startPrank(address(tradeEngine));
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
        _amountToStake = bound(_amountToStake, 1000 ether, 1_000_000_000 ether);
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

    function test_users_can_lock_staked_tokens(uint256 _amountToStake, uint256 _duration)
        public
        setUpMarkets
        distributeFees
    {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        _duration = bound(_duration, 1, type(uint32).max);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint40(_duration));
        vm.stopPrank();
        // ensure the staked balance == staked amount
        assertEq(rewardTracker.balanceOf(USER), _amountToStake);
        assertEq(rewardTracker.lockedAmounts(USER), _amountToStake);

        GlobalRewardTracker.LockData memory lock = rewardTracker.getLockAtIndex(USER, 0);
        assertEq(lock.depositAmount, _amountToStake, "Lock Amount");
        assertEq(lock.owner, USER, "Lock Owner");
        assertEq(lock.lockedAt, block.timestamp, "Locked At Date");

        assertEq(lock.unlockDate, block.timestamp + _duration, "Unlock Date");
    }

    function test_users_cant_unlock_staked_tokens_before_the_lock_ends(uint256 _amountToStake, uint256 _duration)
        public
        setUpMarkets
        distributeFees
    {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        _duration = bound(_duration, 1, type(uint32).max);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint40(_duration));
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
        uint256 _duration,
        uint256 _amountToTransfer
    ) public setUpMarkets {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        _duration = bound(_duration, 1, type(uint32).max);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint40(_duration));
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

    function test_users_can_unstake_after_locks_end(uint256 _amountToStake, uint256 _duration)
        public
        setUpMarkets
        distributeFees
    {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        _duration = bound(_duration, 1, type(uint32).max);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint40(_duration));
        vm.stopPrank();

        bytes32 lockKey = rewardTracker.getLockKeyAtIndex(USER, 0);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = lockKey;

        skip(_duration);

        // Try and unlock
        vm.prank(USER);
        rewardTracker.unstake(address(vault), _amountToStake, keys);

        assertEq(rewardTracker.balanceOf(USER), 0);
        assertEq(rewardTracker.lockedAmounts(USER), 0);
        assertEq(vault.balanceOf(USER), _amountToStake);

        GlobalRewardTracker.LockData memory lock = rewardTracker.getLockData(lockKey);

        assertEq(lock.depositAmount, 0, "Lock Amount");
        assertEq(lock.owner, address(0), "Lock Owner");
        assertEq(lock.lockedAt, 0, "Locked At Date");
        assertEq(lock.unlockDate, 0, "Unlock Date");
    }

    function test_users_can_still_claim_rewards_from_locked_tokens(uint256 _amountToStake, uint256 _duration)
        public
        setUpMarkets
        distributeFees
    {
        // bound input
        _amountToStake = bound(_amountToStake, 1000 ether, 1_000_000_000 ether);
        _duration = bound(_duration, 1, type(uint32).max);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint40(_duration));
        vm.stopPrank();

        skip(_duration);

        uint256 ethBalance = IERC20(weth).balanceOf(USER);
        uint256 usdcBalance = IERC20(usdc).balanceOf(USER);

        vm.prank(USER);
        (uint256 ethClaimed, uint256 usdcClaimed) = rewardTracker.claim(address(vault), USER);

        assertNotEq(ethClaimed, 0, "Amount is Zero");
        assertNotEq(usdcClaimed, 0, "Amount is Zero");

        assertEq(IERC20(weth).balanceOf(USER), ethBalance + ethClaimed, "Invalid Claim");
        assertEq(IERC20(usdc).balanceOf(USER), usdcBalance + usdcClaimed, "Invalid Claim");
    }

    function test_auto_staking_through_position_manager_still_lets_users_claim_rewards(
        uint256 _timeToSkip,
        bool _isLongToken
    ) public setUpMarkets distributeFees {
        _timeToSkip = bound(_timeToSkip, 1 days, 3650 days);

        vm.startPrank(USER);
        if (_isLongToken) {
            WETH(weth).approve(address(router), type(uint256).max);
            deal(weth, USER, 20_000 ether);
            router.createDeposit{value: 0.01 ether + 1 gwei}(marketId, USER, weth, 20_000 ether, 0.01 ether, 0, false);
            positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);
        } else {
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            deal(usdc, USER, 50_000_000e6);
            router.createDeposit{value: 0.01 ether + 1 gwei}(marketId, USER, usdc, 50_000_000e6, 0.01 ether, 0, false);
            positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);
        }
        vm.stopPrank();

        assertNotEq(rewardTracker.balanceOf(USER), 0);

        skip(_timeToSkip);

        vm.prank(USER);
        (uint256 ethClaimed, uint256 usdcClaimed) = rewardTracker.claim(address(vault), USER);

        assertNotEq(ethClaimed, 0, "Amount is Zero");
        assertNotEq(usdcClaimed, 0, "Amount is Zero");
    }

    function test_users_can_unstake_auto_staked_tokens(bool _isLongToken) public setUpMarkets {
        vm.startPrank(USER);
        if (_isLongToken) {
            WETH(weth).approve(address(router), type(uint256).max);
            deal(weth, USER, 20_000 ether);
            router.createDeposit{value: 0.01 ether + 1 gwei}(marketId, USER, weth, 20_000 ether, 0.01 ether, 0, false);
            positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);
        } else {
            MockUSDC(usdc).approve(address(router), type(uint256).max);
            deal(usdc, USER, 50_000_000e6);
            router.createDeposit{value: 0.01 ether + 1 gwei}(marketId, USER, usdc, 50_000_000e6, 0.01 ether, 0, false);
            positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);
        }
        vm.stopPrank();

        // Unstake
        vm.startPrank(USER);
        rewardTracker.unstake(address(vault), rewardTracker.balanceOf(USER), new bytes32[](0));
        vm.stopPrank();

        assertEq(rewardTracker.balanceOf(USER), 0);
    }

    function test_users_can_extend_lock_duration(uint256 _amountToStake, uint256 _duration, uint256 _extension)
        public
        setUpMarkets
    {
        // bound input
        _amountToStake = bound(_amountToStake, 1, 1_000_000_000 ether);
        _duration = bound(_duration, 1, type(uint32).max);
        _extension = bound(_extension, 1, type(uint32).max);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, uint40(_duration));
        vm.stopPrank();

        // get the lock position
        bytes32 lockKey = rewardTracker.getLockKeyAtIndex(USER, 0);

        // extend the lock
        vm.startPrank(USER);
        rewardTracker.extendLockDuration(lockKey, uint40(_extension));
        vm.stopPrank();

        // get the lock data
        GlobalRewardTracker.LockData memory lock = rewardTracker.getLockData(lockKey);

        assertEq(lock.unlockDate, block.timestamp + _duration + _extension, "Unlock Date");
    }

    function test_locking_directly_from_the_lock_function(
        uint256 _amountToStake,
        uint256 _amountToLock,
        uint256 _duration
    ) public setUpMarkets {
        // bound input
        _amountToStake = bound(_amountToStake, 2, 1_000_000_000 ether);
        _amountToLock = bound(_amountToLock, 1, _amountToStake - 1);
        _duration = bound(_duration, 1, type(uint32).max);
        // deal user some vault tokens
        deal(address(vault), USER, _amountToStake);
        // stake them
        vm.startPrank(USER);
        vault.approve(address(rewardTracker), _amountToStake);
        rewardTracker.stake(address(vault), _amountToStake, 0);
        rewardTracker.lock(address(vault), _amountToLock, uint40(_duration));
        vm.stopPrank();

        // get the lock position
        GlobalRewardTracker.LockData memory lock = rewardTracker.getLockAtIndex(USER, 0);
        assertEq(lock.depositAmount, _amountToLock, "Lock Amount");

        // Try and unlock, and expect revert
        bytes32 lockKey = rewardTracker.getLockKeyAtIndex(USER, 0);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = lockKey;
        vm.prank(USER);
        vm.expectRevert();
        rewardTracker.unstake(address(vault), _amountToStake, keys);

        skip(_duration);

        // Unlock the unlocked amount and it should pass
        vm.prank(USER);
        rewardTracker.unstake(address(vault), _amountToStake - _amountToLock, keys);

        // Balance should only remain as _amountToLock
        assertEq(rewardTracker.balanceOf(USER), _amountToLock);
    }
}
