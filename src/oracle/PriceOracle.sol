// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// Do we need to allow DEX pricing to price PRINT?
//https://sips.synthetix.io/sips/sip-285/
contract PriceOracle {
    // source of pricing for all tokens
    // need list of whitelisted tokens (long, short and index for all markets)
    // passing the address of a token will fetch price
    // pricing will be determined using Pyth and Chainlink as secondary
    // pricing should be upgradeable so we can improve pricing mechanism in future
    // Need max block the price is valid until
    uint256 public constant PRICE_DECIMALS = 18;

    mapping(address => bool) public whitelistedTokens;
    mapping(address => uint256) public pricePrecisions;
    // token => block => price
    mapping(address => mapping(uint256 => uint256)) signedPrices;
    mapping(address => uint256) public cachedPrices;

    function setWhitelist(address _token, address _priceFeed) external {
        // only callable by permissioned roles
        // add token to whitelist
    }

    function updatePriceSource(address _token, address _newPriceSource) external {
        // only callable by permissioned roles
        // update price source for token
    }

    // Stable price should cap at 1 USD
    // price should have 30
    function getPrice(address _token) external view returns (uint256) {
        // require token is whitelisted
        // return price of token
    }

    function getSignedPrice(address _token, uint256 _block) external view returns (uint256) {
        // require token is whitelisted
        // return price of token at block
    }

    // return price of USDC / WUSD
    function getCollateralPrice() external pure returns (uint256) {
        return 1e18;
    }

    function setSignedPrice(address _token, uint256 _block, uint256 _price) external {
        // only callable by permissioned roles
        // require token is whitelisted
        // set price of token at block
    }
}
