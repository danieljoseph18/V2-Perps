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
import {Execution} from "../../../src/positions/Execution.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MarketUtils} from "../../../src/markets/MarketUtils.sol";

contract TestVaultAccounting is Test {
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

    bytes32 ethAssetId = keccak256(abi.encode("ETH"));
    bytes32 usdcAssetId = keccak256(abi.encode("USDC"));

    bytes[] tokenUpdateData;
    uint256[] allocations;
    bytes32[] assetIds;
    uint256[] compactedPrices;

    Oracle.PriceUpdateData ethPriceData;

    address USER = makeAddr("USER");

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
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            primaryStrategy: Oracle.PrimaryStrategy.PYTH,
            secondaryStrategy: Oracle.SecondaryStrategy.NONE,
            pool: Oracle.UniswapPool({token0: weth, token1: usdc, poolAddress: address(0), poolType: Oracle.PoolType.V3})
        });
        IMarketMaker.MarketRequest memory request = IMarketMaker.MarketRequest({
            owner: OWNER,
            indexTokenTicker: "ETH",
            marketTokenName: "BRRR",
            marketTokenSymbol: "BRRR",
            asset: wethData
        });
        marketMaker.requestNewMarket{value: 0.01 ether}(request);
        // Set primary prices for ref price
        priceFeed.setPrimaryPrices{value: 0.01 ether}(assetIds, tokenUpdateData, compactedPrices);
        // Clear them
        priceFeed.clearPrimaryPrices();
        marketMaker.executeNewMarket(marketMaker.getMarketRequestKey(request.owner, request.indexTokenTicker));
        vm.stopPrank();
        market = Market(payable(marketMaker.tokenToMarket(ethAssetId)));
        tradeStorage = ITradeStorage(market.tradeStorage());
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, OWNER, weth, 20_000 ether, 0.01 ether, true);
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(market, market.getRequestAtIndex(0).key, ethPriceData);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
        positionManager.executeDeposit{value: 0.01 ether}(market, market.getRequestAtIndex(0).key, ethPriceData);
        vm.stopPrank();
        vm.startPrank(OWNER);
        allocations.push(10000 << 240);
        market.setAllocationsWithBits(allocations);
        assertEq(MarketUtils.getAllocation(market, ethAssetId), 10000);
        vm.stopPrank();
        _;
    }

    struct VaultState {
        uint256 longTokenBalance;
        uint256 shortTokenBalance;
        uint256 longTokensReserved;
        uint256 shortTokensReserved;
        uint256 longAccumulatedFees;
        uint256 shortAccumulatedFees;
        uint256 userCollateral;
    }

    function testCreatingLongNewPositionAccounting(uint256 _leverage, uint256 _collateralDelta) public setUpMarkets {
        // Bound Inputs to realistic values
        // _collateralDelta = bound(_collateralDelta, 0.001 ether, 140 ether);
        // _leverage = bound(_leverage, 1, 90);
        // // Create a Position
        // Position.Input memory input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: _collateralDelta,
        //     sizeDelta: mulDiv(_collateralDelta * _leverage, 2500e30, 1e18),
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.prank(OWNER);
        // router.createPositionRequest{value: _collateralDelta + 0.01 ether}(input);
        // // Store the Vault State Before
        // VaultState memory stateBefore = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });
        // // Execute the Position
        // vm.prank(OWNER);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // // Fetch the Position
        // Position.Data memory position = tradeStorage.getPosition(keccak256(abi.encode(ethAssetId, OWNER, true)));
        // // Compare the Vault State after to the expected values
        // VaultState memory stateAfter = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });

        // // Long Token Balances Should Strictly Stay Constant
        // assertEq(stateAfter.longTokenBalance, stateBefore.longTokenBalance, "Long Token Balance");
        // assertEq(stateAfter.shortTokenBalance, stateBefore.shortTokenBalance, "Short Token Balance");
        // // Long Tokens Reserved Should Increase by Size in USD (Price used is collateral price - spread for min)
        // assertEq(
        //     stateAfter.longTokensReserved,
        //     stateBefore.longTokensReserved + mulDiv(position.positionSize, 1e18, 2499500000000000000000000000000000),
        //     "Long Tokens Reserved"
        // );
        // // Short Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.shortTokensReserved, stateBefore.shortTokensReserved, "Short Tokens Reserved");
        // // Long Accumulated Fees Should Increase by the Fees for a Create Position
        // assertEq(
        //     stateAfter.longAccumulatedFees,
        //     stateBefore.longAccumulatedFees + (input.collateralDelta - position.collateralAmount),
        //     "Long Accumulated Fees"
        // );
        // // Short Accumulated Fees Should Stay Constant
        // assertEq(stateAfter.shortAccumulatedFees, stateBefore.shortAccumulatedFees, "Short Accumulated Fees");
        // // User Collateral Should Increase by the Collateral Delta after fees and price impact
        // assertEq(stateAfter.userCollateral, position.collateralAmount, "User Collateral");
    }

    function testCreatingShortNewPositionAccounting(uint256 _leverage, uint256 _collateralDelta) public setUpMarkets {
        // // Bound Inputs to realistic values (2.5 usdc - 350k)
        // _collateralDelta = bound(_collateralDelta, 2.5e6, 350_000e6);
        // _leverage = bound(_leverage, 1, 90);
        // // Create a Position
        // Position.Input memory input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: usdc,
        //     collateralDelta: _collateralDelta,
        //     sizeDelta: mulDiv(_collateralDelta * _leverage, 1e30, 1e6),
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: false,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: false,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // MockUSDC(usdc).approve(address(router), type(uint256).max);
        // router.createPositionRequest{value: _collateralDelta + 0.01 ether}(input);
        // vm.stopPrank();
        // // Store the Vault State Before
        // VaultState memory stateBefore = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, false)
        // });
        // // Execute the Position
        // vm.prank(OWNER);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // // Fetch the Position
        // Position.Data memory position = tradeStorage.getPosition(keccak256(abi.encode(ethAssetId, OWNER, false)));
        // // Compare the Vault State after to the expected values
        // VaultState memory stateAfter = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, false)
        // });

        // // Short Token Balances Should Strictly Stay Constant
        // assertEq(stateAfter.shortTokenBalance, stateBefore.shortTokenBalance, "Short Token Balance");
        // assertEq(stateAfter.longTokenBalance, stateBefore.longTokenBalance, "Long Token Balance");
        // // Short Tokens Reserved Should Increase by Size in USD (Price used is collateral price - spread for min)
        // assertEq(
        //     stateAfter.shortTokensReserved,
        //     stateBefore.shortTokensReserved + mulDiv(position.positionSize, 1e6, 1e30),
        //     "Short Tokens Reserved"
        // );
        // // Long Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.longTokensReserved, stateBefore.longTokensReserved, "Long Tokens Reserved");
        // // Short Accumulated Fees Should Increase by the Fees for a Create Position
        // assertEq(
        //     stateAfter.shortAccumulatedFees,
        //     stateBefore.shortAccumulatedFees + (input.collateralDelta - position.collateralAmount),
        //     "Short Accumulated Fees"
        // );
        // // Long Accumulated Fees Should Stay Constant
        // assertEq(stateAfter.longAccumulatedFees, stateBefore.longAccumulatedFees, "Long Accumulated Fees");
        // // User Collateral Should Increase by the Collateral Delta after fees and price impact
        // assertEq(stateAfter.userCollateral, position.collateralAmount, "User Collateral");
    }

    function testIncreasePositionAccountingLong(uint256 _leverage, uint256 _collateralDelta) public setUpMarkets {
        // // Bound Inputs to realistic values
        // _collateralDelta = bound(_collateralDelta, 0.001 ether, 140 ether);
        // _leverage = bound(_leverage, 1, 90);
        // // Open a regular position and execute it
        // Position.Input memory input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: 1 ether,
        //     sizeDelta: 25_000e30,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // router.createPositionRequest{value: 1.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();
        // // Store the vault state before
        // VaultState memory stateBefore = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });
        // // Increase the position and store the vault state after
        // input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: _collateralDelta,
        //     sizeDelta: mulDiv(_collateralDelta * _leverage, 2499500000000000000000000000000000, 1e18),
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // router.createPositionRequest{value: _collateralDelta + 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();
        // // Get the Expected Collateral Delta (Collateral Delta - Fees)
        // uint256 expectedCollateralDelta = input.collateralDelta
        //     - Fee.calculateForPosition(
        //         tradeStorage,
        //         mulDiv(_collateralDelta * _leverage, 2499500000000000000000000000000000, 1e18),
        //         _collateralDelta,
        //         2499500000000000000000000000000000,
        //         1e18
        //     );

        // // Get Vault State After
        // VaultState memory stateAfter = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });
        // // Compare Values to Expected Values
        // // Long Token Balances Should Strictly Stay Constant
        // assertEq(stateAfter.longTokenBalance, stateBefore.longTokenBalance, "Long Token Balance");
        // assertEq(stateAfter.shortTokenBalance, stateBefore.shortTokenBalance, "Short Token Balance");
        // // Long Tokens Reserved Should Increase by Size in USD (Price used is collateral price - spread for min)
        // assertEq(
        //     stateAfter.longTokensReserved,
        //     stateBefore.longTokensReserved + mulDiv(input.sizeDelta, 1e18, 2499500000000000000000000000000000),
        //     "Long Tokens Reserved"
        // );
        // // Short Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.shortTokensReserved, stateBefore.shortTokensReserved, "Short Tokens Reserved");
        // // Long Accumulated Fees Should Increase by the Fees for a Create Position
        // assertEq(
        //     stateAfter.longAccumulatedFees,
        //     stateBefore.longAccumulatedFees + (input.collateralDelta - expectedCollateralDelta),
        //     "Long Accumulated Fees"
        // );
        // // Short Accumulated Fees Should Stay Constant
        // assertEq(stateAfter.shortAccumulatedFees, stateBefore.shortAccumulatedFees, "Short Accumulated Fees");
        // // User Collateral Should Increase by the Collateral Delta after fees
        // assertEq(stateAfter.userCollateral, stateBefore.userCollateral + expectedCollateralDelta, "User Collateral");
    }

    function testIncreasePositionAccountingShort(uint256 _leverage, uint256 _collateralDelta) public setUpMarkets {
        // // Bound Inputs to realistic values
        // _collateralDelta = bound(_collateralDelta, 2.5e6, 350_000e6);
        // _leverage = bound(_leverage, 1, 90);
        // // Open a regular position and execute it
        // Position.Input memory input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: usdc,
        //     collateralDelta: 1000e6,
        //     sizeDelta: 10_000e30,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: false,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: false,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // MockUSDC(usdc).approve(address(router), type(uint256).max);
        // router.createPositionRequest{value: 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();
        // // Store the vault state before
        // VaultState memory stateBefore = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, false)
        // });
        // // Increase the position and store the vault state after
        // input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: usdc,
        //     collateralDelta: _collateralDelta,
        //     sizeDelta: mulDiv(_collateralDelta * _leverage, 1e30, 1e6),
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: false,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: false,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // MockUSDC(usdc).approve(address(router), type(uint256).max);
        // router.createPositionRequest{value: 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();
        // // Get the Expected Collateral Delta (Collateral Delta - Fees)
        // uint256 expectedCollateralDelta = input.collateralDelta
        //     - Fee.calculateForPosition(
        //         tradeStorage, mulDiv(_collateralDelta * _leverage, 1e30, 1e6), _collateralDelta, 1e30, 1e6
        //     );

        // // Get Vault State After
        // VaultState memory stateAfter = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, false)
        // });

        // // Compare Values to Expected Values
        // // Short Token Balances Should Strictly Stay Constant
        // assertEq(stateAfter.shortTokenBalance, stateBefore.shortTokenBalance, "Short Token Balance");
        // assertEq(stateAfter.longTokenBalance, stateBefore.longTokenBalance, "Long Token Balance");
        // // Short Tokens Reserved Should Increase by Size in USD (Price used is collateral price - spread for min)
        // assertEq(
        //     stateAfter.shortTokensReserved,
        //     stateBefore.shortTokensReserved + mulDiv(input.sizeDelta, 1e6, 1e30),
        //     "Short Tokens Reserved"
        // );
        // // Long Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.longTokensReserved, stateBefore.longTokensReserved, "Long Tokens Reserved");
        // // Short Accumulated Fees Should Increase by the Fees for a Create Position
        // assertEq(
        //     stateAfter.shortAccumulatedFees,
        //     stateBefore.shortAccumulatedFees + (input.collateralDelta - expectedCollateralDelta),
        //     "Short Accumulated Fees"
        // );
        // // Long Accumulated Fees Should Stay Constant
        // assertEq(stateAfter.longAccumulatedFees, stateBefore.longAccumulatedFees, "Long Accumulated Fees");
        // // User Collateral Should Increase by the Collateral Delta after fees
        // assertEq(stateAfter.userCollateral, stateBefore.userCollateral + expectedCollateralDelta, "User Collateral");
    }

    function testDecreasePositionAccountingLong(uint256 _percentageToDecrease) public setUpMarkets {
        // _percentageToDecrease = bound(_percentageToDecrease, 10000, 0.95e18); // Keep collat above min threshold
        // // Open a regular position and execute it
        // Position.Input memory input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: 10 ether,
        //     sizeDelta: 250_000e30,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // router.createPositionRequest{value: 10.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();
        // // Store the vault state before
        // VaultState memory stateBefore = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });
        // // Get the position
        // Position.Data memory position = tradeStorage.getPosition(keccak256(abi.encode(ethAssetId, OWNER, true)));
        // // Decrease the position and store the vault state after
        // uint256 sizeDelta = mulDiv(position.positionSize, _percentageToDecrease, 1e18);
        // input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: mulDiv(position.collateralAmount, _percentageToDecrease, 1e18),
        //     sizeDelta: sizeDelta,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: false,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // router.createPositionRequest{value: 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();

        // // Get Vault State After
        // VaultState memory stateAfter = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });

        // // Use max price
        // uint256 sizeDeltaTokens = mulDiv(input.sizeDelta, 1e18, 2500500000000000000000000000000000);
        // uint256 fee = Fee.calculateForPosition(
        //     tradeStorage, sizeDelta, input.collateralDelta, 2500500000000000000000000000000000, 1e18
        // );

        // // Compare Values to Expected Values
        // // Long Token Balances Should Strictly Stay Constant
        // assertEq(stateAfter.longTokenBalance, stateBefore.longTokenBalance, "Long Token Balance");
        // assertEq(stateAfter.shortTokenBalance, stateBefore.shortTokenBalance, "Short Token Balance");
        // // Long Tokens Reserved Should Decrease by Size in USD (Price used is collateral price - spread for max)
        // assertEq(
        //     stateAfter.longTokensReserved, stateBefore.longTokensReserved - sizeDeltaTokens, "Long Tokens Reserved"
        // );
        // // Short Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.shortTokensReserved, stateBefore.shortTokensReserved, "Short Tokens Reserved");
        // // Long Accumulated Fees Should Increase by the Fees for a Create Position
        // assertEq(stateAfter.longAccumulatedFees, stateBefore.longAccumulatedFees + fee, "Long Accumulated Fees");
        // // Short Accumulated Fees Should Stay Constant
        // assertEq(stateAfter.shortAccumulatedFees, stateBefore.shortAccumulatedFees, "Short Accumulated Fees");
        // // User Collateral Should Increase by the Collateral Delta after fees
        // assertEq(stateAfter.userCollateral, stateBefore.userCollateral - input.collateralDelta, "User Collateral");
    }

    function testDecreasePositionAccountingShort(uint256 _percentageToDecrease) public setUpMarkets {
        // _percentageToDecrease = bound(_percentageToDecrease, 100000000000000, 0.95e18); // Keep collat above min threshold
        // // Open a regular position and execute it
        // Position.Input memory input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: usdc,
        //     collateralDelta: 1000e6,
        //     sizeDelta: 10_000e30,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: false,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: false,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // MockUSDC(usdc).approve(address(router), type(uint256).max);
        // router.createPositionRequest{value: 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();
        // // Store the vault state before
        // VaultState memory stateBefore = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, false)
        // });
        // // Get the position
        // Position.Data memory position = tradeStorage.getPosition(keccak256(abi.encode(ethAssetId, OWNER, false)));
        // // Decrease the position and store the vault state after
        // uint256 sizeDelta = mulDiv(position.positionSize, _percentageToDecrease, 1e18);
        // input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: usdc,
        //     collateralDelta: mulDiv(position.collateralAmount, _percentageToDecrease, 1e18),
        //     sizeDelta: sizeDelta,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: false,
        //     isLimit: false,
        //     isIncrease: false,
        //     reverseWrap: false,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // MockUSDC(usdc).approve(address(router), type(uint256).max);
        // router.createPositionRequest{value: 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();

        // // Get Vault State After
        // VaultState memory stateAfter = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, false)
        // });

        // // Use max price
        // uint256 sizeDeltaTokens = mulDiv(input.sizeDelta, 1e6, 1e30);
        // uint256 fee = Fee.calculateForPosition(tradeStorage, sizeDelta, input.collateralDelta, 1e30, 1e6);

        // // Compare Values to Expected Values
        // // Short Token Balances Should Strictly Stay Constant
        // assertEq(stateAfter.shortTokenBalance, stateBefore.shortTokenBalance, "Short Token Balance");
        // assertEq(stateAfter.longTokenBalance, stateBefore.longTokenBalance, "Long Token Balance");
        // // Short Tokens Reserved Should Decrease by Size in USD (Price used is collateral price - spread for max)
        // assertEq(
        //     stateAfter.shortTokensReserved, stateBefore.shortTokensReserved - sizeDeltaTokens, "Short Tokens Reserved"
        // );
        // // Long Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.longTokensReserved, stateBefore.longTokensReserved, "Long Tokens Reserved");
        // // Short Accumulated Fees Should Increase by the Fees for a Create Position
        // assertEq(stateAfter.shortAccumulatedFees, stateBefore.shortAccumulatedFees + fee, "Short Accumulated Fees");
        // // Long Accumulated Fees Should Stay Constant
        // assertEq(stateAfter.longAccumulatedFees, stateBefore.longAccumulatedFees, "Long Accumulated Fees");
        // // User Collateral Should Increase by the Collateral Delta after fees
        // assertEq(stateAfter.userCollateral, stateBefore.userCollateral - input.collateralDelta, "User Collateral");
    }

    function testDecreasePositionAccountingForFullDecreaseLong() public setUpMarkets {
        // // Open a regular position and execute it
        // Position.Input memory input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: 10 ether,
        //     sizeDelta: 250_000e30,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // router.createPositionRequest{value: 10.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();
        // // Store the vault state before
        // VaultState memory stateBefore = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });
        // // Get the position
        // Position.Data memory position = tradeStorage.getPosition(keccak256(abi.encode(ethAssetId, OWNER, true)));
        // // Decrease the position and store the vault state after
        // input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: position.collateralAmount,
        //     sizeDelta: position.positionSize,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: false,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // router.createPositionRequest{value: 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();

        // // Get Vault State After
        // VaultState memory stateAfter = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });

        // // Use max price
        // uint256 sizeDeltaTokens = mulDiv(input.sizeDelta, 1e18, 2500500000000000000000000000000000);
        // uint256 fee = Fee.calculateForPosition(
        //     tradeStorage, position.positionSize, input.collateralDelta, 2500500000000000000000000000000000, 1e18
        // );

        // // Compare Values to Expected Values
        // // Long Token Balances Should Strictly Stay Constant
        // assertEq(stateAfter.longTokenBalance, stateBefore.longTokenBalance, "Long Token Balance");
        // assertEq(stateAfter.shortTokenBalance, stateBefore.shortTokenBalance, "Short Token Balance");
        // // Long Tokens Reserved Should Decrease by Size in USD (Price used is collateral price - spread for max)
        // assertEq(
        //     stateAfter.longTokensReserved, stateBefore.longTokensReserved - sizeDeltaTokens, "Long Tokens Reserved"
        // );
        // // Short Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.shortTokensReserved, stateBefore.shortTokensReserved, "Short Tokens Reserved");
        // // Long Accumulated Fees Should Increase by the Fees for a Create Position
        // assertEq(stateAfter.longAccumulatedFees, stateBefore.longAccumulatedFees + fee, "Long Accumulated Fees");
        // // Short Accumulated Fees Should Stay Constant
        // assertEq(stateAfter.shortAccumulatedFees, stateBefore.shortAccumulatedFees, "Short Accumulated Fees");
        // // User Collateral Should Increase by the Collateral Delta after fees
        // assertEq(stateAfter.userCollateral, stateBefore.userCollateral - input.collateralDelta, "User Collateral");
    }

    function testDecreasePositionAccountingForFullDecreaseShort() public setUpMarkets {
        // // Open a regular position and execute it
        // Position.Input memory input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: usdc,
        //     collateralDelta: 1000e6,
        //     sizeDelta: 10_000e30,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: false,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: false,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // MockUSDC(usdc).approve(address(router), type(uint256).max);
        // router.createPositionRequest{value: 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();
        // // Store the vault state before
        // VaultState memory stateBefore = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, false)
        // });
        // // Get the position
        // Position.Data memory position = tradeStorage.getPosition(keccak256(abi.encode(ethAssetId, OWNER, false)));
        // // Decrease the position and store the vault state after
        // input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: usdc,
        //     collateralDelta: position.collateralAmount,
        //     sizeDelta: position.positionSize,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: false,
        //     isLimit: false,
        //     isIncrease: false,
        //     reverseWrap: false,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // MockUSDC(usdc).approve(address(router), type(uint256).max);
        // router.createPositionRequest{value: 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();

        // // Get Vault State After
        // VaultState memory stateAfter = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, false)
        // });

        // // Use max price
        // uint256 sizeDeltaTokens = mulDiv(input.sizeDelta, 1e6, 1e30);
        // uint256 fee = Fee.calculateForPosition(tradeStorage, position.positionSize, input.collateralDelta, 1e30, 1e6);

        // // Compare Values to Expected Values
        // // Short Token Balances Should Strictly Stay Constant
        // assertEq(stateAfter.shortTokenBalance, stateBefore.shortTokenBalance, "Short Token Balance");
        // assertEq(stateAfter.longTokenBalance, stateBefore.longTokenBalance, "Long Token Balance");
        // // Short Tokens Reserved Should Decrease by Size in USD (Price used is collateral price - spread for max)
        // assertEq(
        //     stateAfter.shortTokensReserved, stateBefore.shortTokensReserved - sizeDeltaTokens, "Short Tokens Reserved"
        // );
        // // Long Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.longTokensReserved, stateBefore.longTokensReserved, "Long Tokens Reserved");
        // // Short Accumulated Fees Should Increase by the Fees for a Create Position
        // assertEq(stateAfter.shortAccumulatedFees, stateBefore.shortAccumulatedFees + fee, "Short Accumulated Fees");
        // // Long Accumulated Fees Should Stay Constant
        // assertEq(stateAfter.longAccumulatedFees, stateBefore.longAccumulatedFees, "Long Accumulated Fees");
        // // User Collateral Should Increase by the Collateral Delta after fees
        // assertEq(stateAfter.userCollateral, stateBefore.userCollateral - input.collateralDelta, "User Collateral");
    }

    function testAccountingForCollateralIncrease(uint256 _collateralDelta) public setUpMarkets {
        // _collateralDelta = bound(_collateralDelta, 0.001 ether, 140 ether);
        // // Open an existing position
        // Position.Input memory input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: 100 ether,
        //     sizeDelta: 2_500_000e30,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // router.createPositionRequest{value: 100.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();
        // // Store the vault state before
        // VaultState memory stateBefore = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });
        // // Increase the collateral and store the vault state after
        // input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: _collateralDelta,
        //     sizeDelta: 0,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // router.createPositionRequest{value: _collateralDelta + 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();

        // // Get Vault State After
        // VaultState memory stateAfter = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });

        // uint256 fee =
        //     Fee.calculateForPosition(tradeStorage, 0, _collateralDelta, 2500500000000000000000000000000000, 1e18);

        // // Compare Values to Expected Values
        // // Long Token Balances Should Strictly Stay Constant
        // assertEq(stateAfter.longTokenBalance, stateBefore.longTokenBalance, "Long Token Balance");
        // assertEq(stateAfter.shortTokenBalance, stateBefore.shortTokenBalance, "Short Token Balance");
        // // Long Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.longTokensReserved, stateBefore.longTokensReserved, "Long Tokens Reserved");
        // // Short Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.shortTokensReserved, stateBefore.shortTokensReserved, "Short Tokens Reserved");
        // // Long Accumulated Fees Should Increase by the Fees for a collateral increase
        // assertEq(stateAfter.longAccumulatedFees, stateBefore.longAccumulatedFees + fee, "Long Accumulated Fees");
        // // Short Accumulated Fees Should Stay Constant
        // assertEq(stateAfter.shortAccumulatedFees, stateBefore.shortAccumulatedFees, "Short Accumulated Fees");
        // // User Collateral Should Increase by the Collateral Delta after fees
        // assertEq(stateAfter.userCollateral, stateBefore.userCollateral + (_collateralDelta - fee), "User Collateral");
    }

    function testAccountingForCollateralDecrease(uint256 _collateralDelta) public setUpMarkets {
        // // Max leverage 100x -> Can only reduce collateral to 1 ether
        // _collateralDelta = bound(_collateralDelta, 0.001 ether, 98.5 ether);
        // // Open an existing position
        // Position.Input memory input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: 100 ether,
        //     sizeDelta: 250_000e30,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: true,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // router.createPositionRequest{value: 100.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();
        // // Store the vault state before
        // VaultState memory stateBefore = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });
        // // Decrease the collateral and store the vault state after
        // input = Position.Input({
        //     assetId: ethAssetId,
        //     collateralToken: weth,
        //     collateralDelta: _collateralDelta,
        //     sizeDelta: 0,
        //     limitPrice: 0,
        //     maxSlippage: 0.99e18,
        //     executionFee: 0.01 ether,
        //     isLong: true,
        //     isLimit: false,
        //     isIncrease: false,
        //     reverseWrap: true,
        //     conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        // });
        // vm.startPrank(OWNER);
        // router.createPositionRequest{value: 0.01 ether}(input);
        // positionManager.executePosition{value: 0.01 ether}(
        //     market, tradeStorage.getOrderAtIndex(0, false), msg.sender, ethPriceData
        // );
        // vm.stopPrank();

        // // Get Vault State After
        // VaultState memory stateAfter = VaultState({
        //     longTokenBalance: market.longTokenBalance(),
        //     shortTokenBalance: market.shortTokenBalance(),
        //     longTokensReserved: market.longTokensReserved(),
        //     shortTokensReserved: market.shortTokensReserved(),
        //     longAccumulatedFees: market.longAccumulatedFees(),
        //     shortAccumulatedFees: market.shortAccumulatedFees(),
        //     userCollateral: market.collateralAmounts(OWNER, true)
        // });

        // uint256 fee =
        //     Fee.calculateForPosition(tradeStorage, 0, _collateralDelta, 2499500000000000000000000000000000, 1e18);

        // // Compare Values to Expected Values
        // // Long Token Balances Should Strictly Stay Constant
        // assertEq(stateAfter.longTokenBalance, stateBefore.longTokenBalance, "Long Token Balance");
        // assertEq(stateAfter.shortTokenBalance, stateBefore.shortTokenBalance, "Short Token Balance");
        // // Long Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.longTokensReserved, stateBefore.longTokensReserved, "Long Tokens Reserved");
        // // Short Tokens Reserved Should Stay Constant
        // assertEq(stateAfter.shortTokensReserved, stateBefore.shortTokensReserved, "Short Tokens Reserved");
        // // Long Accumulated Fees Should Increase by the Fees for a collateral decrease
        // assertEq(stateAfter.longAccumulatedFees, stateBefore.longAccumulatedFees + fee, "Long Accumulated Fees");
        // // Short Accumulated Fees Should Stay Constant
        // assertEq(stateAfter.shortAccumulatedFees, stateBefore.shortAccumulatedFees, "Short Accumulated Fees");
        // // User Collateral Should Increase by the Collateral Delta after fees
        // assertEq(stateAfter.userCollateral, stateBefore.userCollateral - _collateralDelta, "User Collateral");
    }
}
