// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console} from "forge-std/Test.sol";
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
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Fee} from "../../../src/libraries/Fee.sol";

contract TestDeposits is Test {
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

        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, OWNER, weth, 20_000 ether, 0.01 ether, true);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
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

    function testCreatingADepositRequest() public setUpMarkets {
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 0.51 ether}(market, OWNER, weth, 0.5 ether, 0.01 ether, true);
    }

    function testExecutingADepositRequest() public setUpMarkets {
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 0.51 ether}(market, OWNER, weth, 0.5 ether, 0.01 ether, true);
        // Call the execute deposit function with sufficient gas
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
    }

    function testFuzzingDepositAmountInEther(uint256 _amountIn) public setUpMarkets {
        // Add Buffer of 0.1 ether to cover execution fees and gas
        _amountIn = bound(_amountIn, 1, address(OWNER).balance - 0.1 ether);
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: _amountIn + 0.01 ether}(market, OWNER, weth, _amountIn, 0.01 ether, true);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        uint256 marketTokenBalanceBefore = market.balanceOf(OWNER);
        vm.prank(OWNER);
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
        uint256 marketTokenBalanceAfter = market.balanceOf(OWNER);
        assertGt(marketTokenBalanceAfter, marketTokenBalanceBefore);
    }

    function testFuzzingInvalidEtherAmountInsFails(uint256 _amountIn) public setUpMarkets {
        vm.assume(_amountIn > address(OWNER).balance);
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        vm.expectRevert();
        router.createDeposit{value: _amountIn + 0.01 ether}(market, OWNER, weth, _amountIn, 0.01 ether, true);
    }

    function testFuzzingValuesWhereValueIsLessThanAmount(uint256 _amountIn, uint256 _value) public setUpMarkets {
        vm.assume(_value < _amountIn);
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        vm.expectRevert();
        router.createDeposit{value: _value + 0.01 ether}(market, OWNER, weth, _amountIn, 0.01 ether, true);
    }

    function testFuzzingDepositAmountInWrappedEther(uint256 _amountIn) public setUpMarkets {
        _amountIn = bound(_amountIn, 1, WETH(weth).balanceOf(OWNER));
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        WETH(weth).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether}(market, OWNER, weth, _amountIn, 0.01 ether, false);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
    }

    function testFuzzingDepositAmountInUsdc(uint256 _amountIn) public setUpMarkets {
        _amountIn = bound(_amountIn, 1, MockUSDC(usdc).balanceOf(OWNER));
        // Call the deposit function with sufficient gas
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether}(market, OWNER, usdc, _amountIn, 0.01 ether, false);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
        vm.stopPrank();
    }

    // Expected Amount = 2.4970005e+25 (base fee + price spread)
    // Received Amount = 2.4970005e+25
    function testDepositWithHugeAmount() public setUpMarkets {
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 10_000.01 ether}(market, OWNER, weth, 10_000 ether, 0.01 ether, true);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        uint256 balanceBefore = market.balanceOf(OWNER);
        vm.prank(OWNER);
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
        uint256 balanceAfter = market.balanceOf(OWNER);
        assertGt(balanceAfter, balanceBefore);
    }

    // @audit - Fee values correct?
    function testDynamicFeesOnImbalancedDeposits() public setUpMarkets {
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 1.01 ether}(market, OWNER, weth, 1 ether, 0.01 ether, true);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
        uint256 balanceBefore = market.balanceOf(OWNER);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Calculate the expected amount out
        (Oracle.Price memory longPrices, Oracle.Price memory shortPrices) = Oracle.getLastMarketTokenPrices(priceFeed);
        console.log("LTB: ", market.longTokenBalance());
        console.log("STB: ", market.shortTokenBalance());
        console.log("MTS: ", market.totalSupply());
        Fee.Params memory feeParams = Fee.constructFeeParams(market, 50000e6, false, longPrices, shortPrices, true);
        uint256 expectedFee =
            Fee.calculateForMarketAction(feeParams, market.longTokenBalance(), 1e18, market.shortTokenBalance(), 1e6);
        console.log("Expected Fee: ", expectedFee);
        uint256 amountMinusFee = 50_000e6 - expectedFee;
        console.log("Amount Minus Fee: ", amountMinusFee);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
        depositKey = market.getDepositRequestAtIndex(0).key;
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
        vm.stopPrank();
        uint256 balanceAfter = market.balanceOf(OWNER);
        console.log("Actual Amount Out: ", balanceAfter - balanceBefore);
    }

    // Bonus Fee = 0.0003995201959207653 (0.04%)
    function testDynamicFeesOnGiganticImbalancedDeposits() public setUpMarkets {
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 1.01 ether}(market, OWNER, weth, 1 ether, 0.01 ether, true);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        vm.prank(OWNER);
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
        uint256 balanceBefore = market.balanceOf(OWNER);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
        depositKey = market.getDepositRequestAtIndex(0).key;
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
        vm.stopPrank();
        uint256 amountReceived = market.balanceOf(OWNER) - balanceBefore;
        console.log("Actual Amount Out: ", amountReceived);
    }

    function testCreateDepositWithWethNoWrap() public setUpMarkets {
        // Call the deposit function with sufficient gas
        vm.startPrank(OWNER);
        WETH(weth).approve(address(router), type(uint256).max);
        router.createDeposit{value: 1.01 ether}(market, OWNER, weth, 1 ether, 0.01 ether, false);
        bytes32 depositKey = market.getDepositRequestAtIndex(0).key;
        processor.executeDeposit{value: 0.0001 ether}(market, depositKey, ethPriceData);
        vm.stopPrank();
    }
}
