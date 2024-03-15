// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
import {Market, IMarket, IVault} from "../../../src/markets/Market.sol";
import {MarketMaker, IMarketMaker} from "../../../src/markets/MarketMaker.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage} from "../../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {Processor} from "../../../src/router/Processor.sol";
import {Router} from "../../../src/router/Router.sol";
import {Deposit} from "../../../src/markets/Deposit.sol";
import {Withdrawal} from "../../../src/markets/Withdrawal.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Fee} from "../../../src/libraries/Fee.sol";
import {Position} from "../../../src/positions/Position.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";

contract TestRequestExecution is Test {
    RoleStorage roleStorage;
    GlobalMarketConfig globalMarketConfig;
    MarketMaker marketMaker;
    IPriceFeed priceFeed; // Deployed in Helper Config
    TradeStorage tradeStorage;
    ReferralStorage referralStorage;
    Processor processor;
    Router router;
    address OWNER;
    Market market;

    address weth;
    address usdc;
    bytes32 ethPriceId;
    bytes32 usdcPriceId;

    bytes[] tokenUpdateData;
    uint256[] allocations;
    bytes32[] assetIds;
    uint256[] compactedPrices;

    Oracle.PriceUpdateData ethPriceData;

    address USER = makeAddr("USER");

    bytes32 ethAssetId = keccak256(abi.encode("ETH"));
    bytes32 usdcAssetId = keccak256(abi.encode("USDC"));

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();
        roleStorage = contracts.roleStorage;
        globalMarketConfig = contracts.globalMarketConfig;
        marketMaker = contracts.marketMaker;
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
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // Set Update Data
        bytes memory wethUpdateData = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 250000, 50, -2, 250000, 50, uint64(block.timestamp), uint64(block.timestamp)
        );
        bytes memory usdcUpdateData = priceFeed.createPriceFeedUpdateData(
            usdcPriceId, 1, 0, 0, 1, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        tokenUpdateData.push(wethUpdateData);
        tokenUpdateData.push(usdcUpdateData);
        assetIds.push(ethAssetId);
        assetIds.push(usdcAssetId);

        ethPriceData =
            Oracle.PriceUpdateData({assetIds: assetIds, pythData: tokenUpdateData, compactedPrices: compactedPrices});
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
            primaryStrategy: Oracle.PrimaryStrategy.PYTH,
            secondaryStrategy: Oracle.SecondaryStrategy.NONE,
            pool: Oracle.UniswapPool({
                token0: weth,
                token1: usdc,
                poolAddress: address(0),
                poolType: Oracle.PoolType.UNISWAP_V3
            })
        });
        IVault.VaultConfig memory wethVaultDetails = IVault.VaultConfig({
            longToken: weth,
            shortToken: usdc,
            longBaseUnit: 1e18,
            shortBaseUnit: 1e6,
            feeScale: 0.03e18,
            feePercentageToOwner: 0.2e18,
            minTimeToExpiration: 1 minutes,
            priceFeed: address(priceFeed),
            processor: address(processor),
            poolOwner: OWNER,
            feeDistributor: OWNER,
            name: "WETH/USDC",
            symbol: "WETH/USDC"
        });
        marketMaker.createNewMarket(wethVaultDetails, ethAssetId, ethPriceId, wethData);
        vm.stopPrank();
        address wethMarket = marketMaker.tokenToMarkets(ethAssetId);
        market = Market(payable(wethMarket));
        // Construct the deposit input
        Deposit.Input memory input = Deposit.Input({
            owner: OWNER,
            tokenIn: weth,
            amountIn: 20_000 ether,
            executionFee: 0.01 ether,
            reverseWrap: true
        });
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, input);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);

        // Construct the deposit input
        input = Deposit.Input({
            owner: OWNER,
            tokenIn: usdc,
            amountIn: 50_000_000e6,
            executionFee: 0.01 ether,
            reverseWrap: false
        });
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, input);
        depositKey = market.getDepositRequestAtIndex(0).key;
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
        vm.stopPrank();
        vm.startPrank(OWNER);
        uint256 allocation = 10000;
        uint256 encodedAllocation = allocation << 240;
        allocations.push(encodedAllocation);
        market.setAllocationsWithBits(allocations);
        assertEq(market.getAllocation(ethAssetId), 10000);
        vm.stopPrank();
        _;
    }

    function testWhereTokensEndUp() public setUpMarkets {
        // Create a Position
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            reverseWrap: true,
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
        router.createPositionRequest{value: 0.51 ether}(input);
        // Check that the tokens for the position are stored in the Processor contract
        uint256 processorBalanceAfter = WETH(weth).balanceOf(address(processor));
        assertEq(processorBalanceAfter - processorBalanceBefore, 0.5 ether);
        // Execute the Position
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);
        uint256 vaultBalance = WETH(weth).balanceOf(address(market));
        vm.prank(OWNER);
        processor.executePosition{value: 0.0001 ether}(orderKey, OWNER, ethPriceData);
        // Check that the tokens for the position are stored in the Market contract
        uint256 processorBalanceAfterExecution = WETH(weth).balanceOf(address(processor));
        assertEq(processorBalanceAfterExecution, 0);
        uint256 vaultBalanceAfter = WETH(weth).balanceOf(address(market));
        assertEq(vaultBalanceAfter - vaultBalance, 0.5 ether);
    }

    function testImpactPoolIsUpdatedForPriceImpact() public setUpMarkets {
        // Create a Position
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            reverseWrap: true,
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
        router.createPositionRequest{value: 0.51 ether}(input);
        // Execute the Position
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);

        // Get the size of the impact pool before the position is executed
        uint256 impactPoolBefore = IMarket(marketMaker.tokenToMarkets(ethAssetId)).getImpactPool(ethAssetId);
        vm.prank(OWNER);
        processor.executePosition{value: 0.0001 ether}(orderKey, OWNER, ethPriceData);
        // Get the size of the impact pool after the position is executed
        uint256 impactPoolAfter = IMarket(marketMaker.tokenToMarkets(ethAssetId)).getImpactPool(ethAssetId);
        // Check that the impact pool has been updated
        assertGt(impactPoolAfter, impactPoolBefore);
    }

    function testPnlParamsAreBasedOnPriceAtTheRequestBlock() public setUpMarkets {
        // Create a request
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            reverseWrap: true,
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
        router.createPositionRequest{value: 0.51 ether}(input);
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

        // Execute the position and check the prices
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);

        vm.prank(OWNER);
        processor.executePosition{value: 0.0001 ether}(orderKey, OWNER, ethPriceData);
        // Check that the prices are based on the price at the request block
        bytes32 positionKey = keccak256(abi.encode(ethAssetId, OWNER, input.isLong));
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
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            reverseWrap: true,
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
        router.createPositionRequest{value: 0.51 ether}(input);
        // Execute the position
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);

        vm.prank(OWNER);
        processor.executePosition{value: 0.0001 ether}(orderKey, OWNER, ethPriceData);

        vm.warp(block.timestamp + 100 seconds);
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

        // get the position
        bytes32 positionKey = keccak256(abi.encode(ethAssetId, OWNER, input.isLong));
        Position.Data memory position = tradeStorage.getPosition(positionKey);

        // Create a close position request
        Position.Input memory closeInput = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: position.collateralAmount,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: false,
            reverseWrap: true, // Receive Ether
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
        router.createPositionRequest{value: 0.01 ether}(closeInput);
        // Execute the close position request
        bytes32 closeOrderKey = tradeStorage.getOrderAtIndex(0, false);
        uint256 balanceBefore = OWNER.balance;
        vm.prank(OWNER);
        processor.executePosition{value: 0.0001 ether}(closeOrderKey, OWNER, ethPriceData);
        uint256 balanceAfter = OWNER.balance;
        // Check that the user receives profit
        assertGt(balanceAfter, balanceBefore);
        console.log("Profit Received: ", balanceAfter - balanceBefore);
    }

    function testAUserAccruesLossesIfClosingAnUnprofitablePosition() public setUpMarkets {
        // Create a request
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            reverseWrap: true,
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
        router.createPositionRequest{value: 0.51 ether}(input);
        // Execute the position
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);

        vm.prank(OWNER);
        processor.executePosition{value: 0.0001 ether}(orderKey, OWNER, ethPriceData);

        vm.warp(block.timestamp + 100 seconds);
        vm.roll(block.number + 1);

        // Update the Price
        bytes memory wethUpdateData = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 240000, 50, -2, 240000, 50, uint64(block.timestamp), uint64(block.timestamp)
        );
        // Create usdc update data with a price of 1.05
        bytes memory usdcUpdateData = priceFeed.createPriceFeedUpdateData(
            usdcPriceId, 100, 0, -2, 100, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        tokenUpdateData[0] = wethUpdateData;
        tokenUpdateData[1] = usdcUpdateData;
        ethPriceData.pythData = tokenUpdateData;

        // get the position
        bytes32 positionKey = keccak256(abi.encode(ethAssetId, OWNER, input.isLong));
        Position.Data memory position = tradeStorage.getPosition(positionKey);

        // Create a close position request
        Position.Input memory closeInput = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: position.collateralAmount,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: false,
            reverseWrap: true, // Receive Ether
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
        router.createPositionRequest{value: 0.01 ether}(closeInput);
        // Execute the close position request
        bytes32 closeOrderKey = tradeStorage.getOrderAtIndex(0, false);
        uint256 balanceBefore = OWNER.balance;
        vm.prank(OWNER);
        processor.executePosition{value: 0.0001 ether}(closeOrderKey, OWNER, ethPriceData);
        uint256 balanceAfter = OWNER.balance;
        // Check that the user accrues losses
        uint256 expectedAmountOut = 0.5 ether;
        assertLt(balanceAfter - balanceBefore, expectedAmountOut);
        console.log("Amount Out: ", balanceAfter - balanceBefore);
    }

    function testMarketStateIsUpdatedForEachPositionExecution() public setUpMarkets {
        // Pass some time
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // create a request
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.04 ether,
            sizeDelta: 1000e30,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            reverseWrap: true,
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
        router.createPositionRequest{value: 0.05 ether}(input);
        // execute the request
        bytes32 orderKey = tradeStorage.getOrderAtIndex(0, false);

        vm.prank(OWNER);
        processor.executePosition{value: 0.0001 ether}(orderKey, OWNER, ethPriceData);
        // pass some time
        vm.warp(block.timestamp + 100 seconds);
        vm.roll(block.number + 1);
        // check the market parameters
        uint256 longOpenInterest = market.getOpenInterest(ethAssetId, true);
        assertEq(longOpenInterest, 1000e30);
        uint256 longAverageEntryPrice = market.getAverageEntryPrice(ethAssetId, true);
        assertNotEq(longAverageEntryPrice, 0);
        // Update the Price
        bytes memory wethUpdateData = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 230000, 50, -2, 230000, 50, uint64(block.timestamp), uint64(block.timestamp)
        );
        // Create usdc update data with a price of 1.05
        bytes memory usdcUpdateData = priceFeed.createPriceFeedUpdateData(
            usdcPriceId, 95, 0, -2, 95, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        tokenUpdateData[0] = wethUpdateData;
        tokenUpdateData[1] = usdcUpdateData;
        // create a request
        vm.prank(USER);
        router.createPositionRequest{value: 0.05 ether}(input);
        // execute the request
        orderKey = tradeStorage.getOrderAtIndex(0, false);
        vm.prank(OWNER);
        processor.executePosition{value: 0.0001 ether}(orderKey, OWNER, ethPriceData);
        // check the market parameters
        longOpenInterest = market.getOpenInterest(ethAssetId, true);
        assertEq(longOpenInterest, 2000e30);
        uint256 newLongWaep = market.getAverageEntryPrice(ethAssetId, true);
        assertNotEq(newLongWaep, longAverageEntryPrice);
        uint256 lastBorrowingUpdate = market.getLastBorrowingUpdate(ethAssetId);
        assertEq(lastBorrowingUpdate, block.timestamp);
        uint256 lastFundingUpdate = market.getLastFundingUpdate(ethAssetId);
        assertEq(lastFundingUpdate, block.timestamp);
        uint256 longBorrowingRate = market.getLastBorrowingUpdate(ethAssetId);
        assertNotEq(longBorrowingRate, 0);
    }

    function testPositionFeesAreCalculatedCorrectly() public setUpMarkets {
        // create a position
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            reverseWrap: true,
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
        router.createPositionRequest{value: 0.51 ether}(input);
        // predict the fee owed
        uint256 feeUsd = (10_000e30 * 0.001e18) / 1e18;
        uint256 predictedFee = Position.convertUsdToCollateral(feeUsd, 2500e30, 1e18);
        // compare it with the fee owed from the contract
        uint256 fee = Fee.calculateForPosition(tradeStorage, 10_000e30, 0.5 ether, 2500e30, 1e18);
        assertEq(predictedFee, fee);
    }
}
