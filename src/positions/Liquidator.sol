// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Needs Liquidator role
contract Liquidator is RoleValidation {
    using MarketStructs for MarketStructs.Position;
    using SafeCast for int256;
    // interacts with the TradeManager contract to liquidate positions
    // if collateral falls below threshold, user is liquidated
    // liquidator can be anyone, but must pay gas to liquidate
    // liquidator gets a fee for liquidating

    mapping(bytes32 => bool) isFlagged;

    ITradeStorage public tradeStorage;
    IMarketStorage public marketStorage;

    constructor(ITradeStorage _tradeStorage, IMarketStorage _marketStorage) RoleValidation(roleStorage) {
        tradeStorage = _tradeStorage;
        marketStorage = _marketStorage;
    }

    function flagForLiquidation(bytes32 _positionKey) external onlyKeeper {
        // check if position is already flagged for liquidation
        require(!isFlagged[_positionKey], "Position already flagged for liquidation");
        // get the position
        MarketStructs.Position memory _position = tradeStorage.openPositions(_positionKey);
        // check if collateral is below liquidation threshold
        require(_checkIsLiquidatable(_position), "Position is not liquidatable");
        isFlagged[_positionKey] = true;
    }

    // need to store who flagged and liquidated
    // let the liquidator claim liquidation rewards from the tradestorage contract
    function liquidatePosition(bytes32 _positionKey) external onlyKeeper {
        // check if position is flagged for liquidation
        require(isFlagged[_positionKey], "Position not flagged for liquidation");
        tradeStorage.liquidatePosition(_positionKey, msg.sender);
    }

    // need to also factor in associated fees
    // position needs a base liquidation fee measured in usd
    function _checkIsLiquidatable(MarketStructs.Position memory _position) internal view returns (bool) {
        address market = marketStorage.getMarket(_position.market).market;
        int256 pnl = IMarket(market).getPnL(_position);
        uint256 collateral = _position.collateralAmount;

        (uint256 borrowFee, int256 fundingFee, uint256 liquidationFee) = tradeStorage.getPositionFees(_position);

        // subtract the fees from the collateral
        collateral -= borrowFee;
        fundingFee >= 0 ? collateral -= fundingFee.toUint256() : collateral += (-fundingFee).toUint256();
        collateral -= liquidationFee;
        // check the collateral - pnl > 0
        return pnl < 0 && collateral <= (-pnl).toUint256() ? true : false;
    }
}
