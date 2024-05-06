// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {IReferralStorage} from "./interfaces/IReferralStorage.sol";
import {IMarketFactory} from "../factory/interfaces/IMarketFactory.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {MarketId} from "../types/MarketId.sol";

contract ReferralStorage is OwnableRoles, IReferralStorage, ReentrancyGuard {
    using SafeTransferLib for IERC20;

    IWETH weth;
    IMarketFactory factory;

    uint256 public constant PRECISION = 1e18;
    address public longToken;
    address public shortToken;

    mapping(address user => uint256 tier) public override referrerTiers; // link between user <> tier
    mapping(uint256 tier => uint256 discount) public tiers; // 0.1e18 = 10% discount

    mapping(address => bool) public isHandler;

    mapping(bytes32 => address) public override codeOwners;
    mapping(address => bytes32) public override traderReferralCodes;

    mapping(address => mapping(bool isLongToken => uint256 affiliateRewards)) public affiliateRewards;

    modifier onlyHandler() {
        if (!isHandler[msg.sender]) revert ReferralStorage_Forbidden();
        _;
    }

    constructor(address _weth, address _shortToken, address _marketFactory) {
        _initializeOwner(msg.sender);
        longToken = _weth;
        shortToken = _shortToken;
        weth = IWETH(_weth);
        factory = IMarketFactory(_marketFactory);
    }

    receive() external payable {
        IWETH(weth).deposit{value: msg.value}();
    }

    function setHandler(address _handler, bool _isActive) external onlyOwner {
        isHandler[_handler] = _isActive;
        emit SetHandler(_handler, _isActive);
    }

    function setTier(uint256 _tierId, uint256 _totalDiscount) external override onlyOwner {
        if (_totalDiscount > PRECISION) revert ReferralStorage_InvalidTotalDiscount();
        tiers[_tierId] = _totalDiscount;
        emit SetTier(_tierId, _totalDiscount);
    }

    function setReferrerTier(address _referrer, uint256 _tierId) external override onlyOwner {
        referrerTiers[_referrer] = _tierId;
        emit SetReferrerTier(_referrer, _tierId);
    }

    function setTraderReferralCode(address _account, bytes32 _code) external override onlyHandler {
        _setTraderReferralCode(_account, _code);
    }

    function setTraderReferralCodeByUser(bytes32 _code) external {
        _setTraderReferralCode(msg.sender, _code);
    }

    function registerCode(bytes32 _code) external {
        if (_code == bytes32(0)) revert ReferralStorage_InvalidCode();
        if (codeOwners[_code] != address(0)) revert ReferralStorage_CodeAlreadyExists();

        codeOwners[_code] = msg.sender;
        emit RegisterCode(msg.sender, _code);
    }

    function accumulateAffiliateRewards(MarketId _id, address _account, bool _isLongToken, uint256 _amount)
        external
        onlyRoles(_ROLE_6)
    {
        if (!factory.isMarket(_id)) revert ReferralStorage_InvalidMarket();

        affiliateRewards[_account][_isLongToken] += _amount;

        emit AffiliateRewardsAccumulated(_account, _isLongToken, _amount);
    }

    function claimAffiliateRewards() external nonReentrant {
        uint256 longTokenAmount = affiliateRewards[msg.sender][true];
        uint256 shortTokenAmount = affiliateRewards[msg.sender][false];
        if (longTokenAmount > 0) {
            affiliateRewards[msg.sender][true] = 0;
            IERC20(longToken).safeTransfer(msg.sender, longTokenAmount);
        }
        if (shortTokenAmount > 0) {
            affiliateRewards[msg.sender][false] = 0;
            IERC20(shortToken).safeTransfer(msg.sender, shortTokenAmount);
        }
        emit AffiliateRewardsClaimed(msg.sender, longTokenAmount, shortTokenAmount);
    }

    function setCodeOwner(bytes32 _code, address _newAccount) external {
        if (_code == bytes32(0)) revert ReferralStorage_InvalidCode();

        address account = codeOwners[_code];
        if (msg.sender != account) revert ReferralStorage_Forbidden();

        codeOwners[_code] = _newAccount;
        emit SetCodeOwner(msg.sender, _newAccount, _code);
    }

    function govSetCodeOwner(bytes32 _code, address _newAccount) external override onlyOwner {
        if (_code == bytes32(0)) revert ReferralStorage_InvalidCode();

        codeOwners[_code] = _newAccount;
        emit GovSetCodeOwner(_code, _newAccount);
    }

    function getTraderReferralInfo(address _account) public view override returns (bytes32, address) {
        bytes32 code = traderReferralCodes[_account];
        address referrer;
        if (code != bytes32(0)) {
            referrer = codeOwners[code];
        }
        return (code, referrer);
    }

    /// @return discountPercentage - 0.1e18 = 10% discount
    function getDiscountForUser(address _account) external view returns (uint256) {
        (, address referrer) = getTraderReferralInfo(_account);
        if (referrer == address(0)) {
            return 0;
        } else {
            return tiers[referrerTiers[referrer]];
        }
    }

    function getAffiliateFromUser(address _account) external view returns (address codeOwner) {
        (, address referrer) = getTraderReferralInfo(_account);
        return referrer;
    }

    function getClaimableAffiliateRewards(address _account, bool _isLong)
        external
        view
        returns (uint256 claimableAmount)
    {
        claimableAmount = affiliateRewards[_account][_isLong];
    }

    function _setTraderReferralCode(address _account, bytes32 _code) private {
        traderReferralCodes[_account] = _code;
        emit SetTraderReferralCode(_account, _code);
    }
}
