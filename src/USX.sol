// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

    // Treasury contract can mint USX

    // Admin role can whitelist users for minting/redeeming USX

    // deposit USDC to get USX

    // Governance (or Asset Manager?) will monitor for unfufilled withdrawal requests and request USDC from Asset Manager as needed

    // Upgradeable smart contract UUPS
    // ERC7201
    // ReentrancyGuard

contract USX is ERC20 {

    /*=========================== State Variables =========================*/

    address public USDC; // IERC20 import instead? immutable?

    uint256 public outstandingWithdrawalAmount;

    address public treasury;

    address public governanceWarchest;

    /*=========================== Public Functions =========================*/

    function deposit() public {}
    // check for qued withdrawals, fulfill withdrawals with new deposits
    // outstanding net deposits are sent to the treasury contract

    function requestUSDC() public {}
    // check if withdrawals are frozen
    // check if there is USDC on the treasury contract that haven't been sent to asset manager. If so user can call claimUSDC immediately.

    function claimUSDC() public {}

    function usxPrice() public view returns (uint256) {}

    /*=========================== Internal Functions =========================*/

}