// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

interface IPriceOracle {
    function whitelistToken(address _token) external;
    function getPrice(address _token) external view returns (uint256);
    function getSignedPrice(address _token, uint256 _block) external view returns (uint256);
    function setSignedPrice(address _token, uint256 _block, uint256 _price) external;
    function getCollateralPrice() external pure returns (uint256);
}
