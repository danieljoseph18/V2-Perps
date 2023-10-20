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

    ITradeStorage public tradeStorage;
    IMarketStorage public marketStorage;

    mapping(bytes32 => bool) isFlagged;

    error Liquidator_PositionAlreadyFlagged();
    error Liquidator_PositionNotLiquidatable();
    error Liquidator_PositionNotFlagged();

    constructor(ITradeStorage _tradeStorage, IMarketStorage _marketStorage) RoleValidation(roleStorage) {
        tradeStorage = _tradeStorage;
        marketStorage = _marketStorage;
    }

    function flagForLiquidation(bytes32 _positionKey) external onlyKeeper {
        // check if position is already flagged for liquidation
        if (isFlagged[_positionKey]) revert Liquidator_PositionAlreadyFlagged();
        // get the position
        MarketStructs.Position memory _position = tradeStorage.openPositions(_positionKey);
        // check if collateral is below liquidation threshold
        if (!_checkIsLiquidatable(_position)) revert Liquidator_PositionNotLiquidatable();
        isFlagged[_positionKey] = true;
    }

    // need to store who flagged and liquidated
    // let the liquidator claim liquidation rewards from the tradestorage contract
    function liquidatePosition(bytes32 _positionKey) external onlyKeeper {
        // check if position is flagged for liquidation
        if (!isFlagged[_positionKey]) revert Liquidator_PositionNotFlagged();
        tradeStorage.liquidatePosition(_positionKey, msg.sender);
    }

    // need to also factor in associated fees
    // position needs a base liquidation fee measured in usd
    //Review
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
