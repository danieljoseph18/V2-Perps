// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console} from "forge-std/Test.sol";
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

contract TestRequestExecution is Test {
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
        vm.startPrank(OWNER);
        WETH(weth).deposit{value: 50 ether}();
        Oracle.Asset memory wethData = Oracle.Asset({
            isValid: true,
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
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

    function testWhereTokensEndUp() public setUpMarkets {
        // Create a Position
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.01e18,
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
        uint256 processorBalanceBefore = WETH(weth).balanceOf(address(processor));
        vm.prank(OWNER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
        // Check that the tokens for the position are stored in the Processor contract
        uint256 processorBalanceAfter = WETH(weth).balanceOf(address(processor));
        assertEq(processorBalanceAfter - processorBalanceBefore, 0.5 ether);
        // Execute the Position
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        uint256 liquidityVaultBalance = WETH(weth).balanceOf(address(liquidityVault));
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);
        // Check that the tokens for the position are stored in the Liquidity Vault contract
        uint256 processorBalanceAfterExecution = WETH(weth).balanceOf(address(processor));
        assertEq(processorBalanceAfterExecution, 0);
        uint256 liquidityVaultBalanceAfter = WETH(weth).balanceOf(address(liquidityVault));
        assertEq(liquidityVaultBalanceAfter - liquidityVaultBalance, 0.5 ether);
    }

    function testImpactPoolIsUpdatedForPriceImpact() public setUpMarkets {
        // Create a Position
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.01e18,
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
        vm.prank(OWNER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
        // Execute the Position
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        // Get the size of the impact pool before the position is executed
        uint256 impactPoolBefore = IMarket(marketMaker.tokenToMarkets(weth)).longImpactPoolUsd();
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);
        // Get the size of the impact pool after the position is executed
        uint256 impactPoolAfter = IMarket(marketMaker.tokenToMarkets(weth)).longImpactPoolUsd();
        // Check that the impact pool has been updated
        assertGt(impactPoolAfter, impactPoolBefore);
    }

    function testPnlParamsAreBasedOnPriceAtTheRequestBlock() public setUpMarkets {
        // Create a request
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.01e18,
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
        vm.prank(OWNER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
        // Pass some time
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // Update Prices
        bytes memory wethUpdateData = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 300000, 50, -2, 300000, 50, uint64(block.timestamp), uint64(block.timestamp)
        );
        // Create usdc update data with a price of 1.05
        bytes memory usdcUpdateData = priceFeed.createPriceFeedUpdateData(
            usdcPriceId, 105, 0, -2, 105, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        tokenUpdateData[0] = wethUpdateData;
        tokenUpdateData[1] = usdcUpdateData;
        vm.prank(OWNER);
        priceFeed.signPriceData{value: 2 gwei}(weth, tokenUpdateData);
        // Execute the position and check the prices
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);
        // Check that the prices are based on the price at the request block
        bytes32 positionKey = keccak256(abi.encode(weth, OWNER, true));
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        // Should be ~ 2500 instead of 3000
        console.log("Entry Price: ", position.weightedAvgEntryPrice);
    }

    // Price up 20%
    // Expected Profit: $2000 = 0.66 ether
    // Profit Received ~ 0.64 ether -> Accounts for Price Impact
    function testAUserReceivesProfitIfClosingAProfitablePosition() public setUpMarkets {
        // Create a request
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.01e18,
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
        vm.prank(OWNER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
        // Execute the position
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        vm.prank(OWNER);
        processor.executePosition(orderKey, OWNER, false, tradingEnabled);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Update the Price
        bytes memory wethUpdateData = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 300000, 50, -2, 300000, 50, uint64(block.timestamp), uint64(block.timestamp)
        );
        // Create usdc update data with a price of 1.05
        bytes memory usdcUpdateData = priceFeed.createPriceFeedUpdateData(
            usdcPriceId, 105, 0, -2, 105, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        tokenUpdateData[0] = wethUpdateData;
        tokenUpdateData[1] = usdcUpdateData;
        vm.prank(OWNER);
        priceFeed.signPriceData{value: 2 gwei}(weth, tokenUpdateData);
        // Create a close position request
        Position.Input memory closeInput = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 4 ether,
            limitPrice: 0,
            maxSlippage: 0.01e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: false,
            shouldWrap: true, // Receive Ether
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.prank(OWNER);
        router.createPositionRequest{value: 0.01 ether}(closeInput, tokenUpdateData);
        // Execute the close position request
        bytes32 closeOrderKey = tradeStorage.getOrderAtIndex(0, false);
        uint256 balanceBefore = OWNER.balance;
        vm.prank(OWNER);
        processor.executePosition(closeOrderKey, OWNER, false, tradingEnabled);
        uint256 balanceAfter = OWNER.balance;
        // Check that the user receives profit
        assertGt(balanceAfter, balanceBefore);
        console.log("Profit Received: ", balanceAfter - balanceBefore);
    }
}
