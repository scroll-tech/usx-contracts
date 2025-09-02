// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ITreasury
/// @notice Interface for the USX Protocol Treasury contract
interface ITreasury {
    // Core functions
    function governanceWarchest() external view returns (address);

    // Asset Manager functions
    function maxLeverage() external view returns (uint256);
    function checkMaxLeverage(uint256 depositAmount) external view returns (bool);
    function netDeposits() external view returns (uint256);
    function transferUSDCtoAssetManager(uint256 _amount) external;
    function transferUSDCFromAssetManager(uint256 _amount) external;

    // Insurance Buffer functions
    function bufferTarget() external view returns (uint256);

    // Profit/Loss functions
    function successFee(uint256 profitAmount) external view returns (uint256);
    function profitLatestEpoch() external view returns (uint256);
    function profitPerBlock() external view returns (uint256);
    function reportProfits(uint256 totalBalance) external;
    function reportLosses(uint256 totalBalance) external;
    function setSuccessFeeFraction(uint256 _successFeeFraction) external;
}
