// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IMarket} from "./interfaces/IMarket.sol";
import {IMarketStorage} from "./interfaces/IMarketStorage.sol";

contract GlobalMarketConfig {

    address public marketStorage;

    constructor(address _marketStorage) {
        marketStorage = _marketStorage;
    }
   

    function setMarketFundingConfig(bytes32 _marketKey, uint256 _fundingInterval, uint256 _maxFundingVelocity, uint256 _skewScale, uint256 _maxFundingRate) external {
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(market).setFundingConfig(_fundingInterval, _maxFundingVelocity, _skewScale, _maxFundingRate);
    }

    function setMarketBorrowingConfig(bytes32 _marketKey, uint256 _borrowingFactor, uint256 _borrowingExponent, bool _feeForSmallerSide) external {
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(market).setBorrowingConfig(_borrowingFactor, _borrowingExponent, _feeForSmallerSide);
    }

    function getMarketKey(address _indexToken, address _stablecoin) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_indexToken, _stablecoin));
    }

    function setStableCoin(address _stablecoin) external {
        IMarketStorage(marketStorage).setIsStable(_stablecoin);
    }

    function setMarketPriceImpactConfig(bytes32 _marketKey, uint256 _priceImpactFactor, uint256 _priceImpactExponent) external {
        address market = IMarketStorage(marketStorage).getMarket(_marketKey).market;
        IMarket(market).setPriceImpactConfig(_priceImpactFactor, _priceImpactExponent);
    }

}