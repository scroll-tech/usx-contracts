// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// standaradized interface for Asset Manager's contract
interface IAssetManager {
    function deposit(uint256 _usdcAmount) external;
    function withdraw(uint256 _usdcAmount) external;
}