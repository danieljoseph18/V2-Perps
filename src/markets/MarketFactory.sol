// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Create new Market.sol contracts, with MarketToken.sol's associated
// Store them in MarketStorage.sol with associated information
// Should just be for making Perp markets, spot should work differently
// Also add the option to delete markets if underperforming
import {MarketStorage} from "./MarketStorage.sol";
import {MarketToken} from "./MarketToken.sol";
import {Market} from "./Market.sol";
import {MarketStructs} from "./MarketStructs.sol";

contract MarketFactory {

    mapping(address => bool) public isStable;

    MarketStorage public marketStorage;

    event MarketCreated(address indexed indexToken, address indexed stablecoin, address market, address marketToken);

    constructor(address _marketStorage) {
        marketStorage = MarketStorage(_marketStorage);
    }

    // Only callable by MARKET_MAKER roles
    function createMarket(address _indexToken, address _stablecoin) public {
        // long and short tokens cant be same, short must be stables
        require(isStable[_stablecoin], "Short token must be a stable token");
        require(_stablecoin != address(0), "Zero address not allowed");
        // pool cant already exist
        bytes32 _key = keccak256(abi.encodePacked(_indexToken, _stablecoin));
        require(marketStorage.getMarket(_key).market == address(0), "Market already exists");
        // Create new MarketToken (ERC20 token)
        MarketToken _marketToken = new MarketToken();
        // Create new Market contract
        Market _market = new Market(_indexToken, _stablecoin, address(_marketToken), address(marketStorage));
        // Store everything in MarketStorage
        MarketStructs.Market memory _marketInfo = MarketStructs.Market(_indexToken, _stablecoin, address(_marketToken), address(_market));
        marketStorage.storeMarket(_marketInfo);

        emit MarketCreated(_indexToken, _stablecoin, address(_market), address(_marketToken));
    }

    // Set permissions
    function setIsStable(address _stablecoin) external {
        isStable[_stablecoin] = true;
    }

}