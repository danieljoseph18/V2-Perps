// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Market, IMarket} from "../markets/Market.sol";
import {Vault, IVault} from "../markets/Vault.sol";
import {TradeStorage} from "../positions/TradeStorage.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";

/// @dev - External library to deploy contracts
library DeployTradeStorage {
    function run(IMarket market, IVault vault, IReferralStorage referralStorage, IPriceFeed priceFeed)
        external
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(market, vault));
        return address(new TradeStorage{salt: salt}(market, vault, referralStorage, priceFeed));
    }
}
