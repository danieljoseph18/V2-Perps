// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {ILiquidityVault} from "../markets/interfaces/ILiquidityVault.sol";
import {SD59x18, sd, unwrap, pow} from "@prb/math/SD59x18.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library PnLCalculator {
    using SafeCast for uint256;
    using SafeCast for int256;

    // USD worth : cumulative USD paid
    // needs to take into account longs and shorts
    // if long, entry - position = pnl, if short, position - entry = pnl
    function calculatePnL(address _market, MarketStructs.Position memory _position) external view returns (int256) {
        uint256 positionValue = _position.positionSize * IMarket(_market).getPrice(_position.indexToken);
        uint256 entryValue = _position.positionSize * _position.averagePricePerToken;
        return _position.isLong
            ? entryValue.toInt256() - positionValue.toInt256()
            : positionValue.toInt256() - entryValue.toInt256();
    }

    // returns the difference between the worth of index token open interest and collateral token
    // NEED TO SCALE TO 1e18 DECIMALS
    function getNetPnL(address _market, address _tradeStorage, address _marketStorage, bytes32 _marketKey, bool _isLong)
        external
        view
        returns (int256)
    {
        uint256 indexValue = IMarket(_market).getIndexOpenInterestUSD(_isLong);
        uint256 entryValue = getTotalEntryValue(_market, _tradeStorage, _marketStorage, _marketKey, _isLong);

        return _isLong ? indexValue.toInt256() - entryValue.toInt256() : entryValue.toInt256() - indexValue.toInt256();
    }

    function getTotalEntryValue(
        address _market,
        address _tradeStorage,
        address _marketStorage,
        bytes32 _marketKey,
        bool _isLong
    ) public view returns (uint256) {
        // get the number of active positions => to do this need to add way to enumerate the open positions in TradeStorage
        uint256 positionCount = ITradeStorage(_tradeStorage).openPositionKeys(_marketKey, _isLong).length;
        // averageEntryPrice = cumulativePricePaid / no positions
        uint256 cumulativePricePerToken =
            _isLong ? IMarket(_market).longCumulativePricePerToken() : IMarket(_market).shortCumulativePricePerToken();
        UD60x18 averageEntryPrice = ud(cumulativePricePerToken).div(ud(positionCount));
        // uint256 averageEntryPrice = cumulativePricePerToken / positionCount;
        // entryValue = averageEntryPrice * total OI
        return unwrap(averageEntryPrice) * calculateIndexOpenInterest(_marketStorage, _marketKey, _isLong);
    }

    // returns total trade open interest in stablecoins
    function calculateCollateralOpenInterest(address _marketStorage, bytes32 _marketKey, bool _isLong)
        public
        view
        returns (uint256)
    {
        // If long, return the long open interest
        // If short, return the short open interest
        return _isLong
            ? IMarketStorage(_marketStorage).collatTokenLongOpenInterest(_marketKey)
            : IMarketStorage(_marketStorage).collatTokenShortOpenInterest(_marketKey);
    }

    // returns the open interest in tokens of the index token
    // basically how many collateral tokens have been exchanged for index tokens
    function calculateIndexOpenInterest(address _marketStorage, bytes32 _marketKey, bool _isLong)
        public
        view
        returns (uint256)
    {
        return _isLong
            ? IMarketStorage(_marketStorage).indexTokenLongOpenInterest(_marketKey)
            : IMarketStorage(_marketStorage).indexTokenShortOpenInterest(_marketKey);
    }

    function calculateCollateralOpenInterestUSD(
        address _marketStorage,
        address _market,
        bytes32 _marketKey,
        address _collateralToken,
        bool _isLong
    ) public view returns (uint256) {
        uint256 collateralOpenInterest = calculateCollateralOpenInterest(_marketStorage, _marketKey, _isLong);
        return collateralOpenInterest * IMarket(_market).getPrice(_collateralToken);
    }

    function calculateIndexOpenInterestUSD(
        address _marketStorage,
        address _market,
        bytes32 _marketKey,
        address _indexToken,
        bool _isLong
    ) public view returns (uint256) {
        uint256 indexOpenInterest = calculateIndexOpenInterest(_marketStorage, _marketKey, _isLong);
        uint256 indexPrice = IMarket(_market).getPrice(_indexToken);
        return indexOpenInterest * indexPrice;
    }

    function calculateTotalCollateralOpenInterest(address _marketStorage, bytes32 _marketKey)
        public
        view
        returns (uint256)
    {
        return calculateCollateralOpenInterest(_marketStorage, _marketKey, true)
            + calculateCollateralOpenInterest(_marketStorage, _marketKey, false);
    }

    function calculateTotalIndexOpenInterest(address _marketStorage, bytes32 _marketKey)
        public
        view
        returns (uint256)
    {
        return calculateIndexOpenInterest(_marketStorage, _marketKey, true)
            + calculateIndexOpenInterest(_marketStorage, _marketKey, false);
    }

    function calculateTotalCollateralOpenInterestUSD(
        address _marketStorage,
        address _market,
        bytes32 _marketKey,
        address _collateralToken
    ) public view returns (uint256) {
        return calculateCollateralOpenInterestUSD(_marketStorage, _market, _marketKey, _collateralToken, true)
            + calculateCollateralOpenInterestUSD(_marketStorage, _market, _marketKey, _collateralToken, false);
    }

    function calculateTotalIndexOpenInterestUSD(
        address _marketStorage,
        address _market,
        bytes32 _marketKey,
        address _indexToken
    ) public view returns (uint256) {
        return calculateIndexOpenInterestUSD(_marketStorage, _market, _marketKey, _indexToken, true)
            + calculateIndexOpenInterestUSD(_marketStorage, _market, _marketKey, _indexToken, false);
    }

    function getPoolBalance(address _liquidityVault, bytes32 _marketKey) public view returns (uint256) {
        return ILiquidityVault(_liquidityVault).getMarketAllocation(_marketKey);
    }

    function getPoolBalanceUSD(address _liquidityVault, bytes32 _marketKey, address _market, address _collateralToken)
        public
        view
        returns (uint256)
    {
        return getPoolBalance(_liquidityVault, _marketKey) * IMarket(_market).getPrice(_collateralToken);
    }

    function getDecreasePositionPnL(
        uint256 _sizeDelta,
        uint256 _positionAveragePricePerToken,
        uint256 _currentPrice,
        bool _isLong
    ) external pure returns (int256) {
        // only realise a percentage equivalent to the percentage of the position being closed
        int256 valueDelta =
            (_sizeDelta * _positionAveragePricePerToken).toInt256() - (_sizeDelta * _currentPrice).toInt256();
        // if long, > 0 is profit, < 0 is loss
        // if short, > 0 is loss, < 0 is profit
        int256 pnl;
        // if profit, add to realised pnl
        if (valueDelta >= 0) {
            _isLong ? pnl += valueDelta : pnl -= valueDelta;
        } else {
            // subtract from realised pnl
            _isLong ? pnl -= valueDelta : pnl += valueDelta;
        }
        return pnl;
    }
}
