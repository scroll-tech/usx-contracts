// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IsUSX {
    // Core ERC20 functions
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    
    // Vault functions
    function distributeProfits(uint256 amountProfit) external;
    function sharePrice() external view returns (uint256);
    
    // State getters
    function USX() external view returns (address);
    function treasury() external view returns (address);
}