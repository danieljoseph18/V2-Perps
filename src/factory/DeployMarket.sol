// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Pool} from "../markets/Pool.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {Market} from "../markets/Market.sol";

/// @dev - External library to deploy contracts
library DeployMarket {
    function run(
        Pool.Config calldata _config,
        IMarketFactory.Request calldata _params,
        address _vault,
        address _weth,
        address _usdc
    ) external returns (address) {
        bytes32 salt =
            keccak256(abi.encodePacked(_params.input.indexTokenTicker, _params.requester, _params.input.isMultiAsset));
        return address(
            new Market{salt: salt}(
                _config,
                _params.requester,
                _weth,
                _usdc,
                _vault,
                _params.input.indexTokenTicker,
                _params.input.isMultiAsset
            )
        );
    }
}
