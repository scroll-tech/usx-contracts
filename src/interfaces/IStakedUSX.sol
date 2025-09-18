// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITreasury} from "./ITreasury.sol";

/// @title IStakedUSX
/// @notice Interface for the sUSX contract
interface IStakedUSX is IERC20 {
    // Vault functionsw
    function sharePrice() external view returns (uint256);

    // State getters
    function USX() external view returns (IERC20);
    function treasury() external view returns (ITreasury);
    function epochDuration() external view returns (uint256);

    // Rewards management
    function notifyRewards(uint256 amount) external;

    // Deposit freezing functions
    function pauseDeposit() external;
    function unpauseDeposit() external;
    function depositPaused() external view returns (bool);
}
