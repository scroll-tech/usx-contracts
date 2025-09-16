// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IUSX
/// @notice Interface for the USX token contract
interface IUSX {
    // Core ERC20 functions
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);

    // Treasury functions
    function mintUSX(address to, uint256 amount) external;
    function burnUSX(address from, uint256 amount) external;
    function freeze() external;
    function unfreeze() external;

    // State getters
    function frozen() external view returns (bool);
    function governanceWarchest() external view returns (address);

    function totalOutstandingWithdrawalAmount() external view returns (uint256);
    function totalMatchedWithdrawalAmount() external view returns (uint256);
}
