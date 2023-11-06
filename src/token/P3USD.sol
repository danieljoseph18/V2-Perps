// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "../oracle/interfaces/IPriceOracle.sol";

/*
    Contract acts as a Wrapper for Stablecoins, to mint P3USD.
    P3USD is the stablecoin the powers the entire protocol.
    Conversion from other stables let's us work with a standard of 18 decimals.
    It also allows us to create a stable-swap, where users can swap into
    and out of stablecoins at desirable prices.
    Stablecoin prices will be taken as x <= 1
    By depositing/wrapping stablecoins, P3USD is minted to the user
    The amount is determined by the price of the asset deposited at the time.
    Price of P3USD can be determined by (aum USD) / (total supply P3USD)
*/
contract P3USD is ERC20("PRINT3R USD", "P3USD") {

    IPriceOracle public priceOracle;

    uint256 public constant ONE_USD = 1e6;

    mapping(bytes32 _tokenKey => address _token) public whitelistedTokens;
    mapping(address => uint256) public tokenBalances;

    constructor(IPriceOracle _priceOracle) {
        priceOracle = _priceOracle;
    }

    // mint amount = amountInTokens * priceOfToken
    // for minting, price should be <= 1
    /// @dev Can charge a deposit fee here instead of in LV
    function deposit(uint256 _amount, address _token) external {
        bytes32 tokenKey = getTokenKey(_token);
        require(whitelistedTokens[tokenKey] != address(0), "P3USD: Token not whitelisted");
        require(_amount > 0, "P3USD: Amount must be greater than 0");
        address _stablecoin = whitelistedTokens[tokenKey];
        IERC20(_stablecoin).transferFrom(msg.sender, address(this), _amount);
        uint256 price = getMinStablePrice(_stablecoin);
        uint256 mintAmount = _amount * price;
        tokenBalances[_token] += _amount;
        _mint(msg.sender, mintAmount);
    }

    /// @dev Should charge a withdrawal fee
    function withdraw(uint256 _p3Amount, address _tokenOut) external {
        bytes32 tokenKey = getTokenKey(_tokenOut);
        require(whitelistedTokens[tokenKey] != address(0), "P3USD: Token not whitelisted");
        require(_p3Amount > 0, "P3USD: Amount must be greater than 0");
        address _stablecoin = whitelistedTokens[tokenKey];
        uint256 price = getMaxStablePrice(_stablecoin);
        uint256 withdrawAmount = _p3Amount / price; /// @dev Use PRB Math
        _burn(msg.sender, _p3Amount);
        IERC20(_stablecoin).transfer(msg.sender, withdrawAmount);
    }

    function getMinStablePrice(address _stablecoin) public view returns (uint256) {
        uint256 price = priceOracle.getPrice(_stablecoin);
        if (price < ONE_USD) {
            return price;
        } else {
            return ONE_USD;
        }
    }

    function getMaxStablePrice(address _stablecoin) public view returns (uint256) {
        uint256 price = priceOracle.getPrice(_stablecoin);
        if (price > ONE_USD) {
            return price;
        } else {
            return ONE_USD;
        }
    }

    function getTokenKey(address _token) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_token));
    }


}