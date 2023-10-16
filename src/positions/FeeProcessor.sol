// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MarketStructs} from "../markets/MarketStructs.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketStorage} from "../markets/interfaces/IMarketStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {SD59x18, sd, unwrap, pow} from "@prb/math/SD59x18.sol";
import {UD60x18, ud, unwrap} from "@prb/math/UD60x18.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {FundingCalculator} from "./FundingCalculator.sol";

contract FeeProcessor is RoleValidation {
    using SafeCast for uint256;
    using SafeCast for int256;
    // contract handles the processing of all fees using the available libraries

    constructor() RoleValidation(roleStorage) {}

    // takes in borrow and funding fees owed
    // subtracts them
    // sends them to the liquidity vault
    // returns the collateral amount
    function processFees(MarketStructs.Position memory _position, uint256 _collateralDelta)
        internal
        returns (uint256 _afterFeeAmount)
    {
        // (uint256 borrowFee, int256 fundingFees,) = getPositionFees(_position);

        // int256 totalFees = borrowFee.toInt256() + fundingFees; // 0.0001e18 = 0.01%

        // if (totalFees > 0) {
        //     // subtract the fee from the position collateral delta
        //     uint256 fees = unwrap(ud(totalFees.toUint256()) * ud(_collateralDelta));
        //     // give fees to liquidity vault
        //     // Note need to store funding fees separately from borrow fees
        //     // Funding fees need to be claimable by the counterparty
        //     accumulatedRewards[address(liquidityVault)] += fees;
        //     // return size + fees
        //     _afterFeeAmount = _collateralDelta + fees;
        // } else if (totalFees < 0) {
        //     // user is owed fees
        //     // add fee to mapping in liquidity vault
        //     uint256 fees = (-totalFees).toUint256() * _collateralDelta; // precision
        //     liquidityVault.accumulateFundingFees(fees, _position.user);
        //     _afterFeeAmount = _collateralDelta;
        // } else {
        //     _afterFeeAmount = _collateralDelta;
        // }
    }
}
