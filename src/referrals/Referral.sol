// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IReferralStorage} from "./interfaces/IReferralStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Library for referral related logic
library Referral {
    uint256 constant PRECISION = 1e18;

    function calculateFeeDiscount(IReferralStorage _referralStorage, address _account, uint256 _fee)
        external
        view
        returns (uint256 discount, address codeOwner)
    {
        uint256 discountPercentage = _referralStorage.getDiscountForUser(_account);
        discount = Math.mulDiv(_fee, discountPercentage, PRECISION);
        codeOwner = _referralStorage.getAffiliateFromUser(_account);
    }
}
