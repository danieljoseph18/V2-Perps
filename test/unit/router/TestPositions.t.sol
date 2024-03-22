// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";

import {Market, IMarket, IVault} from "../../../src/markets/Market.sol";
import {MarketMaker, IMarketMaker} from "../../../src/markets/MarketMaker.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage, ITradeStorage} from "../../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../../../src/router/PositionManager.sol";
import {Router} from "../../../src/router/Router.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Fee} from "../../../src/libraries/Fee.sol";
import {Position} from "../../../src/positions/Position.sol";

contract TestPositions is Test {
    RoleStorage roleStorage;

    MarketMaker marketMaker;
    IPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
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

        marketMaker = contracts.marketMaker;
        priceFeed = contracts.priceFeed;
        referralStorage = contracts.referralStorage;
        positionManager = contracts.positionManager;
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
            positionManager: address(positionManager),
            poolOwner: OWNER,
            feeDistributor: OWNER,
            name: "WETH/USDC",
            symbol: "WETH/USDC"
        });
        marketMaker.createNewMarket(wethVaultDetails, ethAssetId, ethPriceId, wethData);
        vm.stopPrank();
        address wethMarket = marketMaker.tokenToMarkets(ethAssetId);
        market = Market(payable(wethMarket));
        tradeStorage = market.tradeStorage();

        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, OWNER, weth, 20_000 ether, 0.01 ether, true);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
        depositKey = market.getDepositRequestAtIndex(0).key;
        positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
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
            reverseWrap: false,
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
        router.createPositionRequest{value: 0.01 ether}(input);
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether}(input);
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
            reverseWrap: false,
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
        router.createPositionRequest{value: 0.01 ether}(input);
        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
        router.createPositionRequest{value: 0.51 ether}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
            reverseWrap: false,
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
        router.createPositionRequest{value: 0.01 ether}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
        router.createPositionRequest{value: 0.51 ether}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
            reverseWrap: false,
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
        router.createPositionRequest{value: 0.01 ether}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
            reverseWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        router.createPositionRequest{value: 0.01 ether}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
        router.createPositionRequest{value: 0.51 ether}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
        vm.stopPrank();
    }

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
            reverseWrap: false,
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
        router.createPositionRequest{value: 0.01 ether}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
            reverseWrap: false,
            conditionals: Position.Conditionals({
                stopLossSet: false,
                takeProfitSet: false,
                stopLossPrice: 0,
                takeProfitPrice: 0,
                stopLossPercentage: 0,
                takeProfitPercentage: 0
            })
        });
        router.createPositionRequest{value: 0.01 ether}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
        vm.stopPrank();
    }

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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
        bytes32 positionKey = keccak256(abi.encode(input.assetId, OWNER, input.isLong));
        Position.Data memory position = tradeStorage.getPosition(positionKey);
        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: position.collateralAmount,
            sizeDelta: 5000e30, // 4x leverage
            limitPrice: 0, // Market Order
            maxSlippage: 0.43e18, // 0.3%
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: false,
            isIncrease: false,
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
        router.createPositionRequest{value: 0.01 ether}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
        vm.stopPrank();
        // Check the position was removed from storage
        position = tradeStorage.getPosition(positionKey);
        assertEq(position.positionSize, 0);
    }

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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether}(input);

        bytes32 key = tradeStorage.getOrderAtIndex(0, false);
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
        router.createPositionRequest{value: 0.01 ether}(input);
        key = tradeStorage.getOrderAtIndex(0, false);
        uint256 balanceBeforeDecrease = OWNER.balance;
        positionManager.executePosition{value: 0.0001 ether}(market, key, OWNER, ethPriceData);
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
