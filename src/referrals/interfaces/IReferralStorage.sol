// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketId} from "../../types/MarketId.sol";

interface IReferralStorage {
    // Events
    event SetHandler(address handler, bool isActive);
    event SetTraderReferralCode(address account, bytes32 code);
    event SetTier(uint256 tierId, uint256 totalDiscount);
    event SetReferrerTier(address referrer, uint256 tierId);
    event RegisterCode(address account, bytes32 code);
    event SetCodeOwner(address account, address newAccount, bytes32 code);
    event GovSetCodeOwner(bytes32 code, address newAccount);
    event AffiliateRewardsClaimed(address account, uint256 longTokenAmount, uint256 shortTokenAmount);
    event AffiliateRewardsAccumulated(address account, bool isLongToken, uint256 amount);

    error ReferralStorage_InvalidTotalDiscount();
    error ReferralStorage_InvalidCode();
    error ReferralStorage_CodeAlreadyExists();
    error ReferralStorage_InsufficientBalance();
    error ReferralStorage_Forbidden();
    error ReferralStorage_InvalidMarket();

    // Public State Variables
    function PRECISION() external view returns (uint256);
    function longToken() external view returns (address);
    function shortToken() external view returns (address);
    function referrerTiers(address) external view returns (uint256);
    function tiers(uint256) external view returns (uint256);
    function isHandler(address) external view returns (bool);
    function codeOwners(bytes32) external view returns (address);
    function traderReferralCodes(address) external view returns (bytes32);
    function affiliateRewards(address, bool) external view returns (uint256);

    // Functions
    function setHandler(address _handler, bool _isActive) external;
    function setTier(uint256 _tierId, uint256 _totalDiscount) external;
    function setReferrerTier(address _referrer, uint256 _tierId) external;
    function setTraderReferralCode(address _account, bytes32 _code) external;
    function setTraderReferralCodeByUser(bytes32 _code) external;
    function registerCode(bytes32 _code) external;
    function accumulateAffiliateRewards(MarketId _id, address _account, bool _isLongToken, uint256 _amount) external;
    function claimAffiliateRewards() external;
    function setCodeOwner(bytes32 _code, address _newAccount) external;
    function govSetCodeOwner(bytes32 _code, address _newAccount) external;
    function getTraderReferralInfo(address _account) external view returns (bytes32, address);
    function getDiscountForUser(address _account) external view returns (uint256);
    function getAffiliateFromUser(address _account) external view returns (address codeOwner);
    function getClaimableAffiliateRewards(address _account, bool _isLong)
        external
        view
        returns (uint256 claimableAmount);
}
