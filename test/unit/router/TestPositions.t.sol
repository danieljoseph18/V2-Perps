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

contract TestPositions is Test {
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
            assetType: Oracle.AssetType.CRYPTO,
            pool: Oracle.UniswapPool({
                token0: weth,
                token1: usdc,
                poolAddress: address(0),
                poolType: Oracle.PoolType.UNISWAP_V3
            })
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
        stateUpdater.syncMarkets();
        uint256 allocation = 10000;
        uint256 encodedAllocation = allocation << 240;
        allocations.push(encodedAllocation);
        stateUpdater.setAllocationsWithBits(allocations);
        assertEq(IMarket(wethMarket).percentageAllocation(), 10000);
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
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 2 ether, // 4x leverage
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
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
    }

    function testCreateNewPositionShort() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 2e18, // 10x leverage
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        vm.stopPrank();
    }

    function testExecuteNewPositionLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 2 ether, // 4x leverage
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
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        vm.stopPrank();
    }

    function testExecuteNewPositionShort() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 2e18, // 10x leverage -> 2 eth ~ $5000
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        vm.stopPrank();
    }

    function testExecuteIncreaseExistingPositionLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 2 ether, // 4x leverage
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
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        vm.stopPrank();
    }

    function testPositionsAreWipedOnceExecuted() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 2 ether, // 4x leverage
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
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        vm.stopPrank();
        vm.expectRevert();
        key = tradeStorage.getOrderAtIndex(0, false);
    }

    function testExecuteIncreaseExistingPositionShort() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 2e18, // 10x leverage -> 2 eth ~ $5000
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        vm.stopPrank();
    }

    function testExecuteCollateralIncreaseShort() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 2e18, // 10x leverage -> 2 eth ~ $5000
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        input = Position.Input({
            indexToken: weth,
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        vm.stopPrank();
    }

    function testExecuteCollateralIncreaseLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 2 ether, // 4x leverage
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
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        input = Position.Input({
            indexToken: weth,
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
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        vm.stopPrank();
    }

    function testExecuteCollateralDecreaseShort() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 500e6,
            sizeDelta: 2e18, // 10x leverage -> 2 eth ~ $5000
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        input = Position.Input({
            indexToken: weth,
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        vm.stopPrank();
    }

    function testFullExecuteDecreasePositionLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 2 ether, // 4x leverage
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
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 2 ether, // 4x leverage
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        vm.stopPrank();
        // Check the position was removed from storage
        bytes32 positionKey = keccak256(abi.encode(input.indexToken, OWNER, input.isLong));
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        assertEq(position.positionSize, 0);
    }

    function testPartialExecuteDecreasePositionLong() public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 2 ether, // 4x leverage
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
        router.createPositionRequest{value: 0.51 ether + 1 gwei}(input, tokenUpdateData);
        Oracle.TradingEnabled memory tradingEnabled =
            Oracle.TradingEnabled({forex: true, equity: true, commodity: true, prediction: true});
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 0.25 ether,
            sizeDelta: 1 ether, // 4x leverage
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
        router.createPositionRequest{value: 0.01 ether + 1 gwei}(input, tokenUpdateData);
        key = tradeStorage.getOrderAtIndex(0, false);
        uint256 balanceBeforeDecrease = OWNER.balance;
        processor.executePosition(key, OWNER, tradingEnabled, tokenUpdateData, weth, 0);
        vm.stopPrank();
        bytes32 positionKey = keccak256(abi.encode(input.indexToken, OWNER, input.isLong));
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        uint256 balanceAfterDecrease = OWNER.balance;
        assertEq(position.collateralAmount, 0.25 ether);
        assertEq(position.positionSize, 1 ether);
        assertGt(balanceAfterDecrease, balanceBeforeDecrease);
    }
}
