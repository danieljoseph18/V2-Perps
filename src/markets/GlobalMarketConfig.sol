// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {RoleValidation} from "../access/RoleValidation.sol";

/// @dev GRANT THE CONFIGURATOR ROLE
contract GlobalMarketConfig is RoleValidation {
    IMarketStorage public marketStorage;
    ILiquidityVault public liquidityVault;
    ITradeStorage public tradeStorage;

    constructor(IMarketStorage _marketStorage, ILiquidityVault _liquidityVault, ITradeStorage _tradeStorage)
        RoleValidation(roleStorage)
    {
        marketStorage = _marketStorage;
        liquidityVault = _liquidityVault;
        tradeStorage = _tradeStorage;
    }

    function setMarketFundingConfig(
        bytes32 _marketKey,
        uint256 _fundingInterval,
        uint256 _maxFundingVelocity,
        uint256 _skewScale,
        uint256 _maxFundingRate
    ) external onlyModerator {
        address market = marketStorage.getMarket(_marketKey).market;
        require(market != address(0), "Market does not exist");
        IMarket(market).setFundingConfig(_fundingInterval, _maxFundingVelocity, _skewScale, _maxFundingRate);
    }

    function setMarketBorrowingConfig(
        bytes32 _marketKey,
        uint256 _borrowingFactor,
        uint256 _borrowingExponent,
        bool _feeForSmallerSide
    ) external onlyModerator {
        address market = marketStorage.getMarket(_marketKey).market;
        require(market != address(0), "Market does not exist");
        IMarket(market).setBorrowingConfig(_borrowingFactor, _borrowingExponent, _feeForSmallerSide);
    }

    function getMarketKey(address _indexToken, address _stablecoin) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_indexToken, _stablecoin));
    }

    function setWhitelistedToken(address _token, bool _isWhitelisted) external onlyModerator {
        marketStorage.setIsWhitelisted(_token, _isWhitelisted);
    }

    function setMarketPriceImpactConfig(bytes32 _marketKey, uint256 _priceImpactFactor, uint256 _priceImpactExponent)
        external
        onlyModerator
    {
        address market = marketStorage.getMarket(_marketKey).market;
        require(market != address(0), "Market does not exist");
        IMarket(market).setPriceImpactConfig(_priceImpactFactor, _priceImpactExponent);
    }

    function setLiquidityFee(uint256 _liquidityFee) external onlyModerator {
        liquidityVault.updateLiquidityFee(_liquidityFee);
    }

    function setTradingFees(uint256 _liquidationFee, uint256 _tradingFee) external onlyModerator {
        tradeStorage.setFees(_liquidationFee, _tradingFee);
    }
}
