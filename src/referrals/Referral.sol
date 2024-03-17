// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IReferralStorage} from "./interfaces/IReferralStorage.sol";
import {mulDiv} from "@prb/math/Common.sol";

// Library for referral related logic
library Referral {
    uint256 constant PRECISION = 1e18;

    /**
     * Precision loss - Fee discount should be 5% of the fee
     *     currently works out to 5.263157894736825%
     */
    function applyFeeDiscount(IReferralStorage referralStorage, address _account, uint256 _fee)
        external
        view
        returns (uint256 newFee, uint256 affiliateRebate, address codeOwner)
    {
        uint256 discountPercentage = referralStorage.getDiscountForUser(_account);
        uint256 totalReduction = mulDiv(_fee, discountPercentage, PRECISION);
        // 50% goes to user as extra collateral, 50% goes to code owner
        uint256 discount = totalReduction / 2;
        affiliateRebate = totalReduction - discount;
        codeOwner = referralStorage.getAffiliateFromUser(_account);
        newFee = _fee - discount;
    }
}
