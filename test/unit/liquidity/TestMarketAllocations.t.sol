// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2} from "forge-std/Test.sol";
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
import {Deposit} from "../../../src/liquidity/Deposit.sol";
import {Withdrawal} from "../../../src/liquidity/Withdrawal.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {Oracle} from "../../../src/oracle/Oracle.sol";
import {Pool} from "../../../src/liquidity/Pool.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Fee} from "../../../src/libraries/Fee.sol";
import {Position} from "../../../src/positions/Position.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {Pricing} from "../../../src/libraries/Pricing.sol";
import {Order} from "../../../src/positions/Order.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract TestMarketAllocations is Test {
    using SignedMath for int256;

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
            name: "WETH/USDC",
            symbol: "WETH/USDC",
            priceFeed: address(priceFeed),
            processor: address(processor),
            minTimeToExpiration: 1 minutes,
            feeScale: 0.03e18
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

    /**
        Tests Required:

        - Listing multiple assets under the same market
        - Dividing liquidity between multiple assets in the same market
        - Testing data storage for different assets within the same market

     */

     function testCreatingMultipleAssetsUnderTheSameMarket() public {
        // create some assets
        ERC20Mock randomErc = new ERC20Mock();
        ERC20Mock randomErcTwo = new ERC20Mock();
        ERC20Mock randomErcThree = new ERC20Mock();
        Pool.VaultConfig memory wethVaultDetails = Pool.VaultConfig({
            longToken: weth,
            shortToken: usdc,
            longBaseUnit: 1e18,
            shortBaseUnit: 1e6,
            name: "WETH/USDC",
            symbol: "WETH/USDC",
            priceFeed: address(priceFeed),
            processor: address(processor),
            minTimeToExpiration: 1 minutes,
            feeScale: 0.03e18
        });
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
        Oracle.Asset memory asset1 = Oracle.Asset({
            isValid: true,
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            priceSpread: 0.01e18,
            priceProvider: Oracle.PriceProvider.PYTH,
            assetType: Oracle.AssetType.CRYPTO,
            pool: Oracle.UniswapPool(address(0), address(0), address(0), Oracle.PoolType.UNISWAP_V2)
        });
        Oracle.Asset memory asset2 = Oracle.Asset({
            isValid: true,
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            priceSpread: 0.01e18,
            priceProvider: Oracle.PriceProvider.PYTH,
            assetType: Oracle.AssetType.CRYPTO,
            pool: Oracle.UniswapPool(address(0), address(0), address(0), Oracle.PoolType.UNISWAP_V2)
        });
        Oracle.Asset memory asset3 = Oracle.Asset({
            isValid: true,
            chainlinkPriceFeed: address(0),
            priceId: ethPriceId,
            baseUnit: 1e18,
            heartbeatDuration: 1 minutes,
            maxPriceDeviation: 0.01e18,
            priceSpread: 0.01e18,
            priceProvider: Oracle.PriceProvider.PYTH,
            assetType: Oracle.AssetType.CRYPTO,
            pool: Oracle.UniswapPool(address(0), address(0), address(0), Oracle.PoolType.UNISWAP_V2)
        });

        IMarket marketInterface = IMarket(marketMaker.createNewMarket(
            wethVaultDetails,
            weth,
            ethPriceId,
            wethData
        ));
        
        uint256 firstAllocation = 5000;
        uint256 secondAllocation = 5000;

        uint256 encodedAllocation = firstAllocation << 240;

        encodedAllocation |= secondAllocation << 224;

        delete allocations; // clear allocations
        allocations.push(encodedAllocation);

        // split the allocation between the markets
        marketMaker.addTokenToMarket(marketInterface, address(randomErc), ethPriceId, asset1, allocations);

        assertEq(marketInterface.getAllocation(address(randomErc)), 5000);

        firstAllocation = 3334;
        secondAllocation = 3333;

        encodedAllocation = firstAllocation << 240;
        encodedAllocation |= secondAllocation << 224;
        encodedAllocation |= secondAllocation << 208;

        delete allocations;
        allocations.push(encodedAllocation);
        marketMaker.addTokenToMarket(marketInterface, address(randomErcTwo), ethPriceId, asset2, allocations);

        assertEq(marketInterface.getAllocation(address(randomErcTwo)), 3333);

        firstAllocation = 2500;

        encodedAllocation = firstAllocation << 240;
        encodedAllocation |= firstAllocation << 224;
        encodedAllocation |= firstAllocation << 208;
        encodedAllocation |= firstAllocation << 192;

        delete allocations;
        allocations.push(encodedAllocation);
        marketMaker.addTokenToMarket(marketInterface, address(randomErcThree), ethPriceId, asset3, allocations);
     }
    
}