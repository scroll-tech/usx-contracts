// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Standaradized interface for Asset Manager's contract
interface IAssetManager {
    function deposit(uint256 _usdcAmount) external;
    function withdraw(uint256 _usdcAmount) external;
}

/// @title AssetManagerAllocatorFacet
/// @notice Handles the allocation of USDC between the treasury and the Asset Manager
/// @dev Facet for TreasuryDiamond contract

contract AssetManagerAllocatorFacet is TreasuryStorage, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /*=========================== Public Functions =========================*/

    /// @notice Returns the maximum USDC allocation allowed based on current leverage settings
    /// @return The maximum USDC allocation allowed
    function maxLeverage() public view returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 vaultValue = $.USX.balanceOf(address($.sUSX));

        // maxLeverageFraction is in basis points (e.g., 100000 = 10%)
        // So maxAllocation = maxLeverageFraction * vaultValue / 1000000
        return Math.mulDiv($.maxLeverageFraction, vaultValue, 1000000, Math.Rounding.Floor);
    }

    /// @notice Checks if a deposit on the sUSX contract would exceed the max protocol leverage.
    ///          e.g. maxLeverage of 10 means treasury will allocate to Asset Manager no more USDC than x10 USX held by vault
    /// @param depositAmount The amount of USDC to deposit
    /// @return true if deposit would be allowed, false if it would exceed the max leverage.
    function checkMaxLeverage(uint256 depositAmount) public view returns (bool) {
        uint256 maxAllocation = maxLeverage();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 currentAllocationOfAssetManager = $.assetManagerUSDC;
        if (currentAllocationOfAssetManager + depositAmount > maxAllocation) {
            return false;
        }
        return true;
    }

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
            IAssetManager(oldAssetManager).withdraw($.assetManagerUSDC);

            // deposit all USDC to new asset manager
            $.USDC.forceApprove(_assetManager, $.assetManagerUSDC);
            IAssetManager(_assetManager).deposit($.assetManagerUSDC);
        }
        $.assetManager = _assetManager;
        emit AssetManagerUpdated(oldAssetManager, _assetManager);
    }

    /// @notice Sets the max leverage fraction for the protocol
    /// @dev Maximum value allowed is 10% == 100000
    /// @param _maxLeverageFraction The new max leverage fraction
    function setMaxLeverageFraction(uint256 _maxLeverageFraction) external onlyGovernance {
        if (_maxLeverageFraction > 100000) revert InvalidMaxLeverageFraction();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 oldFraction = $.maxLeverageFraction;
        $.maxLeverageFraction = _maxLeverageFraction;
        emit MaxLeverageUpdated(oldFraction, _maxLeverageFraction);
    }

    /*=========================== Asset Manager Functions =========================*/

    /// @notice Transfers USDC from the treasury to the Asset Manager
    /// @param _amount The amount of USDC to transfer
    function transferUSDCtoAssetManager(uint256 _amount) external onlyAssetManager nonReentrant {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        // Check if the transfer would exceed the max leverage
        if (!checkMaxLeverage(_amount)) revert MaxLeverageExceeded();

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
        IAssetManager($.assetManager).withdraw(_amount);
        emit USDCDeallocated(_amount, $.assetManagerUSDC);
    }
}
