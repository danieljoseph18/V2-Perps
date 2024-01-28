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

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoleValidation} from "../access/RoleValidation.sol";
import {ILiquidityVault} from "../liquidity/interfaces/ILiquidityVault.sol";
import {TradeHelper} from "./TradeHelper.sol";

/// @dev Needs Vault Role
contract TradeVault is RoleValidation {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    ILiquidityVault public liquidityVault;

    mapping(bytes32 _marketKey => uint256 _collateral) public longCollateral;
    mapping(bytes32 _marketKey => uint256 _collateral) public shortCollateral;

    event TransferOutTokens(bytes32 indexed _marketKey, address indexed _to, uint256 _collateralDelta, bool _isLong);
    event LossesTransferred(uint256 indexed _amount);
    event UpdateCollateralBalance(bytes32 indexed _marketKey, uint256 _amount, bool _isLong, bool _isIncrease);
    event ExecutionFeeSent(address indexed _executor, uint256 indexed _fee);
    event PositionCollateralLiquidated(
        address indexed _liquidator,
        uint256 indexed _liqFee,
        bytes32 indexed _marketKey,
        uint256 _totalCollateral,
        uint256 _collateralFundingOwed,
        bool _isLong
    );

    constructor(address _usdc, address _liquidityVault, address _roleStorage) RoleValidation(_roleStorage) {
        USDC = IERC20(_usdc);
        liquidityVault = ILiquidityVault(_liquidityVault);
    }

    receive() external payable {}

    function transferOutTokens(bytes32 _marketKey, address _to, uint256 _collateralDelta, bool _isLong)
        external
        onlyTradeStorage
    {
        require(longCollateral[_marketKey] != 0 || shortCollateral[_marketKey] != 0, "TV: Incorrect Market Key");
        require(_to != address(0), "TV: Zero Address");
        require(_collateralDelta != 0, "TV: Zero Amount");
        if (_isLong) {
            require(longCollateral[_marketKey] >= _collateralDelta, "TV: Insufficient Collateral");
        } else {
            require(shortCollateral[_marketKey] >= _collateralDelta, "TV: Insufficient Collateral");
        }
        _isLong ? longCollateral[_marketKey] -= _collateralDelta : shortCollateral[_marketKey] -= _collateralDelta;
        USDC.safeTransfer(_to, _collateralDelta);
        emit TransferOutTokens(_marketKey, _to, _collateralDelta, _isLong);
    }

    function transferToLiquidityVault(uint256 _amount) external onlyTradeStorage {
        _sendTokensToLiquidityVault(_amount);
    }

    function updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong, bool _isIncrease)
        external
        onlyRouter
    {
        _updateCollateralBalance(_marketKey, _amount, _isLong, _isIncrease);
    }

    function swapFundingAmount(bytes32 _marketKey, uint256 _amount, bool _isLong) external onlyTradeStorage {
        _swapFundingAmount(_marketKey, _amount, _isLong);
    }

    function liquidatePositionCollateral(
        address _liquidator,
        uint256 _liqFee,
        bytes32 _marketKey,
        uint256 _totalCollateral,
        uint256 _collateralFundingOwed,
        bool _isLong
    ) external onlyTradeStorage {
        // funding
        if (_collateralFundingOwed > 0) {
            _swapFundingAmount(_marketKey, _collateralFundingOwed, _isLong);
        }
        // Funds remaining after paying funding and liquidation fee
        uint256 remainingCollateral = _totalCollateral - _collateralFundingOwed - _liqFee;
        if (remainingCollateral > 0) {
            if (_isLong) {
                longCollateral[_marketKey] -= remainingCollateral;
            } else {
                shortCollateral[_marketKey] -= remainingCollateral;
            }
            _sendTokensToLiquidityVault(remainingCollateral);
        }
        USDC.safeTransfer(_liquidator, _liqFee);
        emit PositionCollateralLiquidated(
            _liquidator, _liqFee, _marketKey, _totalCollateral, _collateralFundingOwed, _isLong
        );
    }

    function claimFundingFees(bytes32 _marketKey, address _user, uint256 _claimed, bool _isLong)
        external
        onlyTradeStorage
    {
        if (_isLong) {
            require(shortCollateral[_marketKey] >= _claimed, "TV: Insufficient Claimable");
        } else {
            require(longCollateral[_marketKey] >= _claimed, "TV: Insufficient Claimable");
        }
        // transfer funding from the counter parties' liquidity pool
        _updateCollateralBalance(_marketKey, _claimed, _isLong, false);
        // transfer funding to the user
        USDC.safeTransfer(_user, _claimed);
    }

    function sendExecutionFee(address payable _executor, uint256 _executionFee) external onlyTradeStorage {
        require(address(this).balance >= _executionFee, "TV: Insufficient Balance");
        (bool success,) = _executor.call{value: _executionFee}("");
        require(success, "TV: Fee Transfer Failed");
        emit ExecutionFeeSent(_executor, _executionFee);
    }

    function _swapFundingAmount(bytes32 _marketKey, uint256 _amount, bool _isLong) internal {
        if (_isLong) {
            longCollateral[_marketKey] -= _amount;
            shortCollateral[_marketKey] += _amount;
        } else {
            shortCollateral[_marketKey] -= _amount;
            longCollateral[_marketKey] += _amount;
        }
    }

    function _updateCollateralBalance(bytes32 _marketKey, uint256 _amount, bool _isLong, bool _isIncrease) internal {
        if (_isLong) {
            _isIncrease ? longCollateral[_marketKey] += _amount : longCollateral[_marketKey] -= _amount;
        } else {
            _isIncrease ? shortCollateral[_marketKey] += _amount : shortCollateral[_marketKey] -= _amount;
        }
        emit UpdateCollateralBalance(_marketKey, _amount, _isLong, _isIncrease);
    }

    function _sendTokensToLiquidityVault(uint256 _amount) internal {
        require(_amount != 0, "TV: Zero Amount");
        liquidityVault.accumulateFees(_amount);
        USDC.safeTransfer(address(liquidityVault), _amount);
        emit LossesTransferred(_amount);
    }
}
