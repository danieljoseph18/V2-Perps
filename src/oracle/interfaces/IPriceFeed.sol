// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {Oracle} from "../Oracle.sol";

interface IPriceFeed {
    event PriceDataSigned(address token, uint256 block, PythStructs.Price priceData);

    function supportAsset(address _token, bytes32 _priceId, uint256 _baseUnit, Oracle.PriceProvider _provider)
        external;
    function unsupportAsset(address _token) external;
    function signPriceData(address _token, bytes[] calldata _priceUpdateData) external payable;
    function getPriceData(uint256 _block, address _token) external view returns (PythStructs.Price memory);
    function getSecondaryPrice(address _token, uint256 _block) external view returns (uint256);
    function getAsset(address token) external view returns (Oracle.Asset memory);
    function lastUpdateBlock() external view returns (uint256);
    function longToken() external view returns (address);
    function shortToken() external view returns (address);
    function secondaryPriceFee() external view returns (uint256);
    function getPrimaryUpdateFee(bytes[] calldata _priceUpdateData) external view returns (uint256);
}
