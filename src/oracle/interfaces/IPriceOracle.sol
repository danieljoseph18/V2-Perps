// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IPriceOracle {
    function setWhitelist(address _token, address _priceFeed) external;
    function updatePriceSource(address _token, address _newPriceSource) external;
    function getPrice(address _token) external view returns (uint256);
    function getSignedPrice(address _token, uint256 _block) external view returns (uint256);
    function setSignedPrice(address _token, uint256 _block, uint256 _price) external;

    // Optional: Consider adding these getters if you want to expose the state variables.
    function whitelistedTokens(address _token) external view returns (bool);
    function signedPrices(address _token, uint256 _block) external view returns (uint256);
    function cachedPrice() external view returns (uint256);
}
