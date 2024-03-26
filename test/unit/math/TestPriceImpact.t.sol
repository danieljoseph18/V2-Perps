// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
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
import {Market, IMarket} from "../../../src/markets/Market.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Execution} from "../../../src/positions/Execution.sol";
import {MarketUtils} from "../../../src/markets/MarketUtils.sol";

contract TestPriceImpact is Test {
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

    modifier setUpMarketsDeepLiquidity() {
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
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(market, OWNER, weth, 20_000 ether, 0.01 ether, true);
        bytes32 depositKey = market.getRequestAtIndex(0).key;
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.001 ether}(market, depositKey, ethPriceData);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
        depositKey = market.getRequestAtIndex(0).key;
        positionManager.executeDeposit{value: 0.001 ether}(market, depositKey, ethPriceData);
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

    modifier setUpMarketsShallowLiquidity() {
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
        router.createDeposit{value: 100.01 ether + 1 gwei}(market, OWNER, weth, 100 ether, 0.01 ether, true);
        bytes32 depositKey = market.getRequestAtIndex(0).key;
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.001 ether}(market, depositKey, ethPriceData);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 250_000e6, 0.01 ether, false);
        depositKey = market.getRequestAtIndex(0).key;
        positionManager.executeDeposit{value: 0.001 ether}(market, depositKey, ethPriceData);
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

    /**
     * Actual Impacted Price PRB Math: 2551.072469825497887958
     * Expected Impacted Price:        2551.072469825497887958
     * Delta: 0
     *
     * Actual Price Impact PRB Math: -200008000080000000000
     * Expected Price Impact: -200008000080000000000
     * Delta: 0
     */

    // $50M Long / Short Liquidity
    function testPriceImpactValuesDeepLiquidity(uint256 _sizeDelta, uint256 _longOi, uint256 _shortOi)
        public
        setUpMarketsDeepLiquidity
    {
        // bound the inputs to realistic values
        _sizeDelta = bound(_sizeDelta, 2500e30, 125_000e30); // $2500 - $125,000
        _longOi = bound(_longOi, 0, 175_00030); // $0 - $175,000
        _shortOi = bound(_shortOi, 0, 175_00030); // $0 - $175,000

        Position.Request memory request = Position.Request({
            input: Position.Input({
                assetId: ethAssetId,
                collateralToken: weth,
                collateralDelta: 0.5 ether,
                sizeDelta: _sizeDelta,
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
            }),
            user: USER,
            requestBlock: block.number,
            requestType: Position.RequestType.POSITION_INCREASE
        });
        // Test negative price impact values

        Execution.State memory orderState = Execution.State({
            indexPrice: 2500e18,
            indexBaseUnit: 1e18,
            impactedPrice: 2500.05e18,
            longMarketTokenPrice: 2500e18,
            shortMarketTokenPrice: 1e18,
            collateralDeltaUsd: 0,
            priceImpactUsd: 0,
            collateralPrice: 1e18,
            collateralBaseUnit: 1e6,
            borrowFee: 0,
            fee: 0,
            affiliateRebate: 0,
            referrer: address(0)
        });

        // Get market storage
        IMarket.MarketStorage memory marketStorage = market.getStorage(ethAssetId);
        marketStorage.openInterest.longOpenInterest = _longOi;
        marketStorage.openInterest.shortOpenInterest = _shortOi;

        // Mock call open interest values
        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getStorage.selector, ethAssetId), abi.encode(marketStorage)
        );

        (orderState.impactedPrice, orderState.priceImpactUsd) =
            PriceImpact.execute(market, priceFeed, request, orderState);
    }

    function testPriceImpactValuesShallowLiquidity(uint256 _sizeDelta, uint256 _longOi, uint256 _shortOi)
        public
        setUpMarketsShallowLiquidity
    {
        // bound the inputs to realistic values
        _sizeDelta = bound(_sizeDelta, 2500e30, 125000e30);
        _longOi = bound(_longOi, 0, 175_00030);
        _shortOi = bound(_shortOi, 0, 175_00030);

        Position.Request memory request = Position.Request({
            input: Position.Input({
                assetId: ethAssetId,
                collateralToken: weth,
                collateralDelta: 0.5 ether,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 1e18,
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
            }),
            user: USER,
            requestBlock: block.number,
            requestType: Position.RequestType.POSITION_INCREASE
        });
        // Test negative price impact values

        Execution.State memory orderState = Execution.State({
            indexPrice: 2500e18,
            indexBaseUnit: 1e18,
            impactedPrice: 2500.05e18,
            longMarketTokenPrice: 2500e18,
            shortMarketTokenPrice: 1e18,
            collateralDeltaUsd: 0,
            priceImpactUsd: 0,
            collateralPrice: 1e18,
            collateralBaseUnit: 1e6,
            borrowFee: 0,
            fee: 0,
            affiliateRebate: 0,
            referrer: address(0)
        });

        // Get Market Storage
        IMarket.MarketStorage memory marketStorage = market.getStorage(ethAssetId);
        marketStorage.openInterest.longOpenInterest = _longOi;
        marketStorage.openInterest.shortOpenInterest = _shortOi;

        // Mock call open interest values
        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getStorage.selector, ethAssetId), abi.encode(marketStorage)
        );

        (orderState.impactedPrice, orderState.priceImpactUsd) =
            PriceImpact.execute(market, priceFeed, request, orderState);
    }
}
