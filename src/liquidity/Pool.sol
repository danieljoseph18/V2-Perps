// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IDataOracle} from "../oracle/interfaces/IDataOracle.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library Pool {
    uint256 public constant SCALING_FACTOR = 1e18;

    struct Values {
        IDataOracle dataOracle;
        IPriceOracle priceOracle;
        address longToken;
        address shortToken;
        uint256 longTokenBalance;
        uint256 shortTokenBalance;
        uint256 marketTokenSupply;
        uint256 blockNumber;
        uint256 longBaseUnit;
        uint256 shortBaseUnit;
    }

    function calculateUsdValue(
        bool _isLongToken,
        uint256 _longBaseUnit,
        uint256 _shortBaseUnit,
        uint256 _price,
        uint256 _amount
    ) external pure returns (uint256 valueUsd) {
        if (_isLongToken) {
            valueUsd = Math.mulDiv(_amount, _price, _longBaseUnit);
        } else {
            valueUsd = Math.mulDiv(_amount, _price, _shortBaseUnit);
        }
    }

    function getMarketTokenPrice(Values memory _values, uint256 _longTokenPrice, uint256 _shortTokenPrice)
        external
        view
        returns (uint256 lpTokenPrice)
    {
        // market token price = (worth of market pool in USD) / total supply
        uint256 aum = getAum(_values, _longTokenPrice, _shortTokenPrice);
        if (aum == 0 || _values.marketTokenSupply == 0) {
            lpTokenPrice = 0;
        } else {
            lpTokenPrice = Math.mulDiv(aum, SCALING_FACTOR, _values.marketTokenSupply);
        }
    }

    // @audit - probably need to account for some fees
    function getAum(Values memory _values, uint256 _longTokenPrice, uint256 _shortTokenPrice)
        public
        view
        returns (uint256 aum)
    {
        // Get Values in USD
        uint256 longTokenValue = Math.mulDiv(_values.longTokenBalance, _longTokenPrice, _values.longBaseUnit);
        uint256 shortTokenValue = Math.mulDiv(_values.shortTokenBalance, _shortTokenPrice, _values.shortBaseUnit);

        // Calculate PNL
        int256 pnl = _values.dataOracle.getCumulativeNetPnl(_values.blockNumber);

        // Calculate AUM
        aum = pnl >= 0
            ? longTokenValue + shortTokenValue + uint256(pnl)
            : longTokenValue + shortTokenValue - uint256(-pnl);
    }
}
