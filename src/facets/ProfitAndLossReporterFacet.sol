// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {InsuranceBufferFacet} from "./InsuranceBufferFacet.sol";
import {AssetManagerAllocatorFacet} from "./AssetManagerAllocatorFacet.sol";

/// @title ProfitAndLossReporterFacet
/// @notice Handles the reporting of profits and losses to the protocol by the Asset Manager
/// @dev Facet for USX Protocol Treasury Diamond contract

contract ProfitAndLossReporterFacet is TreasuryStorage {
    /*=========================== Public Functions =========================*/

    /// @notice Calculates the success fee for the Goverance Warchest based on successFeeFraction
    /// @param profitAmount The amount of profits to calculate the success fee for
    /// @return The success fee for the Goverance Warchest
    function successFee(uint256 profitAmount) public view returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        return profitAmount * $.successFeeFraction / 100000;
    }

    /// @notice Calculates cumulative profit for previous epoch
    /// @return profit The cumulative profit for the previous epoch
    function profitLatestEpoch() public view returns (uint256 profit) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 blocks = block.number - $.sUSX.lastEpochBlock();
        return profitPerBlock() * blocks;
    }

    /// @notice Calculates the profit per block for the current epoch, to be added to USX balance over time in sharePrice() function
    /// @return The profit per block for the current epoch
    function profitPerBlock() public view returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 blocksRemainingInEpoch = $.sUSX.lastEpochBlock() + $.sUSX.epochDuration() - block.number;
        return $.netEpochProfits / blocksRemainingInEpoch;
    }

    /*=========================== Asset Manager Functions =========================*/

    /// @notice Asset Manager reports total balance of USDC they hold, profits calculated from this value
    /// @param totalBalance The total balance of USDC held by the Asset Manager
    function reportProfits(uint256 totalBalance) public onlyAssetManager {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        // Next epoch is started
        $.sUSX.updateLastEpochBlock();

        // Check if the peg is broken
        bool pegBroken = $.USX.usxPrice() < 1e18;

        // Get the previous net deposits
        uint256 previousNetDeposits = AssetManagerAllocatorFacet(address(this)).netDeposits();

        // Updates assetManagerUSDC to the new balance, which updates the netDeposits
        $.assetManagerUSDC = totalBalance;
        uint256 currentNetDeposits = AssetManagerAllocatorFacet(address(this)).netDeposits();

        // Gets the total profits since the last report
        if (currentNetDeposits < previousNetDeposits) revert LossesDetectedUseReportLossesFunction();
        uint256 grossProfit = currentNetDeposits - previousNetDeposits;

        // If peg is broken, recover it first
        if (pegBroken) {
            uint256 profitsRemaining = _recoverPeg(grossProfit);
            // Distribute any remaining profits after peg recovery
            if (profitsRemaining > 0) {
                _distributeProfits(profitsRemaining);
            }
            // Update peg after all USX minting is complete
            _updatePeg();
        } else {
            // Distribute profits to the stakers, with a portion going to the Insurance Buffer and Governance Warchest
            _distributeProfits(grossProfit);
        }
    }

    /// @notice Asset Manager reports total balance of USDC they hold, losses calculated from this value
    /// @param totalBalance The total balance of USDC held by the Asset Manager
    function reportLosses(uint256 totalBalance) public onlyAssetManager {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        // Next epoch is started
        $.sUSX.updateLastEpochBlock();

        if (totalBalance > $.assetManagerUSDC) revert ProfitsDetectedUseReportProfitsFunction();
        uint256 grossLoss = $.assetManagerUSDC - totalBalance;

        // Update the assetManagerUSDC to the new balance
        $.assetManagerUSDC = totalBalance;

        // 1. Subtract loss from the Insurance Buffer module
        uint256 remainingLossesAfterInsuranceBuffer = InsuranceBufferFacet(address(this)).slashBuffer(grossLoss);

        // 2. Then if losses remain, burn USX held in sUSX contract to cover loss
        if (remainingLossesAfterInsuranceBuffer > 0) {
            uint256 remainingLossesAfterVault = _distributeLosses(remainingLossesAfterInsuranceBuffer);

            // 3. Finally if neither of these cover the losses, update the peg to adjust the USX:USDC ratio and freeze withdrawal temporarily
            if (remainingLossesAfterVault > 0) {
                _updatePeg();
                $.USX.freezeWithdrawals();
            }
        }
    }

    /*=========================== Governance Functions =========================*/

    /// @notice Sets the success fee fraction determining the success fee, (default 5% == 50000) with precision to 0.001 percent
    /// @param _successFeeFraction The new success fee fraction
    function setSuccessFeeFraction(uint256 _successFeeFraction) external onlyGovernance {
        if (_successFeeFraction > 100000) revert InvalidSuccessFeeFraction();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        $.successFeeFraction = _successFeeFraction;
    }

    /*=========================== Internal Functions =========================*/

    /// @notice Updates peg, by taking all outstanding USDC in the system (treasury & asset manager holdings) and dividing them by total supply of USX.
    /// @return The updated peg
    /// @dev USDC has 6 decimals, USX has 18 decimals, so we need to scale USDC up by 10^12
    function _updatePeg() internal returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 totalUSDCoutstanding = AssetManagerAllocatorFacet(address(this)).netDeposits();
        uint256 scaledUSDC = totalUSDCoutstanding * DECIMAL_SCALE_FACTOR;
        uint256 updatedPeg = scaledUSDC / $.USX.totalSupply();
        $.USX.updatePeg(updatedPeg);
        return updatedPeg;
    }

    /// @notice Distributes profits to the Insurance Buffer and Governance Warchest, and sUSX contract (USX stakers)
    /// @param profits The total amount of profits to distribute in USDC
    function _distributeProfits(uint256 profits) internal {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        // Portion of the profits are added to the Insurance Buffer
        uint256 insuranceBufferProfits = InsuranceBufferFacet(address(this)).topUpBuffer(profits);

        // Portion of the profits are added to the Governance Warchest
        uint256 governanceWarchestProfits = successFee(profits);
        uint256 governanceWarchestUSX = governanceWarchestProfits * DECIMAL_SCALE_FACTOR;
        $.USX.mintUSX($.governanceWarchest, governanceWarchestUSX);

        // Remaining profits are distributed to sUSX contract (USX stakers)
        uint256 stakerProfits = profits - insuranceBufferProfits - governanceWarchestProfits;
        uint256 stakerProfitsUSX = stakerProfits * DECIMAL_SCALE_FACTOR;
        $.USX.mintUSX(address($.sUSX), stakerProfitsUSX);

        // Update netEpochProfits
        $.netEpochProfits = stakerProfits;
    }

    /// @notice Distributes losses to the sUSX contract (USX stakers)
    /// @param losses The total amount of losses to distribute in USDC
    /// @return remainingLosses The amount of USDC remaining after the losses are distributed
    function _distributeLosses(uint256 losses) internal returns (uint256 remainingLosses) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        address vaultAddress = address($.sUSX);
        uint256 vaultUSXBalance = $.USX.balanceOf(vaultAddress);

        // Convert USDC losses to USX: losses (6 decimals) * DECIMAL_SCALE_FACTOR (10^12) = USX (18 decimals)
        uint256 lossesUSX = losses * DECIMAL_SCALE_FACTOR;

        if (vaultUSXBalance > lossesUSX) {
            $.USX.burnUSX(vaultAddress, lossesUSX);
            remainingLosses = 0;
        } else {
            $.USX.burnUSX(vaultAddress, vaultUSXBalance);
            // Convert remaining USX back to USDC: remaining USX / DECIMAL_SCALE_FACTOR
            remainingLosses = (lossesUSX - vaultUSXBalance) / DECIMAL_SCALE_FACTOR;
        }
    }

    /// @notice Recovers the broken peg by minting USX to restore 1:1 backing ratio
    /// @param availableProfits The USDC profits available for peg recovery
    /// @return profitsRemainingAfterPegRecovery The USDC profits remaining after peg recovery
    function _recoverPeg(uint256 availableProfits) internal returns (uint256 profitsRemainingAfterPegRecovery) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        // Calculate how much USX needs to be minted to restore 1:1 peg
        uint256 totalUSDC = AssetManagerAllocatorFacet(address(this)).netDeposits();
        uint256 totalUSX = $.USX.totalSupply();
        uint256 usxNeededForPeg = totalUSX - (totalUSDC * DECIMAL_SCALE_FACTOR / 1e18);

        // Convert profits to USX (profits in USDC, need to scale to USX)
        uint256 profitsInUSX = availableProfits * DECIMAL_SCALE_FACTOR;

        if (profitsInUSX >= usxNeededForPeg) {
            // Full peg recovery possible
            $.USX.mintUSX(address($.sUSX), usxNeededForPeg);
            profitsRemainingAfterPegRecovery = availableProfits - (usxNeededForPeg / DECIMAL_SCALE_FACTOR);
        } else {
            // Partial peg recovery - use all available profits
            $.USX.mintUSX(address($.sUSX), profitsInUSX);
            profitsRemainingAfterPegRecovery = 0;
        }
    }
}
