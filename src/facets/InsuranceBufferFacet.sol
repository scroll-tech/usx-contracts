// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {IUSX} from "../interfaces/IUSX.sol";
import {AssetManagerAllocatorFacet} from "./AssetManagerAllocatorFacet.sol";

contract InsuranceBufferFacet is TreasuryStorage {
    
    /*=========================== Public Functions =========================*/
    
    // returns current buffer target based on bufferTargetFraction and USX total supply
    function bufferTarget() public view returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        return $.USX.totalSupply() * $.bufferTargetFraction / 100000;
    }

    /*=========================== Governance Functions =========================*/
    
    // sets renewal fraction with precision to 0.001 percent (Minimal value & default is 10% fee == 100000)
    function setBufferRenewalRate(uint256 _bufferRenewalRate) external onlyGovernance {
        if (_bufferRenewalRate < 100000) revert InvalidBufferRenewalRate();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        $.bufferRenewalFraction = _bufferRenewalRate;
    }

    // sets buffer target with precision to 0.001 percent (Minimum value & default is 5% == 50000)
    function setBufferTargetFraction(uint256 _bufferTargetFraction) external onlyGovernance {
        if (_bufferTargetFraction < 50000) revert InvalidBufferTargetFraction();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        $.bufferTargetFraction = _bufferTargetFraction;
    }

    /*=========================== Treasury Functions =========================*/

    // tops up insurance buffer
    /// @param _totalProfit - total profit from the latest epoch in USDC
    // it is triggered within every reportProfitAndLoss() call reports positive rewards while insurance buffer is less then bufferTarget(). Tries to replenish buffer up to amount from first netDeposits from the latest epoch, then netEpochProfits
    function topUpBuffer(uint256 _totalProfit) public onlyTreasury returns (uint256 insuranceBufferAccrual) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        
        // Check if the buffer is less than the buffer target
        if ($.USX.balanceOf(address(this)) < bufferTarget()) {
            // Calculate the amount of USX to mint to the buffer based on profits only
            uint256 totalProfitUSDC = _totalProfit;
            
            // Only use a portion of the profits for insurance buffer (not the entire system's USDC)
            uint256 insuranceBufferAccrualUSDC = totalProfitUSDC * $.bufferRenewalFraction / 1000000;

            // Mint USX to the buffer
            $.USX.mintUSX(address(this), insuranceBufferAccrualUSDC * DECIMAL_SCALE_FACTOR);
            
            insuranceBufferAccrual = insuranceBufferAccrualUSDC;
        } else {
            insuranceBufferAccrual = 0;
        }
    }

    // deplete insurance buffer
    // it is triggered within every reportProfitAndLoss() call reports a loss. Tries to drain buffer up to amount. If amount <= bufferSize, then it drains the buffer, if amount > bufferSize than the USX:USDC peg is broken to reflect the loss.
    function slashBuffer(uint256 _amount) public onlyTreasury returns (uint256 remainingLosses) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 bufferSize = $.USX.balanceOf(address(this));
        // Convert USDC amount to USX: _amount (6 decimals) * DECIMAL_SCALE_FACTOR (10^12) = USX (18 decimals)
        uint256 amountUSX = _amount * DECIMAL_SCALE_FACTOR;
        
        // Insurance Buffer can absorb the loss
        if (amountUSX <= bufferSize) {
            $.USX.burnUSX(address(this), amountUSX);
            remainingLosses = 0;
        // Insurance Buffer is not sufficient to absorb the loss
        } else {
            // If the amount is greater than the buffer size, burn the buffer and return the remaining losses
            $.USX.burnUSX(address(this), bufferSize);
            // Convert remaining USX back to USDC: remaining USX / DECIMAL_SCALE_FACTOR
            remainingLosses = (amountUSX - bufferSize) / DECIMAL_SCALE_FACTOR;
        }
    }
}
