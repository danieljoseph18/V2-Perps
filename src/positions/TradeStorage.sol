// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

contract TradeStorage {

    // positions need info like market address, entry price, entry time etc.
    // funding should be snapshotted on position open to calc funding fee
    // blocks should be used to settle trades at the price at that block
    // this prevents MEV by capitalizing on large price moves

    // stores all data for open trades and positions
    // needs to store all historic data for leaderboard and trade history
    // store requests for trades and liquidations
    // store open trades and liquidations
    // store closed trades and liquidations
    // all 3 stores separately for separate data extraction

}