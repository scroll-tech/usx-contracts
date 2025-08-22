// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {IUSX} from "../interfaces/IUSX.sol";
import {AssetManagerAllocatorFacet} from "./AssetManagerAllocatorFacet.sol";

contract InsuranceBufferFacet is TreasuryStorage {
    
    /*=========================== Modifiers =========================*/
    
    modifier onlyTreasury() {
        require(msg.sender == address(this), "Only Treasury facets can call this function");
        _;
    }
    
    /*=========================== Public Functions =========================*/
    
    // returns current buffer target based on bufferTargetFraction and USX total supply
    function bufferTarget() public view returns (uint256) {
        return USX.totalSupply() * bufferTargetFraction / 100000;
    }

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

    /*=========================== Treasury Functions =========================*/

    // tops up insurance buffer
    // it is triggered within every reportProfitAndLoss() call reports positive rewards while insurance buffer is less then bufferTarget(). Tries to replenish buffer up to amount from first netDeposits from the latest epoch, then netEpochProfits
    function topUpBuffer(uint256 _totalProfit) public onlyTreasury returns (uint256 insuranceBufferAccrual) {
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
    function slashBuffer(uint256 _amount) public onlyTreasury returns (uint256 remainingLosses) {
        uint256 bufferSize = USX.balanceOf(address(this));
        // Insurance Buffer can absorb the loss
        if (_amount <= bufferSize) {
            // Deduct the amount from the buffer
            USX.burnUSX(address(this), _amount);
            remainingLosses = 0;
        // Insurance Buffer is not sufficient to absorb the loss
        } else {
            // If the amount is greater than the buffer size, burn the buffer and return the remaining losses
            USX.burnUSX(address(this), bufferSize);
            remainingLosses = _amount - bufferSize;
        }
    }
}
