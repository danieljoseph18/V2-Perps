// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
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
import {Borrowing} from "../../../src/libraries/Borrowing.sol";
import {mulDiv} from "@prb/math/Common.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {MarketUtils} from "../../../src/markets/MarketUtils.sol";

contract TestFee is Test {
    using SignedMath for int256;
    using stdStorage for StdStorage;

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
        assertEq(MarketUtils.getAllocation(market, ethAssetId), 10000);
        vm.stopPrank();
        _;
    }

    /**
     * Test:
     * - Dynamic fees for market actions (deposit / withdrawal )
     * - Calculate for a position
     */
    function testCalculatingFeesForASinglePosition(uint256 _sizeDelta) public setUpMarkets {
        _sizeDelta = bound(_sizeDelta, 1, 1_000_000_000e30);
        // convert size delta usd to collateral
        uint256 sizeDeltaCollateral = mulDiv(_sizeDelta, 1e18, 2500e30);
        // calculate expected fee
        uint256 expectedFee = mulDiv(sizeDeltaCollateral, tradeStorage.tradingFee(), 1e18);
        // calculate fee
        uint256 fee = Position.calculateFee(tradeStorage, _sizeDelta, 0, 2500e30, 1e18);
        assertEq(fee, expectedFee);
    }

    function testCalculatingDepositFees(
        uint256 _tokenAmount,
        uint256 _longTokenBalance,
        uint256 _shortTokenBalance,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        bool _isLong
    ) public setUpMarkets {
        // Bound inputs to realistic ranges
        if (_isLong) {
            _tokenAmount = bound(_tokenAmount, 1, 1_000_000_000_000e18); // 1 Tn Ether
        } else {
            _tokenAmount = bound(_tokenAmount, 1, 1_000_000_000_000e6); // 1 Tn USDC
        }
        vm.assume(_longTokenBalance < 1_000_000_000_000 ether); // 1Tn Ether
        vm.assume(_shortTokenBalance < 1_000_000_000_000e6); // 1Tn USDC
        _longTokenPrice = bound(_longTokenPrice, 1e30, 1_000_000e30);
        _shortTokenPrice = bound(_shortTokenPrice, 0.9e30, 1000e30);

        // Calculate Fee
        uint256 fee = MarketUtils.calculateDepositFee(
            Oracle.Price({max: _longTokenPrice, med: _longTokenPrice, min: _longTokenPrice}),
            Oracle.Price({max: _shortTokenPrice, med: _shortTokenPrice, min: _shortTokenPrice}),
            _longTokenBalance,
            _shortTokenBalance,
            _tokenAmount,
            _isLong
        );
        // Calculate Expected Fee Range
        uint256 baseFee = mulDiv(_tokenAmount, MarketUtils.BASE_FEE, MarketUtils.SCALAR);
        uint256 maxFeeAddition = mulDiv(_tokenAmount, MarketUtils.FEE_SCALE, MarketUtils.SCALAR);
        // Validate Fee is within range
        assertLe(baseFee, fee, "Fee below base fee");
        assertGe(maxFeeAddition + baseFee, fee, "Fee above max fee");
    }

    /**
     * function calculateWithdrawalFee(
     *     uint256 _longPrice,
     *     uint256 _shortPrice,
     *     uint256 _longTokenBalance,
     *     uint256 _shortTokenBalance,
     *     uint256 _tokenAmount,
     *     bool _isLongToken
     * ) public pure returns (uint256) {
     *     uint256 baseFee = mulDiv(_tokenAmount, BASE_FEE, SCALAR);
     *
     *     // It is possible that the opposite side has 0 balance. How do we handle this?
     *
     *     // Maximize to increase the impact on the skew
     *     uint256 amountUsd = _isLongToken
     *         ? mulDiv(_tokenAmount, _longPrice, LONG_BASE_UNIT)
     *         : mulDiv(_tokenAmount, _shortPrice, SHORT_BASE_UNIT);
     *     if (amountUsd == 0) revert MarketUtils_AmountTooSmall();
     *     // Minimize value of pool to maximise the effect on the skew
     *     uint256 longValue = mulDiv(_longTokenBalance, _longPrice, LONG_BASE_UNIT);
     *     uint256 shortValue = mulDiv(_shortTokenBalance, _shortPrice, SHORT_BASE_UNIT);
     *
     *     int256 initialSkew = longValue.toInt256() - shortValue.toInt256();
     *     _isLongToken ? longValue -= amountUsd : shortValue -= amountUsd;
     *     int256 updatedSkew = longValue.toInt256() - shortValue.toInt256();
     *
     *     if (longValue + shortValue == 0) {
     *         // Charge the maximium possible fee for full withdrawals
     *         return baseFee + mulDiv(_tokenAmount, FEE_SCALE, SCALAR);
     *     }
     *
     *     // Check for a Skew Flip
     *     bool skewFlip = initialSkew ^ updatedSkew < 0;
     *
     *     // Skew Improve Same Side - Charge the Base fee
     *     if (updatedSkew.abs() < initialSkew.abs() && !skewFlip) return baseFee;
     *     // If Flip, charge full Skew After, else charge the delta
     *     uint256 negativeSkewAccrued = skewFlip ? updatedSkew.abs() : amountUsd;
     *     // Calculate the relative impact on Market Skew
     *     // Re-add amount to get the initial net pool value
     *     uint256 feeFactor = mulDiv(negativeSkewAccrued, FEE_SCALE, longValue + shortValue + amountUsd);
     *     // Calculate the additional fee
     *     uint256 feeAddition = mulDiv(feeFactor, _tokenAmount, SCALAR);
     *     // Return base fee + fee addition
     *     return baseFee + feeAddition;
     * }
     */
    function testCalculatingWithdrawalFees(
        uint256 _tokenAmount,
        uint256 _longTokenBalance,
        uint256 _shortTokenBalance,
        uint256 _longTokenPrice,
        uint256 _shortTokenPrice,
        bool _isLong
    ) public setUpMarkets {
        // Bound inputs to realistic ranges
        _longTokenBalance = bound(_longTokenBalance, 1, 1_000_000_000_000 ether); // 1Tn Ether
        _shortTokenBalance = bound(_shortTokenBalance, 1, 1_000_000_000_000e6); // 1Tn USDC
        if (_isLong) {
            _tokenAmount = bound(_tokenAmount, 1, _longTokenBalance); // 1 Tn Ether
        } else {
            _tokenAmount = bound(_tokenAmount, 1, _shortTokenBalance); // 1 Tn USDC
        }
        _longTokenPrice = bound(_longTokenPrice, 1e30, 1_000_000e30);
        _shortTokenPrice = bound(_shortTokenPrice, 0.9e30, 1000e30);

        // Calculate Fee
        uint256 fee = MarketUtils.calculateWithdrawalFee(
            _longTokenPrice, _shortTokenPrice, _longTokenBalance, _shortTokenBalance, _tokenAmount, _isLong
        );

        // Calculate Expected Fee Range
        uint256 baseFee = mulDiv(_tokenAmount, MarketUtils.BASE_FEE, MarketUtils.SCALAR);
        uint256 maxFeeAddition = mulDiv(_tokenAmount, MarketUtils.FEE_SCALE, MarketUtils.SCALAR);
        // Validate Fee is within range
        assertLe(baseFee, fee, "Fee below base fee");
        assertGe(maxFeeAddition + baseFee, fee, "Fee above max fee");
    }
}
