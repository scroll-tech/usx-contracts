// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {IUSX} from "../interfaces/IUSX.sol";
import {AssetManagerAllocatorFacet} from "./AssetManagerAllocatorFacet.sol";

contract InsuranceBufferFacet is TreasuryStorage {
    
    /*=========================== Governance Functions =========================*/
    
    // sets renewal fraction with precision to 0.001 percent (Minimal value & default is 10% fee == 100000)
    function setBufferRenewalRate(uint256 _bufferRenewalRate) external onlyGovernance {
        if (_bufferRenewalRate < 100000) revert InvalidBufferRenewalRate();
        bufferRenewalFraction = _bufferRenewalRate;
    }

    // sets buffer target with precision to 0.001 percent (Minimum value & default is 5% == 50000)
    function setBufferTargetFraction(uint256 _bufferTargetFraction) external onlyGovernance {
        if (_bufferTargetFraction < 50000) revert InvalidBufferTargetFraction();
        bufferTargetFraction = _bufferTargetFraction;
    }
    
    /*=========================== Internal Functions =========================*/
    
    // returns current buffer target based on bufferTargetFraction and USX total supply
    function bufferTarget() public view returns (uint256) {
        return USX.totalSupply() * bufferTargetFraction / 100000;
    }
    
    // tops up insurance buffer
    // it is triggered within every reportProfitAndLoss() call reports positive rewards while insurance buffer is less then bufferTarget(). Tries to replenish buffer up to amount from first netDeposits from the latest epoch, then netEpochProfits
    function _topUpBuffer(uint256 _totalProfit) external returns (uint256 insuranceBufferAccrual) {
        // Check if the buffer is less than the buffer target
        if (USX.balanceOf(address(this)) < bufferTarget()) {
            // Calculate the amount of USX to mint to the buffer
            insuranceBufferAccrual = (_totalProfit * bufferRenewalFraction / 100000) + AssetManagerAllocatorFacet(address(this)).netDeposits();

            // Mint USX to the buffer
            USX.mintUSX(address(this), insuranceBufferAccrual);
        }
    }

    // deplete insurance buffer
    // it is triggered within every reportProfitAndLoss() call reports a loss. Tries to drain buffer up to amount. If amount <= bufferSize, then it drains the buffer, if amount > bufferSize than the USX:USDC peg is broken to reflect the loss.
    function _slashBuffer(uint256 _amount) external returns (uint256 remainingLosses) {

    }
}
