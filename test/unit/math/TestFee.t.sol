// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {RoleStorage} from "../../../src/access/RoleStorage.sol";
import {GlobalMarketConfig} from "../../../src/markets/GlobalMarketConfig.sol";
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
import {Market, IMarket, IVault} from "../../../src/markets/Market.sol";
import {Gas} from "../../../src/libraries/Gas.sol";
import {Funding} from "../../../src/libraries/Funding.sol";
import {PriceImpact} from "../../../src/libraries/PriceImpact.sol";
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {Pricing} from "../../../src/libraries/Pricing.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Fee} from "../../../src/libraries/Fee.sol";

contract TestFee is Test {
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
        positionManager.executeDeposit{value: 0.01 ether}(market, depositKey, ethPriceData);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(market, OWNER, usdc, 50_000_000e6, 0.01 ether, false);
        depositKey = market.getDepositRequestAtIndex(0).key;
        positionManager.executeDeposit{value: 0.01 ether}(market, depositKey, ethPriceData);
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
     * Test:
     * - Dynamic fees for market actions (deposit / withdrawal )
     * - Calculate for a position
     */
    function testConstructionOfFeeParameters(uint256 _tokenAmount) public setUpMarkets {
        (Oracle.Price memory longPrices, Oracle.Price memory shortPrices) = Oracle.getLastMarketTokenPrices(priceFeed);
        Fee.Params memory feeParams = Fee.constructFeeParams(market, _tokenAmount, true, longPrices, shortPrices, true);
        assertEq(feeParams.tokenAmount, _tokenAmount);
    }

    function testCalculatingFeesForASinglePosition(uint256 _sizeDelta) public setUpMarkets {
        _sizeDelta = bound(_sizeDelta, 1, 1_000_000_000e30);
        // convert size delta usd to collateral
        uint256 sizeDeltaCollateral = mulDiv(_sizeDelta, 1e18, 2500e30);
        // calculate expected fee
        uint256 expectedFee = mulDiv(sizeDeltaCollateral, tradeStorage.tradingFee(), 1e18);
        // calculate fee
        uint256 fee = Fee.calculateForPosition(tradeStorage, _sizeDelta, 0, 2500e30, 1e18);
        assertEq(fee, expectedFee);
    }

    function testCalculatingFeesForAMarketAction(uint256 _tokenAmount) public setUpMarkets {
        _tokenAmount = bound(_tokenAmount, 1000, 1_000_000_000e18);
        (Oracle.Price memory longPrices, Oracle.Price memory shortPrices) = Oracle.getLastMarketTokenPrices(priceFeed);
        Fee.Params memory feeParams = Fee.constructFeeParams(market, _tokenAmount, true, longPrices, shortPrices, true);

        uint256 fee =
            Fee.calculateForMarketAction(feeParams, market.longTokenBalance(), 1e18, market.shortTokenBalance(), 1e6);
        console.log("Fee: ", fee);
        require(fee >= 0, "Invalid Fee");
    }
}
