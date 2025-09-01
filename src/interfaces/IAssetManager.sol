// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAssetManager
/// @notice Standardized interface for the Asset Manager contract
interface IAssetManager {
    function deposit(uint256 _usdcAmount) external;
    function withdraw(uint256 _usdcAmount) external;
}