// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
import {LiquidityVault} from "../../../src/liquidity/LiquidityVault.sol";
import {MarketMaker} from "../../../src/markets/MarketMaker.sol";
import {StateUpdater} from "../../../src/markets/StateUpdater.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage} from "../../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {Processor} from "../../../src/router/Processor.sol";
import {Router} from "../../../src/router/Router.sol";
import {Deposit} from "../../../src/liquidity/Deposit.sol";
import {Withdrawal} from "../../../src/liquidity/Withdrawal.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {Pool} from "../../../src/liquidity/Pool.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Fee} from "../../../src/libraries/Fee.sol";
import {Position} from "../../../src/positions/Position.sol";
import {IMarket} from "../../../src/markets/interfaces/IMarket.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {Pricing} from "../../../src/libraries/Pricing.sol";
import {Order} from "../../../src/positions/Order.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Fee} from "../../../src/libraries/Fee.sol";

contract TestAlternativeOrders is Test {
    using SignedMath for int256;
    using stdStorage for StdStorage;

    RoleStorage roleStorage;
    GlobalMarketConfig globalMarketConfig;
    LiquidityVault liquidityVault;
    MarketMaker marketMaker;
    StateUpdater stateUpdater;
    IPriceFeed priceFeed; // Deployed in Helper Config
    TradeStorage tradeStorage;
    ReferralStorage referralStorage;
    Processor processor;
    Router router;
    address OWNER;

    address weth;
    address usdc;
    bytes32 ethPriceId;
    bytes32 usdcPriceId;

    bytes[] tokenUpdateData;
    uint256[] allocations;

    address USER = makeAddr("USER");

    function setUp() public {
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;
        globalMarketConfig = contracts.globalMarketConfig;
        liquidityVault = contracts.liquidityVault;
        marketMaker = contracts.marketMaker;
        stateUpdater = contracts.stateUpdater;
        priceFeed = contracts.priceFeed;
        tradeStorage = contracts.tradeStorage;
        referralStorage = contracts.referralStorage;
        processor = contracts.processor;
        router = contracts.router;
        OWNER = contracts.owner;
        ethPriceId = deploy.ethPriceId();
        usdcPriceId = deploy.usdcPriceId();
        weth = deploy.weth();
        usdc = deploy.usdc();
        // Set Update Data
        bytes memory wethUpdateData = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 250000, 50, -2, 250000, 50, uint64(block.timestamp), uint64(block.timestamp)
        );
        bytes memory usdcUpdateData = priceFeed.createPriceFeedUpdateData(
            usdcPriceId, 1, 0, 0, 1, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        tokenUpdateData.push(wethUpdateData);
        tokenUpdateData.push(usdcUpdateData);
    }

    receive() external payable {}

    modifier setUpMarkets() {
        vm.deal(OWNER, 1_000_000 ether);
        MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);
        vm.deal(USER, 1_000_000 ether);
        MockUSDC(usdc).mint(USER, 1_000_000_000e6);
        vm.startPrank(OWNER);
        WETH(weth).deposit{value: 50 ether}();
        Oracle.Asset memory wethData = Oracle.Asset({
            isValid: true,
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            priceSpread: 0.1e18,
            priceProvider: Oracle.PriceProvider.PYTH,
            assetType: Oracle.AssetType.CRYPTO
        });
        marketMaker.createNewMarket(weth, ethPriceId, wethData);
        vm.stopPrank();
        // Construct the deposit input
        Deposit.Input memory input = Deposit.Input({
            owner: OWNER,
            tokenIn: weth,
            amountIn: 20_000 ether,
            executionFee: 0.01 ether,
            shouldWrap: true
        });
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(input, tokenUpdateData);
        bytes32 depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit(depositKey, 0);

        // Construct the deposit input
        input = Deposit.Input({
            owner: OWNER,
            tokenIn: usdc,
            amountIn: 50_000_000e6,
            executionFee: 0.01 ether,
            shouldWrap: false
        });
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        depositKey = liquidityVault.getDepositRequestAtIndex(0).key;
        processor.executeDeposit(depositKey, 0);
        vm.stopPrank();
        vm.startPrank(OWNER);
        address wethMarket = marketMaker.tokenToMarkets(weth);
        stateUpdater.addMarket(IMarket(wethMarket));
        uint256 allocation = 10000;
        uint256 encodedAllocation = allocation << 240;
        allocations.push(encodedAllocation);
        stateUpdater.setAllocationsWithBits(allocations);
        assertEq(IMarket(wethMarket).percentageAllocation(), 10000);
        vm.stopPrank();
        _;
    }

    /**
     * Test:
     * - Shouldnt be able to cancel orders before delay
     * - Stop Loss and Take Profit Orders
     */
    function testAUserCantCancelAnOrderBeforeDelay() public setUpMarkets {
        // create a position
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);

        // get key
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);

        vm.prank(USER);
        vm.expectRevert();
        router.cancelOrderRequest(key, false);
    }

    function testAUserCanCancelAnOrderAfterDelayHasPassed() public setUpMarkets {
        // create a position
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);

        // get key
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);

        vm.roll(block.number + 11);

        vm.prank(USER);
        router.cancelOrderRequest(key, false);

        assertEq(tradeStorage.getOrder(key).user, address(0));
    }

    function testAUserCanOpenAStopLossAndTakeProfitWithAnOrder() public setUpMarkets {
        // create a position
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: true,
                takeProfitSet: true,
                stopLossPrice: 2400e18,
                takeProfitPrice: 2600e18,
                stopLossPercentage: 1e18,
                takeProfitPercentage: 1e18
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);

        // get key
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        // execute the order
        vm.prank(OWNER);
        processor.executePosition(
            key, OWNER, false, Oracle.TradingEnabled({forex: false, equity: false, commodity: false, prediction: false})
        );

        // the position
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));
        bytes32[] memory positionKeys = tradeStorage.getOpenPositionKeys(address(market), true);
        Position.Data memory position = tradeStorage.getPosition(positionKeys[0]);

        bytes32 slKey = position.stopLossKey;
        bytes32 tpKey = position.takeProfitKey;

        Position.Request memory sl = tradeStorage.getOrder(slKey);
        Position.Request memory tp = tradeStorage.getOrder(tpKey);

        assertEq(sl.user, USER);
        assertEq(tp.user, USER);
        assertEq(sl.input.sizeDelta, 4 ether);
        assertEq(tp.input.sizeDelta, 4 ether);
    }

    function testAUserCanOverwriteExistingStopLossAndTakeProfitOrders() public setUpMarkets {
        // create a position
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: true,
                takeProfitSet: true,
                stopLossPrice: 2400e18,
                takeProfitPrice: 2600e18,
                stopLossPercentage: 1e18,
                takeProfitPercentage: 1e18
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);

        // get key
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        // execute the order
        vm.prank(OWNER);
        processor.executePosition(
            key, OWNER, false, Oracle.TradingEnabled({forex: false, equity: false, commodity: false, prediction: false})
        );

        // the position
        IMarket market = IMarket(marketMaker.tokenToMarkets(weth));
        bytes32[] memory positionKeys = tradeStorage.getOpenPositionKeys(address(market), true);

        Position.Data memory position = tradeStorage.getPosition(positionKeys[0]);

        bytes32 slBefore = position.stopLossKey;
        bytes32 tpBefore = position.takeProfitKey;

        Position.Conditionals memory newConditionals = Position.Conditionals({
            stopLossSet: true,
            takeProfitSet: true,
            stopLossPrice: 2300e18,
            takeProfitPrice: 2700e18,
            stopLossPercentage: 0.5e18,
            takeProfitPercentage: 0.5e18
        });
        vm.prank(USER);
        router.createEditOrder{value: 0.01 ether}(newConditionals, 0.01 ether, positionKeys[0]);

        position = tradeStorage.getPosition(positionKeys[0]);
        bytes32 slKey = position.stopLossKey;
        bytes32 tpKey = position.takeProfitKey;

        Position.Request memory sl = tradeStorage.getOrder(slKey);
        Position.Request memory tp = tradeStorage.getOrder(tpKey);

        assertEq(sl.user, USER);
        assertEq(tp.user, USER);
        assertEq(sl.input.sizeDelta, 2 ether);
        assertEq(tp.input.sizeDelta, 2 ether);

        // check the old sl / tp were deleted
        assertEq(tradeStorage.getOrder(slBefore).user, address(0));
        assertEq(tradeStorage.getOrder(tpBefore).user, address(0));
    }

    function testGasRefundsForCancellations() public setUpMarkets {
        // create a position
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: true,
                takeProfitSet: true,
                stopLossPrice: 2400e18,
                takeProfitPrice: 2600e18,
                stopLossPercentage: 1e18,
                takeProfitPercentage: 1e18
            })
        });
        vm.prank(USER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);

        vm.roll(block.number + 11);

        uint256 balanceBefore = USER.balance;

        // get key
        bytes32 key = tradeStorage.getOrderAtIndex(0, true);

        vm.prank(USER);
        router.cancelOrderRequest(key, true);

        uint256 balanceAfter = USER.balance;

        assertGt(balanceAfter, balanceBefore);
    }
}
