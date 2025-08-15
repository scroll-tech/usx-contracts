// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ITreasury {
    function checkMaxLeverage(uint256 depositAmount) external view returns (bool);
    function governanceWarchest() external view returns (address); 
}