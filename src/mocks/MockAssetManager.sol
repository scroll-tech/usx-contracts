// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockAssetManager
/// @dev A simple mock asset manager for testing purposes
contract MockAssetManager {
    // Public state variables for tracking
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;
    uint256 public currentBalance;

    // USDC token reference
    IERC20 public immutable USDC;

    // Events for tracking
    event DepositCalled(uint256 amount);
    event WithdrawCalled(uint256 amount);
    event BalanceUpdated(uint256 newBalance);

    /// @param _usdcAddress The USDC token contract address
    constructor(address _usdcAddress) {
        USDC = IERC20(_usdcAddress);
    }

    /// @dev Deposit USDC to the asset manager
    /// @param _usdcAmount Amount of USDC to deposit
    function deposit(uint256 _usdcAmount) external {
        // Allow zero amount deposits (no-op)
        if (_usdcAmount == 0) {
            return;
        }

        // Transfer USDC from caller to this contract
        bool success = USDC.transferFrom(msg.sender, address(this), _usdcAmount);
        require(success, "USDC transfer failed");

        // Update state
        totalDeposits += _usdcAmount;
        currentBalance += _usdcAmount;

        emit DepositCalled(_usdcAmount);
        emit BalanceUpdated(currentBalance);
    }

    /// @dev Withdraw USDC from the asset manager
    /// @param _usdcAmount Amount of USDC to withdraw
    function withdraw(uint256 _usdcAmount) external {
        require(_usdcAmount <= currentBalance, "Insufficient balance");

        // Allow zero amount withdrawals (no-op)
        if (_usdcAmount == 0) {
            return;
        }

        // Transfer USDC from this contract to caller
        bool success = USDC.transfer(msg.sender, _usdcAmount);
        require(success, "USDC transfer failed");

        // Update state
        totalWithdrawals += _usdcAmount;
        currentBalance -= _usdcAmount;

        emit WithdrawCalled(_usdcAmount);
        emit BalanceUpdated(currentBalance);
    }

    /// @dev Get the current USDC balance of this contract
    /// @return Current USDC balance
    function getBalance() external view returns (uint256) {
        return currentBalance;
    }

    /// @dev Get the total amount of USDC deposited
    /// @return Total deposits
    function getTotalDeposits() external view returns (uint256) {
        return totalDeposits;
    }

    /// @dev Get the total amount of USDC withdrawn
    /// @return Total withdrawals
    function getTotalWithdrawals() external view returns (uint256) {
        return totalWithdrawals;
    }
}
