// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IUSX
/// @notice Interface for the USX token contract
interface IUSX is IERC20 {
    // Treasury functions
    function mintUSX(address to, uint256 amount) external;
    function burnUSX(address from, uint256 amount) external;
    function pause() external;
    function unpause() external;

    // State getters
    function paused() external view returns (bool);
    function governance() external view returns (address);

    function totalOutstandingWithdrawalAmount() external view returns (uint256);
    function totalMatchedWithdrawalAmount() external view returns (uint256);
}
