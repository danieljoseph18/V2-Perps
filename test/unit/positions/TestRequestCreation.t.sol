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
import {Gas} from "../../../src/libraries/Gas.sol";

contract TestRequestCreation is Test {
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
            priceProvider: Oracle.PriceProvider.PYTH,
            assetType: Oracle.AssetType.CRYPTO,
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
        marketMaker.createNewMarket(wethVaultDetails, weth, ethPriceId, wethData);
        vm.stopPrank();
        address wethMarket = marketMaker.tokenToMarkets(weth);
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
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, input, tokenUpdateData);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit(market, depositKey, 0);

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
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, input, tokenUpdateData);
        depositKey = market.getDepositRequestAtIndex(0).key;
        processor.executeDeposit(market, depositKey, 0);
        vm.stopPrank();
        vm.startPrank(OWNER);
        uint256 allocation = 10000;
        uint256 encodedAllocation = allocation << 240;
        allocations.push(encodedAllocation);
        market.setAllocationsWithBits(allocations);
        assertEq(market.getAllocation(weth), 10000);
        vm.stopPrank();
        _;
    }

    //////////////////
    // CONDITIONALS //
    //////////////////

    // @fail
    function testFuzzingConditionalValues(
        uint256 _stopLossPrice,
        uint256 _takeProfitPrice,
        uint256 _stopLossPercentage,
        uint256 _takeProfitPercentage
    ) external setUpMarkets {
        _stopLossPrice = bound(_stopLossPrice, 1, 2487.5e18);
        _takeProfitPrice = bound(_takeProfitPrice, 2512.5e18, 5000e18);
        _stopLossPercentage = bound(_stopLossPercentage, 1, 1e18);
        _takeProfitPercentage = bound(_takeProfitPercentage, 1, 1e18);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 4 ether,
            sizeDelta: 100_000e30,
            limitPrice: 0,
            maxSlippage: 0.003e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: true,
            shouldWrap: true,
            conditionals: Position.Conditionals({
                stopLossSet: true,
                takeProfitSet: true,
                stopLossPrice: _stopLossPrice,
                takeProfitPrice: _takeProfitPrice,
                stopLossPercentage: _stopLossPercentage,
                takeProfitPercentage: _takeProfitPercentage
            })
        });
        vm.prank(OWNER);
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
    }

    ///////////////////
    // EXECUTION FEE //
    ///////////////////

    function testFuzzingValidExecutionFees(uint256 _executionFee) public setUpMarkets {
        vm.txGasPrice(1e3);
        uint256 expGasLimit = Gas.getLimitForAction(processor, Gas.Action.POSITION);
        uint256 minFee = Gas.getMinExecutionFee(processor, expGasLimit);
        _executionFee = bound(_executionFee, minFee, 1 ether);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 4 ether,
            sizeDelta: 100_000e30,
            limitPrice: 0,
            maxSlippage: 0.003e18,
            executionFee: _executionFee,
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
        router.createPositionRequest{value: 4 ether + _executionFee}(input, tokenUpdateData);
    }

    function testFuzzingValidExecutionFeesShort(uint256 _executionFee) public setUpMarkets {
        vm.txGasPrice(1e3);
        uint256 expGasLimit = Gas.getLimitForAction(processor, Gas.Action.POSITION);
        uint256 minFee = Gas.getMinExecutionFee(processor, expGasLimit);
        _executionFee = bound(_executionFee, minFee, 1 ether);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 10_000e6,
            sizeDelta: 100_000e30,
            limitPrice: 0,
            maxSlippage: 0.003e18,
            executionFee: _executionFee,
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
        router.createPositionRequest{value: _executionFee}(input, tokenUpdateData);
        vm.stopPrank();
    }

    function testFuzzingInvalidExecutionFees(uint256 _executionFee) public setUpMarkets {
        // Set the Gas Price so min fee != 0
        vm.txGasPrice(1e9);
        uint256 expGasLimit = Gas.getLimitForAction(processor, Gas.Action.POSITION);
        uint256 minFee = Gas.getMinExecutionFee(processor, expGasLimit);
        _executionFee = bound(_executionFee, 0, minFee - 1);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 4 ether,
            sizeDelta: 100_000e30,
            limitPrice: 0,
            maxSlippage: 0.003e18,
            executionFee: _executionFee,
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
        vm.expectRevert();
        router.createPositionRequest{value: 4 ether + _executionFee}(input, tokenUpdateData);
    }

    ////////////////
    // LIMIT PRICE//
    ////////////////

    // @fail
    function testFuzzingInvalidLimitPrices(uint256 _limitPrice) public setUpMarkets {
        vm.assume(_limitPrice > 2500e18);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 4 ether,
            sizeDelta: 100_000e30,
            limitPrice: _limitPrice,
            maxSlippage: 0.003e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
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
        vm.expectRevert();
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
    }

    function testFuzzingInvalidLimitPricesShort(uint256 _limitPrice) public setUpMarkets {
        vm.assume(_limitPrice < 2500e18);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 10_000e6,
            sizeDelta: 100_000e30,
            limitPrice: _limitPrice,
            maxSlippage: 0.003e18,
            executionFee: 0.01 ether,
            isLong: false,
            isLimit: true,
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
        vm.expectRevert();
        router.createPositionRequest{value: 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
    }

    function testFuzzingLimitPriceWithinBounds(uint256 _limitPrice) public setUpMarkets {
        _limitPrice = bound(_limitPrice, 1, 2500e18);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 4 ether,
            sizeDelta: 100_000e30,
            limitPrice: _limitPrice,
            maxSlippage: 0.003e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
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
    }

    function testFuzzingLimitPriceWithinBoundsShort(uint256 _limitPrice) public setUpMarkets {
        vm.assume(_limitPrice > 2500e18);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 10_000e6,
            sizeDelta: 100_000e30,
            limitPrice: _limitPrice,
            maxSlippage: 0.003e18,
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
        router.createPositionRequest{value: 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
    }

    ////////////////
    // SIZE DELTA //
    ////////////////

    function testFuzzingSizeDeltaAboveBound(uint256 _sizeDelta) public setUpMarkets {
        vm.assume(_sizeDelta > 1_000_000e30);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 4 ether,
            sizeDelta: _sizeDelta,
            limitPrice: 0,
            maxSlippage: 0.003e18,
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
        vm.expectRevert();
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
    }

    function testFuzzingSizeDeltaBelowBound(uint256 _sizeDelta) public setUpMarkets {
        vm.assume(_sizeDelta < 10_000e30);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 4 ether,
            sizeDelta: _sizeDelta,
            limitPrice: 0,
            maxSlippage: 0.003e18,
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
        vm.expectRevert();
        router.createPositionRequest{value: 4.01 ether}(input, tokenUpdateData);
    }

    function testFuzzingSizeDeltaWithinBounds(uint256 _sizeDelta) public setUpMarkets {
        _sizeDelta = bound(_sizeDelta, 10_000e30, 1_000_000e30);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: 4 ether,
            sizeDelta: _sizeDelta,
            limitPrice: 0,
            maxSlippage: 0.003e18,
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
    }

    function testFuzzingSizeDeltaWithinBoundsShort(uint256 _sizeDelta) public setUpMarkets {
        _sizeDelta = bound(_sizeDelta, 10_000e30, 1_000_000e30);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: 10_000e6,
            sizeDelta: _sizeDelta,
            limitPrice: 0,
            maxSlippage: 0.003e18,
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
        router.createPositionRequest{value: 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
    }

    //////////////////////
    // COLLATERAL DELTA //
    //////////////////////

    // @fail
    function testFuzzingCollateralDeltaBelowBound(uint256 _collateralDelta) public setUpMarkets {
        vm.assume(_collateralDelta < 100e30);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: _collateralDelta,
            sizeDelta: 10_000e30, // 10k
            limitPrice: 0,
            maxSlippage: 0.003e18,
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
        vm.expectRevert();
        router.createPositionRequest{value: _collateralDelta + 0.01 ether}(input, tokenUpdateData);
    }

    function testFuzzingCollateralDeltaBelowBoundShort(uint256 _collateralDelta) public setUpMarkets {
        vm.assume(_collateralDelta < 100e6);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: _collateralDelta,
            sizeDelta: 10_000e30, // 10k
            limitPrice: 0,
            maxSlippage: 0.003e18,
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
        vm.expectRevert();
        router.createPositionRequest{value: _collateralDelta + 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
    }

    function testFuzzingCollateralDeltaAboveBound(uint256 _collateralDelta) public setUpMarkets {
        vm.assume(_collateralDelta > 10_000e30);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: _collateralDelta,
            sizeDelta: 10_000e30, // 10k
            limitPrice: 0,
            maxSlippage: 0.003e18,
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
        vm.expectRevert();
        router.createPositionRequest{value: _collateralDelta + 0.01 ether}(input, tokenUpdateData);
    }

    // @fail
    function testFuzzingCollateralDeltaWithinBounds(uint256 _collateralDelta) public setUpMarkets {
        // Bound the input between 1 and 4 ether
        _collateralDelta = bound(_collateralDelta, 100e30, 10_000e30);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: weth,
            collateralDelta: _collateralDelta,
            sizeDelta: 10_000e30, // 10k
            limitPrice: 0,
            maxSlippage: 0.003e18,
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
        router.createPositionRequest{value: _collateralDelta + 0.01 ether}(input, tokenUpdateData);
    }

    function testFuzzingCollateralDeltaWithinBounsShort(uint256 _collateralDelta) public setUpMarkets {
        // Bound the input between 1 and 4 ether
        _collateralDelta = bound(_collateralDelta, 100e6, 10_000e6);
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: usdc,
            collateralDelta: _collateralDelta,
            sizeDelta: 10_000e30, // 10k
            limitPrice: 0,
            maxSlippage: 0.003e18,
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
        router.createPositionRequest{value: _collateralDelta + 0.01 ether}(input, tokenUpdateData);
        vm.stopPrank();
    }

    function testCreatingAPositionWithInvalidIndexToken(address _randomToken) public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: _randomToken,
            collateralToken: weth,
            collateralDelta: 0.5 ether,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.003e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
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
        vm.expectRevert();
        router.createPositionRequest(input, tokenUpdateData);
    }

    function testCreatingAPositionWithInvalidCollateralToken(address _randomToken) public setUpMarkets {
        Position.Input memory input = Position.Input({
            indexToken: weth,
            collateralToken: _randomToken,
            collateralDelta: 0.5 ether,
            sizeDelta: 10_000e30,
            limitPrice: 0,
            maxSlippage: 0.003e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
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
        vm.expectRevert();
        router.createPositionRequest(input, tokenUpdateData);
    }
}
