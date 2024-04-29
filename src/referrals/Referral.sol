// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IReferralStorage} from "./interfaces/IReferralStorage.sol";
import {Units} from "../libraries/Units.sol";

// Library for referral related logic
library Referral {
    using Units for uint256;

    function applyFeeDiscount(IReferralStorage referralStorage, address _account, uint256 _fee)
        external
        view
        returns (uint256 newFee, uint256 affiliateRebate, address codeOwner)
    {
        uint256 discountPercentage = referralStorage.getDiscountForUser(_account);

        uint256 totalReduction = _fee.percentage(discountPercentage);

        // 50% goes to user as extra collateral, 50% goes to code owner
        uint256 discount = totalReduction / 2;
        affiliateRebate = totalReduction - discount; // Ensure full amount is accounted for in case of rounding down

        codeOwner = referralStorage.getAffiliateFromUser(_account);

        newFee = _fee - discount;
    }
}
