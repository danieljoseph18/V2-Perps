// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPriceOracle} from "../../src/oracle/interfaces/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 public constant PRICE_DECIMALS = 18;

    mapping(address => bool) public whitelistedTokens;
    mapping(address => uint256) public pricePrecisions;
    // token => block => price
    mapping(address => mapping(uint256 => uint256)) signedPrices;
    mapping(address => uint256) public cachedPrices;

    function getPrice(address _token) external pure returns (uint256) {
        _token;
        return 1000e18;
    }

    function whitelistToken(address _token) external {
        whitelistedTokens[_token] = true;
    }

    function updatePriceSource(address _token, address _newPriceSource) external pure {
        _token;
        _newPriceSource;
    }

    function getSignedPrice(address _token, uint256 _block) external view returns (uint256) {
        signedPrices[_token][_block];
        return 1000e18;
    }

    function setSignedPrice(address _token, uint256 _block, uint256 _price) external {
        signedPrices[_token][_block] = _price;
    }

    function requestSignedPrice(address _indexToken, uint256 _block) external {
        // only callable by permissioned roles
        // request price for all whitelisted tokens at block
    }

    function getCollateralPrice() external pure returns (uint256) {
        return 1e18;
    }

    function getInstantMarketTokenPrices() external view returns (uint256 longTokenPrice, uint256 shortTokenPrice) {}
}
