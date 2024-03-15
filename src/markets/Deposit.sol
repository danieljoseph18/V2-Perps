//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {Fee} from "../libraries/Fee.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IProcessor} from "../router/interfaces/IProcessor.sol";
import {IVault} from "../markets/interfaces/IVault.sol";

library Deposit {
    using SignedMath for int256;
    using SafeCast for uint256;

    uint256 public constant MIN_SLIPPAGE = 0.0001e18; // 0.01%
    uint256 public constant MAX_SLIPPAGE = 0.9999e18; // 99.99%
    uint256 public constant SCALING_FACTOR = 1e18;

    error Deposit_InvalidOwner();
    error Deposit_DepositNotExpired();
    error Deposit_ZeroFee();
    error Deposit_InvalidPrices();

    struct Input {
        address owner;
        address tokenIn;
        uint256 amountIn;
        uint256 executionFee;
        bool reverseWrap;
    }

    struct Data {
        Input input;
        uint256 blockNumber;
        uint48 expirationTimestamp;
        bytes32 key;
    }

    struct ExecuteParams {
        IMarket market;
        IProcessor processor;
        IPriceFeed priceFeed;
        Data data;
        bytes32 key;
        int256 cumulativePnl;
        bool isLongToken;
    }

    function validateCancellation(Data memory _data, address _caller) internal view {
        if (_data.input.owner != _caller) revert Deposit_InvalidOwner();
        if (_data.expirationTimestamp >= block.timestamp) revert Deposit_DepositNotExpired();
    }

    function create(Input memory _input, uint48 _minTimeToExpiration) external view returns (Data memory data) {
        uint256 blockNumber = block.number;
        data = Data({
            input: _input,
            blockNumber: blockNumber,
            expirationTimestamp: uint48(block.timestamp) + _minTimeToExpiration,
            key: _generateKey(_input.owner, _input.tokenIn, _input.amountIn, blockNumber)
        });
    }

    function _generateKey(address owner, address tokenIn, uint256 amountIn, uint256 blockNumber)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tokenIn, amountIn, blockNumber));
    }
}
