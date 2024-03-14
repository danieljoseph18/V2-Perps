// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
import {Market, IMarket} from "../../../src/markets/Market.sol";
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
import {Pool} from "../../../src/markets/Pool.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Fee} from "../../../src/libraries/Fee.sol";
import {Position} from "../../../src/positions/Position.sol";

contract TestPositions is Test {
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

    address USER = makeAddr("USER");

    bytes32 ethAssetId = keccak256("ETH");
    bytes32 usdcAssetId = keccak256("USDC");

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
        Pool.VaultConfig memory wethVaultDetails = Pool.VaultConfig({
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
            shouldWrap: true
        });
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, input);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, 0, tokenUpdateData);

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
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, input);
        depositKey = market.getDepositRequestAtIndex(0).key;
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, 0, tokenUpdateData);
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

    /**
     * struct Input {
     *     address indexToken;
     *     address collateralToken;
     *     uint256 collateralDelta;
     *     uint256 sizeDelta;
     *     uint256 limitPrice;
     *     uint256 maxSlippage;
     *     uint256 executionFee;
     *     bool isLong;
     *     bool isLimit;
     *     bool isIncrease;
     *     bool shouldWrap;
     *     Conditionals conditionals;
     * }
     */
    function testCreateNewPositionLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 5000e30, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
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
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input);
    }

    function testCreateNewPositionShort() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 5000e30, // 10x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input);
        vm.stopPrank();
    }

    function testExecuteNewPositionLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 5000e30, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input);
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        vm.stopPrank();
    }

    function testExecuteNewPositionShort() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 5000e30, // 10x leverage -> 2 eth ~ $5000
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input);
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        vm.stopPrank();
    }

    function testExecuteIncreaseExistingPositionLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 5000e30, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        vm.stopPrank();
    }

    function testPositionsAreWipedOnceExecuted() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 5000e30, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        vm.stopPrank();
        vm.expectRevert();
        key = tradeStorage.getOrderAtIndex(0, false);
    }

    function testExecuteIncreaseExistingPositionShort() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 5000e30, // 10x leverage -> 2 eth ~ $5000
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        vm.stopPrank();
    }

    function testExecuteCollateralIncreaseShort() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 5000e30, // 10x leverage -> 2 eth ~ $5000
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 0, // 10x leverage -> 2 eth ~ $5000
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        vm.stopPrank();
    }

    function testExecuteCollateralIncreaseLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 5000e30, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 0, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
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
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        vm.stopPrank();
    }

    // @fail
    function testExecuteCollateralDecreaseShort() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 5000e30, // 10x leverage -> 2 eth ~ $5000
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: true,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: usdc,
            collateralDelta: 50e6,
            sizeDelta: 0, // 10x leverage -> 2 eth ~ $5000
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: false,
            isIncrease: false,
            shouldWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        vm.stopPrank();
    }

    // @fail
    function testFullExecuteDecreasePositionLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 5000e30, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 5000e30, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: false,
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        vm.stopPrank();
        // Check the position was removed from storage
        bytes32 positionKey = keccak256(abi.encode(input.assetId, OWNER, input.isLong));
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        assertEq(position.positionSize, 0);
    }

    // @fail
    function testPartialExecuteDecreasePositionLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 5000e30, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.25 ether,
            sizeDelta: 2500e30, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: false,
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        uint256 balanceBeforeDecrease = OWNER.balance;
        processor.executePosition{value: 0.0001 ether}(key, OWNER, tokenUpdateData, ethAssetId);
        vm.stopPrank();
        bytes32 positionKey = keccak256(abi.encode(input.assetId, OWNER, input.isLong));
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        uint256 balanceAfterDecrease = OWNER.balance;
        // Will be less after fees
        assertLt(position.collateralAmount, 0.25 ether);
        assertEq(position.positionSize, 2500e30);
        // Should have received some ETH
        assertGt(balanceAfterDecrease, balanceBeforeDecrease);
    }
}
