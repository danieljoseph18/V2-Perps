// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

contract TradeVault is RoleValidation {
    using SafeERC20 for IERC20;
    // contract responsible for handling all tokens
    mapping(bytes32 _marketKey => uint256 _collateral) public longCollateral;
    mapping(bytes32 _marketKey => uint256 _collateral) public shortCollateral;

    mapping(address _user => uint256 _rewards) public liquidationRewards;

    constructor() RoleValidation(roleStorage) {}


    // contract must be validated to transfer funds from TradeStorage
    // perhaps need to adopt a plugin transfer method like GMX V1
    // Note Should only Do 1 thing, transfer out tokens and update state
    // Separate PNL substitution
    function transferOutTokens(address _token, bytes32 _marketKey, address _to, uint256 _collateralDelta, bool _isLong) external {
        // profit = size now - initial size => initial size is not their
        uint256 amount = _collateralDelta;
        _isLong ? longCollateral[_marketKey] -= amount : shortCollateral[_marketKey] -= amount;
        // NEED TO ALSO GET PNL FROM LIQUIDITY VAULT TO COVER THIS
        IERC20(_token).safeTransfer( _to, amount);
    }

    /// Claim funding fees for a specified position
    // function claimFundingFees(bytes32 _positionKey) external {
    //     // get the position
    //     MarketStructs.Position memory position = openPositions[_positionKey];
    //     // check that the position exists
    //     require(position.user != address(0), "Position does not exist");
    //     // get the funding fees a user is eligible to claim for that position
    //     (uint256 longFunding, uint256 shortFunding) = _getFundingFees(position);
    //     // if none, revert
    //     uint256 earnedFundingFees = position.isLong ? shortFunding : longFunding;
    //     if (earnedFundingFees == 0) revert("No funding fees to claim"); // Note Update to custom revert
    //     // apply funding fees to position size
    //     uint256 feesOwed = unwrap(ud(earnedFundingFees) * ud(position.positionSize)); // Note Check scale
    //     uint256 claimable = feesOwed - position.fundingParams.realisedFees; // underflow also = no fees
    //     if (claimable == 0) revert("No funding fees to claim"); // Note Update to custom revert
    //     bytes32 marketKey = getMarketKey(position.indexToken, position.collateralToken);
    //     if (position.isLong) {
    //         require(shortCollateral[marketKey] >= claimable, "Not enough collateral to claim"); // Almost impossible scenario
    //     } else {
    //         require(longCollateral[marketKey] >= claimable, "Not enough collateral to claim"); // Almost impossible scenario
    //     }
    //     // if some to claim, add to realised funding of the position
    //     openPositions[_positionKey].fundingParams.realisedFees += claimable;
    //     // transfer funding from the counter parties' liquidity pool
    //     position.isLong ? shortCollateral[marketKey] -= claimable : longCollateral[marketKey] -= claimable;
    //     // transfer funding to the user
    //     IERC20(position.collateralToken).safeTransfer(position.user, claimable);
    // }
}