// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {IPriceFeed} from "../../src/oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../../src/oracle/Oracle.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

abstract contract MockPriceFeed is MockPyth, IPriceFeed {
    // Mock storage to simulate asset support and price data
    mapping(address => bytes32) public assetPriceIds;
    mapping(address => PythStructs.Price) public signedPrices;

    constructor(uint256 _validTimePeriod, uint256 _singleUpdateFeeInWei)
        MockPyth(_validTimePeriod, _singleUpdateFeeInWei)
    {}

    // function supportAsset(
    //     address _token,
    //     bytes32 _priceId,
    //     uint256, /* _baseUnit */
    //     Oracle.PriceProvider /* _provider */
    // ) external {
    //     // Simply store the price ID for the token
    //     assetPriceIds[_token] = _priceId;
    // }

    // function unsupportAsset(address _token) external {
    //     // Remove the price ID for the token
    //     delete assetPriceIds[_token];
    // }

    // function signPriceData(address _token, bytes[] calldata _priceUpdateData) external payable {
    //     // Mock implementation: Decode the first price data and emit an event
    //     if (_priceUpdateData.length > 0) {
    //         PythStructs.Price memory priceData = abi.decode(_priceUpdateData[0], (PythStructs.Price));
    //         signedPrices[_token] = priceData;
    //         emit PriceDataSigned(_token, block.number, priceData);
    //     }
    // }

    // function getPriceData(uint256, /* _block */ address _token) external view returns (PythStructs.Price memory) {
    //     // Return the signed price for the token
    //     return signedPrices[_token];
    // }

    // // Implement other interface methods as needed...

    // // Mock implementations for remaining IPriceFeed interface methods
    // function getAsset(address token) external view returns (Oracle.Asset memory) {}

    // function lastUpdateBlock() external view returns (uint256) {
    //     // Return the current block number as the last update block
    //     return block.number;
    // }

    // function longToken() external view returns (address) {
    //     // Mock token address
    //     return address(this);
    // }

    // function shortToken() external view returns (address) {
    //     // Mock token address
    //     return address(this);
    // }

    // function secondaryPriceFee() external pure returns (uint256) {
    //     // Mock fee
    //     return 0;
    // }
}
