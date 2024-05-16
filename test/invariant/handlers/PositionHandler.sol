// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Router} from "src/router/Router.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {TradeStorage} from "src/positions/TradeStorage.sol";
import {Market} from "src/markets/Market.sol";
import {Position} from "src/positions/Position.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {MarketId} from "src/types/MarketId.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {WETH} from "src/tokens/WETH.sol";
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {Execution} from "src/positions/Execution.sol";
import {WETH} from "src/tokens/WETH.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {MarketUtils} from "src/markets/MarketUtils.sol";
import {Vault} from "src/markets/Vault.sol";
import {Casting} from "src/libraries/Casting.sol";
import {Units} from "src/libraries/Units.sol";

contract PositionHandler is Test {
    using Casting for uint256;
    using Units for uint256;

    struct PositionDetails {
        uint256 size;
        uint256 leverage;
        bytes32 key;
    }

    Router router;
    PositionManager positionManager;
    TradeStorage tradeStorage;
    Market market;
    MockPriceFeed priceFeed;
    Vault vault;

    string ethTicker = "ETH";
    address weth;
    address usdc;
    MarketId marketId;

    uint8[] precisions;
    uint16[] variances;
    uint48[] timestamps;
    uint64[] meds;
    string[] tickers;

    address user0 = vm.addr(uint256(keccak256("User0")));
    address user1 = vm.addr(uint256(keccak256("User1")));
    address user2 = vm.addr(uint256(keccak256("User2")));
    address user3 = vm.addr(uint256(keccak256("User3")));
    address user4 = vm.addr(uint256(keccak256("User4")));
    address user5 = vm.addr(uint256(keccak256("User5")));

    address[6] actors;

    receive() external payable {}

    constructor(
        address _weth,
        address _usdc,
        address payable _router,
        address payable _positionManager,
        address _tradeStorage,
        address _market,
        address payable _vault,
        address _priceFeed,
        MarketId _marketId
    ) {
        weth = _weth;
        vm.label(weth, "weth");
        usdc = _usdc;
        vm.label(usdc, "usdc");
        router = Router(_router);
        positionManager = PositionManager(_positionManager);
        tradeStorage = TradeStorage(_tradeStorage);
        market = Market(_market);
        priceFeed = MockPriceFeed(_priceFeed);
        vault = Vault(_vault);
        marketId = _marketId;

        tickers.push("ETH");
        tickers.push("USDC");

        precisions.push(0);
        precisions.push(0);

        variances.push(0);
        variances.push(0);

        timestamps.push(uint48(block.timestamp));
        timestamps.push(uint48(block.timestamp));

        meds.push(3000);
        meds.push(1);

        actors[0] = user0;
        vm.label(user0, "user0");

        actors[1] = user1;
        vm.label(user1, "user1");

        actors[2] = user2;
        vm.label(user2, "user2");

        actors[3] = user3;
        vm.label(user3, "user3");

        actors[4] = user4;
        vm.label(user4, "user4");

        actors[5] = user5;
        vm.label(user5, "user5");
    }

    modifier passTime(uint256 _timeToSkip) {
        _timeToSkip = bound(_timeToSkip, 1, 36500 days);
        _;
    }

    function createIncreasePosition(
        uint256 _seed,
        uint256 _price,
        uint256 _sizeDelta,
        uint256 _timeToSkip,
        uint256 _leverage,
        bool _isLong,
        bool _shouldWrap
    ) external passTime(_timeToSkip) {
        // Pre-Conditions
        address owner = randomAddress(_seed);

        _deal(owner);

        _price = bound(_price, 500, 10_000);
        _updateEthPrice(_price);

        uint256 availUsd = _getAvailableOi(_price * 1e30, _isLong);
        if (availUsd < 210e30) return;
        _sizeDelta = bound(_sizeDelta, 210e30, availUsd);

        // Create Request
        Position.Input memory input;
        _leverage = bound(_leverage, 2, 90);
        bytes32 key;
        if (_isLong) {
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e18, (_price * 1e30));
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: true,
                isLimit: false,
                isIncrease: true,
                reverseWrap: _shouldWrap,
                triggerAbove: false
            });
            if (_shouldWrap) {
                if (collateralDelta > owner.balance) return;
                vm.prank(owner);
                key = router.createPositionRequest{value: collateralDelta + 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
            } else {
                if (collateralDelta > WETH(weth).balanceOf(owner)) return;
                vm.startPrank(owner);
                WETH(weth).approve(address(router), type(uint256).max);
                key = router.createPositionRequest{value: 0.01 ether}(
                    marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
                );
                vm.stopPrank();
            }
        } else {
            uint256 collateralDelta = MathUtils.mulDiv(_sizeDelta / _leverage, 1e6, 1e30);
            input = Position.Input({
                ticker: ethTicker,
                collateralToken: usdc,
                collateralDelta: collateralDelta,
                sizeDelta: _sizeDelta, // 10x leverage
                limitPrice: 0,
                maxSlippage: 0.3e30,
                executionFee: 0.01 ether,
                isLong: false,
                isLimit: false,
                isIncrease: true,
                reverseWrap: false,
                triggerAbove: false
            });
            if (collateralDelta > MockUSDC(usdc).balanceOf(owner)) return;
            vm.startPrank(owner);
            MockUSDC(usdc).approve(address(router), type(uint256).max);

            key = router.createPositionRequest{value: 0.01 ether}(
                marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
            );
            vm.stopPrank();
        }
        // Execute Request
        vm.prank(owner);
        positionManager.executePosition(marketId, key, bytes32(0), owner);
    }

    // @audit - need to make sure the decrease doesn't put the position below the minimum leverage or above the max
    /**
     * For Decrease:
     * 1. Position should still be valid after (collateral > 2e30, lev 1-100)
     * 2. Collateral delta should be enough to cover fees
     */
    function createDecreasePosition(
        uint256 _seed,
        uint256 _timeToSkip,
        uint256 _price,
        uint256 _decreasePercentage,
        bool _isLong
    ) external passTime(_timeToSkip) {
        // Pre-Conditions
        address owner = randomAddress(_seed);

        _deal(owner);

        Position.Data memory position =
            tradeStorage.getPosition(marketId, Position.generateKey(ethTicker, owner, _isLong));

        // Check if position exists
        if (position.size == 0) return;

        _price = bound(_price, 500, 10_000);
        _updateEthPrice(_price);

        _decreasePercentage = bound(_decreasePercentage, 0.01e18, 1e18);

        uint256 sizeDelta = position.size.percentage(_decreasePercentage);

        console2.log("made it before collateral delta");

        // If fees exceed collateral delta, increase
        uint256 collateralDelta = position.collateral.percentage(_decreasePercentage);

        console2.log("made it here");

        // Get total fees owed by the position
        uint256 totalFees = _getTotalFeesOwed(owner, _isLong);

        console2.log("made it here");

        int256 pnl = _getPnl(position, sizeDelta);

        console2.log("pnl: ", pnl);

        uint256 freeLiq = _getFreeLiquidityWithBuffer(_isLong);

        console2.log("free liq: ", freeLiq);

        // Skip the case where PNL exceeds the available payout
        if (pnl > freeLiq.toInt256()) return;

        // Full decrease if size after decrease is less than 2e30 or fees exceed collateral delta
        if (position.size - sizeDelta < 2e30 || totalFees >= collateralDelta) {
            sizeDelta = position.size;
        }

        Position.Input memory input = Position.Input({
            ticker: ethTicker,
            collateralToken: _isLong ? weth : usdc,
            collateralDelta: 0,
            sizeDelta: sizeDelta,
            limitPrice: 0,
            maxSlippage: 0.3e30,
            executionFee: 0.01 ether,
            isLong: _isLong,
            isLimit: false,
            isIncrease: false,
            reverseWrap: false,
            triggerAbove: false
        });

        vm.prank(owner);
        bytes32 orderKey = router.createPositionRequest{value: 0.01 ether}(
            marketId, input, Position.Conditionals(false, false, 0, 0, 0, 0)
        );

        // Execute Request
        vm.prank(owner);
        positionManager.executePosition(marketId, orderKey, bytes32(0), owner);
    }

    /**
     * =================================== Internal Functions ===================================
     */
    function _updateEthPrice(uint256 _price) private {
        meds[0] = uint64(_price);
        timestamps[0] = uint48(block.timestamp);
        timestamps[1] = uint48(block.timestamp);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
    }

    function _getTotalFeesOwed(address _owner, bool _isLong) private view returns (uint256) {
        bytes32 positionKey = Position.generateKey(ethTicker, _owner, _isLong);
        Position.Data memory position = tradeStorage.getPosition(marketId, positionKey);
        uint256 indexPrice = uint256(meds[0]) * (1e30);

        Execution.Prices memory prices;
        prices.indexPrice = indexPrice;
        prices.indexBaseUnit = 1e18;
        prices.impactedPrice = indexPrice;
        prices.longMarketTokenPrice = indexPrice;
        prices.shortMarketTokenPrice = 1e30;
        prices.priceImpactUsd = 0;
        prices.collateralPrice = _isLong ? indexPrice : 1e30;
        prices.collateralBaseUnit = _isLong ? 1e18 : 1e6;

        return Position.getTotalFeesOwedUsd(marketId, market, position, prices.indexPrice);
    }

    function _deal(address _user) private {
        deal(_user, 100_000_000 ether);
        deal(weth, _user, 100_000_000 ether);
        deal(usdc, _user, 300_000_000_000e6);
    }

    function _getAvailableOi(uint256 _indexPrice, bool _isLong) private view returns (uint256) {
        return MarketUtils.getAvailableOiUsd(
            marketId, market, vault, ethTicker, _indexPrice, _isLong ? _indexPrice : 1e30, _isLong ? 1e18 : 1e6, _isLong
        );
    }

    function _getPnl(Position.Data memory _position, uint256 _sizeDelta) private view returns (int256) {
        uint256 indexPrice = uint256(meds[0]) * 1e30;
        return Position.getRealizedPnl(
            _position.size,
            _sizeDelta,
            _position.weightedAvgEntryPrice,
            indexPrice,
            1e18,
            indexPrice,
            1e18,
            _position.isLong
        );
    }

    function _getFreeLiquidityWithBuffer(bool _isLong) private view returns (uint256) {
        uint256 freeLiquidity = vault.totalAvailableLiquidity(_isLong);
        // 40% buffer
        return (freeLiquidity * 6) / 10;
    }

    function randomAddress(uint256 seed) private view returns (address) {
        return actors[_bound(seed, 0, actors.length - 1)];
    }
}
