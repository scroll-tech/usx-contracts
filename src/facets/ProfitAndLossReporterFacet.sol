// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {AssetManagerAllocatorFacet} from "./AssetManagerAllocatorFacet.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStakedUSX} from "../interfaces/IStakedUSX.sol";

/// @title ProfitAndLossReporterFacet
/// @notice Handles the reporting of profits and losses to the protocol by the Asset Manager
/// @dev Facet for USX Protocol Treasury Diamond contract

contract ProfitAndLossReporterFacet is TreasuryStorage, ReentrancyGuardUpgradeable {
    /*=========================== Public Functions =========================*/

    /// @notice Calculates the success fee for the Goverance Warchest based on successFeeFraction
    /// @param profitAmount The amount of profits to calculate the success fee for
    /// @return The success fee for the Goverance Warchest
    function successFee(uint256 profitAmount) public view returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        return Math.mulDiv(profitAmount, $.successFeeFraction, 1000000, Math.Rounding.Floor);
    }

    /// @notice Calculates the insurance fund for the Insurance Fund based on insuranceFundFraction
    /// @param profitAmount The amount of profits to calculate the insurance fund for
    /// @return The insurance fund for the Insurance Fund
    function insuranceFund(uint256 profitAmount) public view returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        return Math.mulDiv(profitAmount, $.insuranceFundFraction, 1000000, Math.Rounding.Floor);
    }

    /*=========================== Asset Manager Functions =========================*/

    /// @notice Asset Manager reports total balance of USDC they hold, profits or losses calculated from this value
    /// @param totalBalance The total balance of USDC held by the Asset Manager
    function assetManagerReport(uint256 totalBalance) public onlyAssetManager nonReentrant {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        // Get the previous net deposits
        uint256 previousNetDeposits = AssetManagerAllocatorFacet(address(this)).netDeposits();

        // Updates assetManagerUSDC to the new balance, which updates the netDeposits
        $.assetManagerUSDC = totalBalance;
        uint256 currentNetDeposits = AssetManagerAllocatorFacet(address(this)).netDeposits();

        // Gets the total profits or losses since the last report
        if (currentNetDeposits >= previousNetDeposits) {
            // Handle profits
            uint256 grossProfit = currentNetDeposits - previousNetDeposits;
            emit ReportSubmitted(totalBalance, grossProfit, true);

            // Distribute profits to the stakers, with a portion going to the Insurance Buffer and Governance Warchest
            _distributeProfits(grossProfit);
        } else {
            // we will always cover losses, do nothing here.
            uint256 grossLoss = previousNetDeposits - currentNetDeposits;
            emit ReportSubmitted(totalBalance, grossLoss, false);
        }
    }

    /*=========================== Governance Functions =========================*/

    /// @notice Sets the success fee fraction determining the success fee, (default 5% == 50000) with precision to 0.001 percent
    /// @param _successFeeFraction The new success fee fraction
    function setSuccessFeeFraction(uint256 _successFeeFraction) external onlyGovernance {
        if (_successFeeFraction > 100000) revert InvalidSuccessFeeFraction();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 oldFraction = $.successFeeFraction;
        $.successFeeFraction = _successFeeFraction;
        emit SuccessFeeUpdated(oldFraction, _successFeeFraction);
    }

    /// @notice Sets the insurance fund fraction determining the insurance fund, (default 5% == 50000) with precision to 0.001 percent
    /// @param _insuranceFundFraction The new insurance fund fraction
    function setInsuranceFundFraction(uint256 _insuranceFundFraction) external onlyGovernance {
        if (_insuranceFundFraction > 100000) revert InvalidInsuranceFundFraction();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 oldFraction = $.insuranceFundFraction;
        $.insuranceFundFraction = _insuranceFundFraction;
        emit InsuranceFundFractionUpdated(oldFraction, _insuranceFundFraction);
    }

    /*=========================== Internal Functions =========================*/

    /// @notice Distributes profits to the Insurance Buffer and Governance Warchest, and sUSX contract (USX stakers)
    /// @param profits The total amount of profits to distribute in USDC
    function _distributeProfits(uint256 profits) internal {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        // Portion of the profits are added to the Insurance Buffer
        uint256 insuranceBufferProfits = insuranceFund(profits);
        uint256 insuranceBufferUSX = insuranceBufferProfits * DECIMAL_SCALE_FACTOR;
        $.USX.mintUSX($.insuranceVault, insuranceBufferUSX);

        // Portion of the profits are added to the Governance Warchest
        uint256 governanceWarchestProfits = successFee(profits);
        uint256 governanceWarchestUSX = governanceWarchestProfits * DECIMAL_SCALE_FACTOR;
        $.USX.mintUSX($.governanceWarchest, governanceWarchestUSX);

        // Remaining profits are distributed to sUSX contract (USX stakers)
        uint256 stakerProfits = profits - insuranceBufferProfits - governanceWarchestProfits;
        uint256 stakerProfitsUSX = stakerProfits * DECIMAL_SCALE_FACTOR;
        $.USX.mintUSX(address($.sUSX), stakerProfitsUSX);
        IStakedUSX($.sUSX).notifyRewards(stakerProfitsUSX);

        // Update netEpochProfits to include both new profits and carryover from previous epoch
        $.netEpochProfits = stakerProfits;

        emit ProfitsDistributed(profits, stakerProfits, insuranceBufferProfits, governanceWarchestProfits);
    }
}
