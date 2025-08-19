// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ITreasury {
    // Core functions
    function checkMaxLeverage(uint256 depositAmount) external view returns (bool);
    function governanceWarchest() external view returns (address);
    
    // Asset Manager functions
    function transferUSDCtoAssetManager(uint256 _amount) external;
    function transferUSDCFromAssetManager(uint256 _amount) external;
    function getAssetManager() external view returns (address);
    function getAssetManagerUSDC() external view returns (uint256);
    
    // Insurance Buffer functions
    function bufferTarget() external view returns (uint256);
    function bufferUtilization() external view returns (uint256);
    function isBufferHealthy() external view returns (bool);
    
    // Profit/Loss functions
    function makeAssetManagerReport(int256 grossValueChange) external;
    function successFee(uint256 profitAmount) external view returns (uint256);
}