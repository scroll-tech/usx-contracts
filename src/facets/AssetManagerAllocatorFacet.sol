// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAssetManager} from "../interfaces/IAssetManager.sol";

/// @title AssetManagerAllocatorFacet
/// @notice Handles the allocation of USDC between the treasury and the Asset Manager
/// @dev Facet for TreasuryDiamond contract

contract AssetManagerAllocatorFacet is
    TreasuryStorage,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /*=========================== Public Functions =========================*/

    /// @notice Returns the total amount of USDC in the protocol (Asset Manager's USDC holdings + USDC in treasury)
    /// @return The net deposits of the protocol
    function netDeposits() public view returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        return $.USDC.balanceOf(address(this)) + $.assetManagerUSDC;
    }

    /*=========================== Governance Functions =========================*/

    /// @notice Sets the current Asset Manager for the protocol
    /// @param _assetManager The address of the new Asset Manager
    function setAssetManager(address _assetManager) external onlyGovernance {
        if (_assetManager == address(0)) revert ZeroAddress();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        address oldAssetManager = $.assetManager;
        if (oldAssetManager != address(0)) {
            // withdraw all USDC from old asset manager
            uint256 balanceBefore = $.USDC.balanceOf(address(this));
            IAssetManager(oldAssetManager).withdraw($.assetManagerUSDC);
            uint256 balanceAfter = $.USDC.balanceOf(address(this));
            if (balanceAfter < balanceBefore + $.assetManagerUSDC) {
                revert USDCWithdrawalFailed();
            }

            // deposit all USDC to new asset manager
            $.USDC.forceApprove(_assetManager, $.assetManagerUSDC);
            IAssetManager(_assetManager).deposit($.assetManagerUSDC);
        }
        $.assetManager = _assetManager;

        emit AssetManagerUpdated(oldAssetManager, _assetManager);
    }

    /*=========================== Asset Manager Functions =========================*/

    /// @notice Transfers USDC from the treasury to the Asset Manager
    /// @param _amount The amount of USDC to transfer
    function transferUSDCtoAssetManager(uint256 _amount) external onlyAssetManager nonReentrant {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        $.assetManagerUSDC += _amount;
        $.USDC.forceApprove(address($.assetManager), _amount);
        IAssetManager($.assetManager).deposit(_amount);
        emit USDCAllocated(_amount, $.assetManagerUSDC);
    }

    /// @notice Transfers USDC from the Asset Manager to the treasury
    /// @param _amount The amount of USDC to transfer
    function transferUSDCFromAssetManager(uint256 _amount) external onlyAssetManager nonReentrant {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        $.assetManagerUSDC -= _amount;

        // @note assume asset manager will transfer all USDC back to treasury
        uint256 balanceBefore = $.USDC.balanceOf(address(this));
        IAssetManager($.assetManager).withdraw(_amount);
        uint256 balanceAfter = $.USDC.balanceOf(address(this));
        if (balanceAfter < balanceBefore + _amount) {
            revert USDCWithdrawalFailed();
        }

        emit USDCDeallocated(_amount, $.assetManagerUSDC);
    }

    /// @notice Transfers USDC from treasury to USX contract for withdrawal
    function transferUSDCForWithdrawal() external onlyAssetManager nonReentrant {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        uint256 totalOutstandingWithdrawalAmount = $.USX.totalOutstandingWithdrawalAmount();
        uint256 totalMatchedWithdrawalAmount = $.USX.totalMatchedWithdrawalAmount();
        uint256 missingUSDCForWithdrawal = totalOutstandingWithdrawalAmount - totalMatchedWithdrawalAmount;

        if (missingUSDCForWithdrawal > 0) {
            $.USDC.safeTransfer(address($.USX), missingUSDCForWithdrawal);
        }
        emit USDCTransferredForWithdrawal(missingUSDCForWithdrawal);
    }
}
