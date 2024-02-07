// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {RoleValidation} from "../access/RoleValidation.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Position} from "../positions/Position.sol";
import {Trade} from "../positions/Trade.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

// Contract for Auto Deleveraging markets
// Maintain a profit to pool ratio for each pool
// If it's exceeded, start forcing positions to take profit (45%)
// Start with the most profitable positions
// ADLs happen for a specific side of the market

contract Adl is RoleValidation {
    using SignedMath for int256;

    IPriceOracle public priceOracle;
    IDataOracle public dataOracle;
    ITradeStorage public tradeStorage;

    event AdlExecuted(IMarket indexed market, bytes32 indexed positionKey, uint256 sizeDelta, bool isLong);

    constructor(address _tradeStorage, address _priceOracle, address _dataOracle, address _roleStorage)
        RoleValidation(_roleStorage)
    {
        tradeStorage = ITradeStorage(_tradeStorage);
        priceOracle = IPriceOracle(_priceOracle);
        dataOracle = IDataOracle(_dataOracle);
    }

    function flagForAdl(IMarket _market, bool _isLong) external onlyAdlKeeper {
        require(_market != IMarket(address(0)), "ADL: Invalid market");
        // get current price
        address indexToken = _market.indexToken();
        uint256 price = priceOracle.getPrice(indexToken);
        uint256 baseUnit = dataOracle.getBaseUnits(indexToken);
        // fetch pnl to pool ratio
        int256 pnlFactor = MarketUtils.getPnlFactor(_market, price, baseUnit, _isLong);
        // fetch max pnl to pool ratio
        uint256 maxPnlFactor = _market.maxPnlFactor();

        if (pnlFactor.abs() > maxPnlFactor && pnlFactor > 0) {
            _market.updateAdlState(true, _isLong);
        } else {
            revert("ADL: PTP ratio not exceeded");
        }
    }

    /**
     * struct ExecuteCache {
     *     IMarket market; x
     *     uint256 indexPrice; x
     *     uint256 indexBaseUnit; x
     *     uint256 impactedPrice; x
     *     uint256 longMarketTokenPrice; x
     *     uint256 shortMarketTokenPrice; x
     *     int256 sizeDeltaUsd; x
     *     uint256 collateralPrice; x
     *     uint256 fee; 0
     *     uint256 feeDiscount; 0
     *     address referrer; address(0)
     * }
     */
    function executeAdl(IMarket _market, uint256 _sizeDelta, bytes32 _positionKey, bool _isLong)
        external
        onlyAdlKeeper
    {
        Trade.ExecuteCache memory cache;
        // Check ADL is enabled for the market and for the side
        if (_isLong) {
            require(_market.adlFlaggedLong(), "ADL: Long side not flagged");
        } else {
            require(_market.adlFlaggedShort(), "ADL: Short side not flagged");
        }
        // Check the position in question is active
        Position.Data memory position = tradeStorage.getPosition(_positionKey);
        require(position.positionSize > 0, "ADL: Position not active");
        // cache the market
        cache.market = _market;
        // Get current pricing and token data
        cache.indexPrice = priceOracle.getPrice(_market.indexToken());
        cache.indexBaseUnit = dataOracle.getBaseUnits(_market.indexToken());
        // Get token prices
        (cache.longMarketTokenPrice, cache.shortMarketTokenPrice) = priceOracle.getInstantMarketTokenPrices();
        // Get collateral price
        cache.collateralPrice = position.isLong ? cache.longMarketTokenPrice : cache.shortMarketTokenPrice;
        // Get size delta usd
        cache.sizeDeltaUsd = -int256(Math.mulDiv(_sizeDelta, cache.indexPrice, cache.indexBaseUnit));
        // Check the position is profitable
        int256 pnl = Position.getPnl(position, cache.indexPrice, cache.indexBaseUnit);
        require(pnl > 0, "ADL: Position not profitable");
        // Get starting PNL Factor
        int256 startingPnlFactor = MarketUtils.getPnlFactor(_market, cache.indexPrice, cache.indexBaseUnit, _isLong);
        // Construct an ADL Order
        Position.Execution memory request =
            Position.createAdlOrder(position, _sizeDelta, cache.indexPrice, cache.collateralPrice);
        // Execute the order
        tradeStorage.decreaseExistingPosition(request, cache);
        // Get the new PNL to pool ratio
        int256 newPnlFactor = MarketUtils.getPnlFactor(_market, cache.indexPrice, cache.indexBaseUnit, _isLong);
        // PNL to pool has reduced
        require(newPnlFactor < startingPnlFactor, "ADL: PNL Factor not reduced");
        // Check if the new PNL to pool ratio is greater than
        // the min PNL factor after ADL (~20%)
        // If not, unflag for ADL
        if (newPnlFactor.abs() <= _market.targetPnlFactor()) {
            _market.updateAdlState(false, _isLong);
        }
        emit AdlExecuted(_market, _positionKey, _sizeDelta, _isLong);
    }
}
