// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUSX} from "../interfaces/IUSX.sol";
import {IsUSX} from "../interfaces/IsUSX.sol";
import {InsuranceBufferFacet} from "./InsuranceBufferFacet.sol";

contract ProfitAndLossReporterFacet is TreasuryStorage {
    
    /*=========================== Public Functions =========================*/
    
    // calculates the success fee for the Goverance Warchest based on successFeeFraction
    function successFee(uint256 profitAmount) public view returns (uint256) {
        return profitAmount * successFeeFraction / 100000;
    }
    
    /*=========================== Asset Manager Functions =========================*/
    
    // reports profit or loss for the Asset Manager
    // TODO: Consider just this one function or two seperate functions for reportProfits and reportLosses?
    function makeAssetManagerReport(int256 grossValueChange) public {
        if (msg.sender != assetManager) revert NotAssetManager();
        if (grossValueChange == 0) revert ZeroValueChange(); // TODO: Should this be allowed? Highly unlikely edge case.
        
        // Profit Reported
        if (grossValueChange > 0) {
            uint256 grossProfit = uint256(grossValueChange);

            // If the usxPrice() < 1 (peg is broken) then update the peg and if there are any remaining profits, distribute them
            uint256 newPeg = _updatePeg();
            if (newPeg >= 1) { // TODO: Consider if should have buffer target (something like >= 0.9995)    
                // Portion of the profits are added to the Insurance Buffer
                uint256 insuranceBufferProfits = InsuranceBufferFacet(address(this))._topUpBuffer(grossProfit);

                // Porftion of the profits are added to the Governance Warchest
                uint256 governanceWarchestProfits = successFee(grossProfit);
                USX.mintUSX(governanceWarchest, governanceWarchestProfits);

                // Remaining profits are distributed to sUSX contract (USX stakers)
                uint256 stakerprofits = grossProfit - insuranceBufferProfits - governanceWarchestProfits;
                _distributeProfits(stakerprofits);
            }

        // Loss Reported
        } else {
            uint256 grossLoss = uint256(-grossValueChange);

            // 1. Subtract loss from the Insurance Buffer module
            uint256 remainingLossesAfterInsuranceBuffer = InsuranceBufferFacet(address(this))._slashBuffer(grossLoss);

            // 2. Then if losses remain, burn USX held in sUSX contract to cover loss
            if (remainingLossesAfterInsuranceBuffer > 0) {
                uint256 remainingLossesAfterVault = _distributeLosses(remainingLossesAfterInsuranceBuffer);

                // TODO: should peg be updated here? USX has been burned so the ratio should change as well?
                
                // 3. Finally if neither of these cover the losses, update the peg to adjust the USX:USDC ratio and freeze withdrawal temporarily
                if (remainingLossesAfterVault > 0) {
                    _updatePeg();
                    USX.freezeWithdrawals();
                }
            }
        }
    }
    
    /*=========================== Governance Functions =========================*/
    
    // fraction of success fee determining the success fee, (default 5% == 50000) with precision to 0.001 percent
    function setSuccessFeeFraction(uint256 _successFeeFraction) external onlyGovernance {
        if (_successFeeFraction > 100000) revert InvalidSuccessFeeFraction();
        successFeeFraction = _successFeeFraction;
    }
    
    /*=========================== Internal Functions =========================*/
    
    // updates peg, by taking all outstanding USDC in the system (treasury & asset manager holdings) and dividing them by total supply of USX. 
    // USDCoutstanding / USXtotalSupply
    function _updatePeg() internal returns (uint256) {
        uint256 totalUSDCoutstanding = USDC.balanceOf(address(this)) + assetManagerUSDC;
        uint256 updatedPeg = USX.totalSupply() / totalUSDCoutstanding; // TODO: verify the order of vision is correct
        USX.updatePeg(updatedPeg);
        return updatedPeg;
    }

    function _distributeProfits(uint256 profits) internal {
        // Distribute the remaining profits to the sUSX contract
        sUSX.distributeProfits(profits);
    }

    function _distributeLosses(uint256 losses) internal returns (uint256 remainingLosses) {
        address vaultAddress = address(sUSX);
        uint256 vaultUSXBalance = USX.balanceOf(vaultAddress);
        
        // Apply the losses to the sUSX contract (USX burned immediately)
        if (vaultUSXBalance > losses) {
            USX.burnUSX(vaultAddress, losses);
            remainingLosses = 0;
        } else {
            USX.burnUSX(vaultAddress, vaultUSXBalance);
            remainingLosses = losses - vaultUSXBalance;
        }
    }
}
