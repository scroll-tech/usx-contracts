// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {InsuranceBufferFacet} from "./InsuranceBufferFacet.sol";
import {AssetManagerAllocatorFacet} from "./AssetManagerAllocatorFacet.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    /// @notice Calculates the cumulative profits for previous epoch that needs to be still distributed
    /// @dev Determines what is the USX balance removed in calculating sharePrice() calculated as profitPerBlock(current_block - lastEpochBlock)
    /// @return profitToSubtract The cumulative profits for previous epoch that needs to be still distributed in USDC
    function substractProfitLatestEpoch() public view returns (uint256 profitToSubtract) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        uint256 finalBlock = $.sUSX.lastEpochBlock() + $.sUSX.epochDuration();
        uint256 currentBlock = block.number;
        if (currentBlock >= finalBlock || $.netEpochProfits == 0) {
            return 0;
        }
        uint256 blocks = finalBlock - currentBlock; // should substract all profits at the beginning of a new epoch
        profitToSubtract = profitPerBlock() * blocks; // all regular math checks required
    }

    /*=========================== Asset Manager Functions =========================*/

    /// @notice Asset Manager reports total balance of USDC they hold, profits or losses calculated from this value
    /// @param totalBalance The total balance of USDC held by the Asset Manager
    function assetManagerReport(uint256 totalBalance) public onlyAssetManager nonReentrant {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        // Check if the peg is broken
        bool pegBroken = $.USX.usxPrice() < 1e18;

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

            // If peg is broken, recover it and distribute the remaining profits
            if (pegBroken) {
                // Calculate the profits available after peg recovery
                uint256 scaledNetDeposits = currentNetDeposits * DECIMAL_SCALE_FACTOR;
                uint256 totalSupply = $.USX.totalSupply();

                // Safe subtraction: only distribute if we have sufficient backing
                if (scaledNetDeposits > totalSupply) {
                    _distributeProfits(scaledNetDeposits - totalSupply);
                }

                // Update peg to account for peg recovery (and after minting of new USX if profits beyond peg recovery)
                _updatePeg();
            } else {
                // Distribute profits to the stakers, with a portion going to the Insurance Buffer and Governance Warchest
                _distributeProfits(grossProfit);
            }
        } else {
            // Handle losses
            uint256 grossLoss = previousNetDeposits - currentNetDeposits;
            emit ReportSubmitted(totalBalance, grossLoss, false);

            // 1. Subtract loss from the Insurance Buffer module
            uint256 remainingLossesAfterInsuranceBuffer = InsuranceBufferFacet(address(this)).slashBuffer(grossLoss);

            // 2. Then if losses remain, burn USX held in sUSX contract to cover loss
            if (remainingLossesAfterInsuranceBuffer > 0) {
                uint256 remainingLossesAfterVault = _distributeLosses(remainingLossesAfterInsuranceBuffer);

                // Freeze sUSX vault deposits when vault USX is burned
                $.sUSX.freezeDeposits();

                // 3. Finally if neither of these cover the losses, update the peg to adjust the USX:USDC ratio and freeze both deposits and withdrawals
                if (remainingLossesAfterVault > 0) {
                    _updatePeg();
                    $.USX.freeze();
                    emit ProtocolFrozen("Losses exceed buffer and vault capacity");
                }
            }
        }

        // Next epoch is started
        $.sUSX.updateLastEpochBlock();
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

    /*=========================== Internal Functions =========================*/

    /// @notice Updates peg, by taking all outstanding USDC in the system (treasury & asset manager holdings) and dividing them by total supply of USX
    /// @dev USDC has 6 decimals, USX has 18 decimals, so we need to scale USDC up by 10^12
    function _updatePeg() internal {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 totalUSDCoutstanding = AssetManagerAllocatorFacet(address(this)).netDeposits();
        uint256 scaledUSDC = totalUSDCoutstanding * DECIMAL_SCALE_FACTOR;
        uint256 updatedPeg = scaledUSDC / $.USX.totalSupply();
        uint256 oldPeg = $.USX.usxPrice();
        $.USX.updatePeg(updatedPeg);
        emit PegUpdated(oldPeg, updatedPeg);
    }

    /// @notice Distributes profits to the Insurance Buffer and Governance Warchest, and sUSX contract (USX stakers)
    /// @param profits The total amount of profits to distribute in USDC
    function _distributeProfits(uint256 profits) internal {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        // Calculate any undistributed profits from the previous epoch
        uint256 undistributedFromPreviousEpoch = substractProfitLatestEpoch();

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

        // Update netEpochProfits to include both new profits and carryover from previous epoch
        $.netEpochProfits = stakerProfits + undistributedFromPreviousEpoch;

        emit ProfitsDistributed(profits, stakerProfits, insuranceBufferProfits, governanceWarchestProfits);
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

        emit LossesDistributed(losses, 0, lossesUSX / DECIMAL_SCALE_FACTOR, remainingLosses);
    }
}
