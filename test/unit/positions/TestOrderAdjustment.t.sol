// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
import {Market, IMarket, IVault} from "../../../src/markets/Market.sol";
import {MarketMaker, IMarketMaker} from "../../../src/markets/MarketMaker.sol";
import {IPriceFeed} from "../../../src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage} from "../../../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../../../src/router/PositionManager.sol";
import {Router} from "../../../src/router/Router.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Fee} from "../../../src/libraries/Fee.sol";
import {Position} from "../../../src/positions/Position.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {Pricing} from "../../../src/libraries/Pricing.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Fee} from "../../../src/libraries/Fee.sol";

contract TestOrderAdjustment is Test {
    using SignedMath for int256;
    using stdStorage for StdStorage;

    RoleStorage roleStorage;
    GlobalMarketConfig globalMarketConfig;
    MarketMaker marketMaker;
    IPriceFeed priceFeed; // Deployed in Helper Config
    TradeStorage tradeStorage;
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
        globalMarketConfig = contracts.globalMarketConfig;
        marketMaker = contracts.marketMaker;
        priceFeed = contracts.priceFeed;
        tradeStorage = contracts.tradeStorage;
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

    /**
     * struct Input {
     *     bytes32 assetId; // Hash of the asset ticker, e.g keccak256(abi.encode("ETH"))
     *     address collateralToken;
     *     uint256 collateralDelta;
     *     uint256 sizeDelta; // USD
     *     uint256 limitPrice;
     *     uint256 maxSlippage;
     *     uint256 executionFee;
     *     bool isLong;
     *     bool isLimit;
     *     bool isIncrease;
     *     bool reverseWrap;
     *     Conditionals conditionals;
     * }
     *
     * function adjustLimitOrder(
     * bytes32 _orderKey,
     * Position.Conditionals calldata _conditionals,
     * uint256 _sizeDelta,
     * uint256 _collateralDelta,
     * uint256 _collateralIn,
     * uint256 _limitPrice,
     * uint256 _maxSlippage,
     * bool _isLongToken,
     * bool _reverseWrap
     * )
     */
    function testWeCanAdjustALimitOrderLong(uint256 _sizeDelta, uint256 _maxSlippage, uint256 _limitPrice)
        public
        setUpMarkets
    {
        // Bound inputs
        _sizeDelta = bound(_sizeDelta, 1, 1e48);
        _maxSlippage = bound(_maxSlippage, 0.1e18, 0.9999e18);
        _limitPrice = bound(_limitPrice, 1, 1e48);
        // Create a limit order
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 1 ether,
            sizeDelta: 25_000e30,
            limitPrice: 250_000e18,
            maxSlippage: 0.1e18,
            executionFee: 0.01e18,
            isLong: true,
            isLimit: true,
            isIncrease: true,
            reverseWrap: true,
            conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        });
        // Create request
        vm.prank(OWNER);
        router.createPositionRequest{value: 1.01 ether}(input);
        // Attempt to adjust it with valid parameters
        Position.Adjustment memory params;
        params.orderKey = tradeStorage.getOrderAtIndex(0, true);
        params.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        params.sizeDelta = _sizeDelta;
        params.collateralDelta = 1 ether;
        params.collateralIn = 0;
        params.limitPrice = _limitPrice;
        params.maxSlippage = _maxSlippage;
        params.isLongToken = false;
        params.reverseWrap = false;
        vm.prank(OWNER);
        positionManager.adjustLimitOrder(params);

        // Check the order has been adjusted in storage
        Position.Request memory request = tradeStorage.getOrder(params.orderKey);
        assertEq(request.input.sizeDelta, _sizeDelta, "Size delta not adjusted");
        assertEq(request.input.maxSlippage, _maxSlippage, "Max slippage not adjusted");
    }

    function testWeCanAdjustALimitOrderShort(uint256 _sizeDelta, uint256 _maxSlippage, uint256 _limitPrice)
        public
        setUpMarkets
    {
        // Bound inputs
        _sizeDelta = bound(_sizeDelta, 1, 1e48);
        _maxSlippage = bound(_maxSlippage, 0.1e18, 0.9999e18);
        _limitPrice = bound(_limitPrice, 1, 1e48);
        // Create a limit order
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: usdc,
            collateralDelta: 2500e6,
            sizeDelta: 25_000e30,
            limitPrice: 2500e30,
            maxSlippage: 0.1e18,
            executionFee: 0.01e18,
            isLong: false,
            isLimit: true,
            isIncrease: true,
            reverseWrap: false,
            conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        });
        // Create request
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input);
        vm.stopPrank();
        // Attempt to adjust it with valid parameters
        Position.Adjustment memory params;
        params.orderKey = tradeStorage.getOrderAtIndex(0, true);
        params.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        params.sizeDelta = _sizeDelta;
        params.collateralDelta = 2500e6;
        params.collateralIn = 0;
        params.limitPrice = _limitPrice;
        params.maxSlippage = _maxSlippage;
        params.isLongToken = false;
        params.reverseWrap = false;

        vm.prank(OWNER);
        positionManager.adjustLimitOrder(params);

        // Check the order has been adjusted in storage
        Position.Request memory request = tradeStorage.getOrder(params.orderKey);
        assertEq(request.input.sizeDelta, _sizeDelta, "Size delta not adjusted");
        assertEq(request.input.maxSlippage, _maxSlippage, "Max slippage not adjusted");
    }

    function testIncreasingTheCollateralDeltaFailsWithoutTransferIn(uint256 _collateralDelta) public setUpMarkets {
        // Bound input
        _collateralDelta = bound(_collateralDelta, 1 ether + 1 wei, 100 ether); // Above prev delta
        // Create a limit order
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 1 ether,
            sizeDelta: 25_000e30,
            limitPrice: 250_000e18,
            maxSlippage: 0.1e18,
            executionFee: 0.01e18,
            isLong: true,
            isLimit: true,
            isIncrease: true,
            reverseWrap: true,
            conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        });
        // Create request
        vm.prank(OWNER);
        router.createPositionRequest{value: 1.01 ether}(input);
        // Attempt to adjust it with valid parameters
        Position.Adjustment memory params;
        params.orderKey = tradeStorage.getOrderAtIndex(0, true);
        params.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        params.sizeDelta = 0;
        params.collateralDelta = _collateralDelta;
        params.collateralIn = 0;
        params.limitPrice = 0;
        params.maxSlippage = 0;
        params.isLongToken = true;
        params.reverseWrap = false;
        vm.prank(OWNER);
        vm.expectRevert();
        positionManager.adjustLimitOrder(params);
    }

    function testIncreasingTheCollateralDeltaPassesWithTransferIn(uint256 _collateralDelta) public setUpMarkets {
        // Bound input
        _collateralDelta = bound(_collateralDelta, 1 ether + 1 wei, 100 ether); // Above prev delta
        // Create a limit order
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 1 ether,
            sizeDelta: 25_000e30,
            limitPrice: 250_000e18,
            maxSlippage: 0.1e18,
            executionFee: 0.01e18,
            isLong: true,
            isLimit: true,
            isIncrease: true,
            reverseWrap: true,
            conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        });
        // Create request
        vm.prank(OWNER);
        router.createPositionRequest{value: 1.01 ether}(input);
        // Attempt to adjust it with valid parameters
        Position.Adjustment memory params;
        params.orderKey = tradeStorage.getOrderAtIndex(0, true);
        params.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        params.sizeDelta = 0;
        params.collateralDelta = _collateralDelta;
        params.collateralIn = _collateralDelta;
        params.limitPrice = 0;
        params.maxSlippage = 0;
        params.isLongToken = true;
        params.reverseWrap = true;
        vm.prank(OWNER);
        positionManager.adjustLimitOrder{value: _collateralDelta}(params);
    }

    function testDecreasingTheFullCollateralFromTheRequest() public setUpMarkets {
        // Create a limit order
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 1 ether,
            sizeDelta: 25_000e30,
            limitPrice: 250_000e18,
            maxSlippage: 0.1e18,
            executionFee: 0.01e18,
            isLong: true,
            isLimit: true,
            isIncrease: true,
            reverseWrap: true,
            conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        });
        // Create request
        vm.prank(OWNER);
        router.createPositionRequest{value: 1.01 ether}(input);
        // Attempt to adjust it with valid parameters
        Position.Adjustment memory params;
        params.orderKey = tradeStorage.getOrderAtIndex(0, true);
        params.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        params.sizeDelta = 0;
        params.collateralDelta = 1;
        params.collateralIn = 0;
        params.limitPrice = 0;
        params.maxSlippage = 0;
        params.isLongToken = true;
        params.reverseWrap = true;
        vm.prank(OWNER);
        positionManager.adjustLimitOrder(params);
    }

    function testDecreasingTheCollateralDeltaTransfersTokensToUserLong(uint256 _collateralDelta) public setUpMarkets {
        // Bound input
        _collateralDelta = bound(_collateralDelta, 1000, 1 ether - 1 wei); // Below prev delta
        // Create a limit order
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 1 ether,
            sizeDelta: 25_000e30,
            limitPrice: 250_000e18,
            maxSlippage: 0.1e18,
            executionFee: 0.01e18,
            isLong: true,
            isLimit: true,
            isIncrease: true,
            reverseWrap: true,
            conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        });
        // Create request
        vm.prank(OWNER);
        router.createPositionRequest{value: 1.01 ether}(input);
        // Attempt to adjust it with valid parameters
        Position.Adjustment memory params;
        params.orderKey = tradeStorage.getOrderAtIndex(0, true);
        params.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        params.sizeDelta = 0;
        params.collateralDelta = _collateralDelta;
        params.collateralIn = 0;
        params.limitPrice = 0;
        params.maxSlippage = 0;
        params.isLongToken = true;
        params.reverseWrap = true;
        uint256 balBefore = OWNER.balance;
        vm.prank(OWNER);
        positionManager.adjustLimitOrder(params);
        uint256 balAfter = OWNER.balance;
        uint256 changeInCollateral = 1 ether - _collateralDelta; // 999999999999999000
        uint256 adjustmentFee = mulDiv(changeInCollateral, 0.001e18, 1e18); // 999999999999999
        assertEq(balAfter, balBefore + (changeInCollateral - adjustmentFee), "Owner balance not adjusted");
    }

    function testDecreasingTheCollateralDeltaTransfersTokensToUsersUnwrap(uint256 _collateralDelta)
        public
        setUpMarkets
    {
        // Bound input
        _collateralDelta = bound(_collateralDelta, 1000, 1 ether - 1 wei); // Below prev delta
        // Create a limit order
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 1 ether,
            sizeDelta: 25_000e30,
            limitPrice: 250_000e18,
            maxSlippage: 0.1e18,
            executionFee: 0.01e18,
            isLong: true,
            isLimit: true,
            isIncrease: true,
            reverseWrap: true,
            conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        });
        // Create request
        vm.prank(OWNER);
        router.createPositionRequest{value: 1.01 ether}(input);
        // Attempt to adjust it with valid parameters
        Position.Adjustment memory params;
        params.orderKey = tradeStorage.getOrderAtIndex(0, true);
        params.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        params.sizeDelta = 0;
        params.collateralDelta = _collateralDelta;
        params.collateralIn = 0;
        params.limitPrice = 0;
        params.maxSlippage = 0;
        params.isLongToken = true;
        params.reverseWrap = false;
        uint256 balBefore = WETH(weth).balanceOf(OWNER);
        vm.prank(OWNER);
        positionManager.adjustLimitOrder(params);
        uint256 balAfter = WETH(weth).balanceOf(OWNER);
        uint256 changeInCollateral = 1 ether - _collateralDelta; // 999999999999999000
        uint256 adjustmentFee = mulDiv(changeInCollateral, 0.001e18, 1e18); // 999999999999999
        assertEq(balAfter, balBefore + (changeInCollateral - adjustmentFee), "Owner balance not adjusted");
    }

    function testDecreasingTheCollateralDeltaTransfersTokensToUserShort(uint256 _collateralDelta) public setUpMarkets {
        // Bound input
        _collateralDelta = bound(_collateralDelta, 1000, 2500e6 - 1); // Below prev delta
        // Create a limit order
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: usdc,
            collateralDelta: 2500e6,
            sizeDelta: 25_000e30,
            limitPrice: 250_000e18,
            maxSlippage: 0.1e18,
            executionFee: 0.01e18,
            isLong: false,
            isLimit: true,
            isIncrease: true,
            reverseWrap: false,
            conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        });
        // Create request
        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createPositionRequest{value: 0.01 ether}(input);
        vm.stopPrank();
        // Attempt to adjust it with valid parameters
        Position.Adjustment memory params;
        params.orderKey = tradeStorage.getOrderAtIndex(0, true);
        params.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        params.sizeDelta = 0;
        params.collateralDelta = _collateralDelta;
        params.collateralIn = 0;
        params.limitPrice = 0;
        params.maxSlippage = 0;
        params.isLongToken = false;
        params.reverseWrap = false;
        uint256 balBefore = MockUSDC(usdc).balanceOf(OWNER);
        vm.prank(OWNER);
        positionManager.adjustLimitOrder(params);
        uint256 balAfter = MockUSDC(usdc).balanceOf(OWNER);
        uint256 changeInCollateral = 2500e6 - _collateralDelta;
        uint256 adjustmentFee = mulDiv(changeInCollateral, 0.001e18, 1e18);
        assertEq(balAfter, balBefore + (changeInCollateral - adjustmentFee), "Owner balance not adjusted");
    }

    function testDecreaseLimitsCantExceedThePositionSize(uint256 _collateralDelta) public setUpMarkets {
        // Bound input to larger than position size
        vm.assume(_collateralDelta > 1 ether);
        // Create a limit order
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 1 ether,
            sizeDelta: 25_000e30,
            limitPrice: 250_000e18,
            maxSlippage: 0.1e18,
            executionFee: 0.01e18,
            isLong: true,
            isLimit: true,
            isIncrease: true,
            reverseWrap: true,
            conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        });
        // Create request
        vm.prank(OWNER);
        router.createPositionRequest{value: 1.01 ether}(input);
        // Attempt to adjust it with valid parameters
        Position.Adjustment memory params;
        params.orderKey = tradeStorage.getOrderAtIndex(0, true);
        params.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        params.sizeDelta = 0;
        params.collateralDelta = _collateralDelta;
        params.collateralIn = 0;
        params.limitPrice = 0;
        params.maxSlippage = 0;
        params.isLongToken = true;
        params.reverseWrap = false;
        vm.prank(OWNER);
        vm.expectRevert();
        positionManager.adjustLimitOrder(params);
    }

    function testAdjustingWithIncorrectToken() public setUpMarkets {
        // Create a limit order
        Position.Input memory input = Position.Input({
            assetId: ethAssetId,
            collateralToken: weth,
            collateralDelta: 1 ether,
            sizeDelta: 25_000e30,
            limitPrice: 250_000e18,
            maxSlippage: 0.1e18,
            executionFee: 0.01e18,
            isLong: true,
            isLimit: true,
            isIncrease: true,
            reverseWrap: true,
            conditionals: Position.Conditionals(false, false, 0, 0, 0, 0)
        });
        // Create request
        vm.prank(OWNER);
        router.createPositionRequest{value: 1.01 ether}(input);
        // Attempt to adjust it with valid parameters
        Position.Adjustment memory params;
        params.orderKey = tradeStorage.getOrderAtIndex(0, true);
        params.conditionals = Position.Conditionals(false, false, 0, 0, 0, 0);
        params.sizeDelta = 0;
        params.collateralDelta = 0.1 ether;
        params.collateralIn = 0;
        params.limitPrice = 0;
        params.maxSlippage = 0;
        params.isLongToken = false;
        params.reverseWrap = false;
        vm.prank(OWNER);
        vm.expectRevert();
        positionManager.adjustLimitOrder(params);
    }
}
