// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {Market, IMarket} from "../../../src/markets/Market.sol";
import {MarketMaker, IMarketMaker} from "../../../src/markets/MarketMaker.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage, ITradeStorage} from "../../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../../../src/router/PositionManager.sol";
import {Router} from "../../../src/router/Router.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Position} from "../../../src/positions/Position.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {MarketUtils} from "../../../src/markets/MarketUtils.sol";

contract TestSlTpOrders is Test {
    using SignedMath for int256;

    RoleStorage roleStorage;

    MarketMaker marketMaker;
    IPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    Router router;
    address OWNER;
    Market market;
    address feeDistributor;

    address weth;
    address usdc;
    bytes32 ethPriceId;
    bytes32 usdcPriceId;

    bytes[] tokenUpdateData;
    uint256[] allocations;

    address USER = makeAddr("USER");
    address RANDOM1 = makeAddr("RANDOM1");
    address RANDOM2 = makeAddr("RANDOM2");
    address RANDOM3 = makeAddr("RANDOM3");

    bytes32[] assetIds;
    uint256[] compactedPrices;

    Oracle.PriceUpdateData ethPriceData;

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
        feeDistributor = address(contracts.feeDistributor);
        OWNER = contracts.owner;
        (weth, usdc, ethPriceId, usdcPriceId,,,,) = deploy.activeNetworkConfig();
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
        IMarket.VaultConfig memory wethVaultDetails = IMarket.VaultConfig({
            longToken: weth,
            shortToken: usdc,
            longBaseUnit: 1e18,
            shortBaseUnit: 1e6,
            feeScale: 0.03e18,
            feePercentageToOwner: 0.2e18,
            minTimeToExpiration: 1 minutes,
            poolOwner: OWNER,
            feeDistributor: feeDistributor,
            name: "WETH/USDC",
            symbol: "WETH/USDC"
        });
        marketMaker.createNewMarket(wethVaultDetails, ethAssetId, ethPriceId, wethData);
        vm.stopPrank();
        address wethMarket = marketMaker.tokenToMarkets(ethAssetId);
        market = Market(payable(wethMarket));
        tradeStorage = ITradeStorage(market.tradeStorage());
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 10_000.01 ether + 1 gwei}(market, OWNER, weth, 10_000 ether, 0.01 ether, true);
        bytes32 depositKey = market.getRequestAtIndex(0).key;
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 25_000_000e6, 0.01 ether, false);
        depositKey = market.getRequestAtIndex(0).key;
        positionManager.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
        vm.stopPrank();
        vm.startPrank(OWNER);
        uint256 allocation = 10000;
        uint256 encodedAllocation = allocation << 240;
        allocations.push(encodedAllocation);
        market.setAllocationsWithBits(allocations);
        assertEq(MarketUtils.getAllocation(market, ethAssetId), 10000);
        vm.stopPrank();
        _;
    }

    function testCreatingAStopLossOrderDirectly() public setUpMarkets {
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether}(input);
        positionManager.executePosition{value: 0.0001 ether}(
            market, tradeStorage.getOrderAtIndex(0, false), OWNER, ethPriceData
        );
        vm.stopPrank();
        // Create a limit decrease with trigger price < entry price

        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.25 ether,
            sizeDelta: 5000e30,
            limitPrice: 2000e30,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
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

        vm.prank(OWNER);
        router.createPositionRequest{value: 0.01 ether}(input);
    }

    function testCreatingATakeProfitOrderDirectly() public setUpMarkets {
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether}(input);
        positionManager.executePosition{value: 0.0001 ether}(
            market, tradeStorage.getOrderAtIndex(0, false), OWNER, ethPriceData
        );
        vm.stopPrank();
        // Create a limit decrease with trigger price < entry price

        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.25 ether,
            sizeDelta: 5000e30,
            limitPrice: 5000e30,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
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

        vm.prank(OWNER);
        router.createPositionRequest{value: 0.01 ether}(input);
    }

    function testExecutingAStopLossOrderTiesItToThePosition() public setUpMarkets {
        // Create a Position
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 2 ether,
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 2.01 ether}(input);
        positionManager.executePosition{value: 0.0001 ether}(
            market, tradeStorage.getOrderAtIndex(0, false), OWNER, ethPriceData
        );
        vm.stopPrank();

        // Create a limit decrease with trigger price < entry price
        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 1 ether,
            sizeDelta: 5000e30,
            limitPrice: 2000e30,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
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

        vm.prank(OWNER);
        router.createPositionRequest{value: 0.01 ether}(input);

        // Check the SL is linked
        bytes32 posKey = keccak256(abi.encode(ethAssetId, OWNER, true));
        bytes32 slKey = tradeStorage.getOrderAtIndex(0, true);
        Position.Data memory position = tradeStorage.getPosition(posKey);
        assertEq(slKey, position.stopLossKey);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Update the price data
        vm.startPrank(OWNER);
        tokenUpdateData[0] = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 200000, 0, -2, 200000, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        ethPriceData =
            Oracle.PriceUpdateData({assetIds: assetIds, pythData: tokenUpdateData, compactedPrices: compactedPrices});
        positionManager.executePosition{value: 0.0001 ether}(market, slKey, OWNER, ethPriceData);
        vm.stopPrank();

        position = tradeStorage.getPosition(posKey);
        assertEq(position.positionSize, 5000e30);
    }

    function testExecutingATakeProfitOrderTiesItToThePosition() public setUpMarkets {
        // Create a Position
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 2 ether,
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 2.01 ether}(input);
        positionManager.executePosition{value: 0.0001 ether}(
            market, tradeStorage.getOrderAtIndex(0, false), OWNER, ethPriceData
        );
        vm.stopPrank();
        // Create a limit decrease with trigger price < entry price

        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 1 ether,
            sizeDelta: 5000e30,
            limitPrice: 5000e30,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
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

        vm.prank(OWNER);
        router.createPositionRequest{value: 0.01 ether}(input);

        // Check the TP is linked
        bytes32 posKey = keccak256(abi.encode(ethAssetId, OWNER, true));
        bytes32 tpKey = tradeStorage.getOrderAtIndex(0, true);
        Position.Data memory position = tradeStorage.getPosition(posKey);
        assertEq(tpKey, position.takeProfitKey);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Update the price data
        vm.startPrank(OWNER);
        tokenUpdateData[0] = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 500000, 0, -2, 500000, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        ethPriceData =
            Oracle.PriceUpdateData({assetIds: assetIds, pythData: tokenUpdateData, compactedPrices: compactedPrices});
        positionManager.executePosition{value: 0.0001 ether}(market, tpKey, OWNER, ethPriceData);
        vm.stopPrank();

        position = tradeStorage.getPosition(posKey);
        assertEq(position.positionSize, 5000e30);
    }

    function testSlOrdersCantExecuteAtIncorrectSpecifiedPrices() public setUpMarkets {
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether}(input);
        positionManager.executePosition{value: 0.0001 ether}(
            market, tradeStorage.getOrderAtIndex(0, false), OWNER, ethPriceData
        );
        vm.stopPrank();
        // Create a limit decrease with trigger price < entry price

        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.25 ether,
            sizeDelta: 5000e30,
            limitPrice: 2000e30,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
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

        vm.prank(OWNER);
        router.createPositionRequest{value: 0.01 ether}(input);

        // Check the SL is linked
        bytes32 posKey = keccak256(abi.encode(ethAssetId, OWNER, true));
        bytes32 slKey = tradeStorage.getOrderAtIndex(0, true);
        Position.Data memory position = tradeStorage.getPosition(posKey);
        assertEq(slKey, position.stopLossKey);

        // Update the price data
        vm.startPrank(OWNER);
        tokenUpdateData[0] = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 250000, 0, -2, 250000, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        ethPriceData =
            Oracle.PriceUpdateData({assetIds: assetIds, pythData: tokenUpdateData, compactedPrices: compactedPrices});
        vm.expectRevert();
        positionManager.executePosition{value: 0.0001 ether}(market, slKey, OWNER, ethPriceData);
        vm.stopPrank();
    }

    function testTpOrdersCantExecuteAtIncorrectPrices() public setUpMarkets {
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
        vm.startPrank(OWNER);
        router.createPositionRequest{value: 0.51 ether}(input);
        positionManager.executePosition{value: 0.0001 ether}(
            market, tradeStorage.getOrderAtIndex(0, false), OWNER, ethPriceData
        );
        vm.stopPrank();
        // Create a limit decrease with trigger price < entry price

        input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 0.25 ether,
            sizeDelta: 5000e30,
            limitPrice: 5000e30,
            maxSlippage: 0.4e18,
            executionFee: 0.01 ether,
            isLong: true,
            isLimit: true,
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

        vm.prank(OWNER);
        router.createPositionRequest{value: 0.01 ether}(input);

        // Check the TP is linked
        bytes32 posKey = keccak256(abi.encode(ethAssetId, OWNER, true));
        bytes32 tpKey = tradeStorage.getOrderAtIndex(0, true);
        Position.Data memory position = tradeStorage.getPosition(posKey);
        assertEq(tpKey, position.takeProfitKey);

        // Update the price data
        vm.startPrank(OWNER);
        tokenUpdateData[0] = priceFeed.createPriceFeedUpdateData(
            ethPriceId, 490000, 0, -2, 490000, 0, uint64(block.timestamp), uint64(block.timestamp)
        );
        ethPriceData =
            Oracle.PriceUpdateData({assetIds: assetIds, pythData: tokenUpdateData, compactedPrices: compactedPrices});
        vm.expectRevert();
        positionManager.executePosition{value: 0.0001 ether}(market, tpKey, OWNER, ethPriceData);
        vm.stopPrank();
    }
}
