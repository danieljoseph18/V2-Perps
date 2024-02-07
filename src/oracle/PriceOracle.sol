//  ,----,------------------------------,------.
//   | ## |                              |    - |
//   | ## |                              |    - |
//   |    |------------------------------|    - |
//   |    ||............................||      |
//   |    ||,-                        -.||      |
//   |    ||___                      ___||    ##|
//   |    ||---`--------------------'---||      |
//   `--mb'|_|______________________==__|`------'

//    ____  ____  ___ _   _ _____ _____ ____
//   |  _ \|  _ \|_ _| \ | |_   _|___ /|  _ \
//   | |_) | |_) || ||  \| | | |   |_ \| |_) |
//   |  __/|  _ < | || |\  | | |  ___) |  _ <
//   |_|   |_| \_\___|_| \_| |_| |____/|_| \_\

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

// Do we need to allow DEX pricing to price PRINT?
// https://sips.synthetix.io/sips/sip-285/
contract PriceOracle {
    error PriceOracle_InvalidToken();
    error PriceOracle_PriceNotSigned();
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
    // price should have 18 decimals
    function getPrice(address _token) external view returns (uint256) {
        // require token is whitelisted
        // return price of token
    }

    /// @dev Request and fetch structure -> Request requests, executor fetches
    /// @dev When fetching a price which has previously been signed to the block, it
    /// should check if the price has moved by a maximum amount -> prevent price manipulation
    function getSignedPrice(address _token, uint256 _block) external view returns (uint256 price) {
        // require token is whitelisted
        if (!whitelistedTokens[_token]) revert PriceOracle_InvalidToken();
        // return price of token at block
        price = signedPrices[_token][_block];
        if (price == 0) revert PriceOracle_PriceNotSigned();
    }

    function getInstantMarketTokenPrices() external view returns (uint256 longTokenPrice, uint256 shortTokenPrice) {}

    /// @dev Request and fetch structure -> Request requests, executor fetches
    function requestSignedPrice(address _indexToken, uint256 _block) external {
        // only callable by permissioned roles
        // request price for all whitelisted tokens at block
    }

    function setSignedPrice(address _token, uint256 _block, uint256 _price) external {
        // only callable by permissioned roles
        // require token is whitelisted
        // set price of token at block
    }
}
