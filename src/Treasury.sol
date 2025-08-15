// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IUSX} from "./IUSX.sol";
import {IsUSX} from "./IsUSX.sol";

// Consolidates all protocol-wide USDC flows, profit/loss accounting, and insurance buffer management within a single orchestrator contract.
// Profit & Loss Reporter: Records epoch-based performance and triggers P&L adjustments.
// Insurance Buffer: Maintains a reserve to cover potential Asset Manager losses.
// Asset Manager Allocator: Routes USDC deposits/withdrawals to the Asset Manager.

// Receives USDC from deposits to the USX contract

// Only this contract can mint/burn USX

// USDC is transferred to/from Asset Manager contract

// Upgradeable smart contract UUPS
// ERC7201

// Diamond Standard implementation? https://eips.ethereum.org/EIPS/eip-2535

contract Treasury {

    /*=========================== Errors =========================*/

    /*=========================== Events =========================*/

    /*=========================== Modifiers =========================*/

    /*=========================== State Variables =========================*/

    /*=========================== Constructor =========================*/

    /*=========================== Public Functions =========================*/

    /*=========================== Governance Functions =========================*/

    /*=========================== Internal Functions =========================*/

}

contract ProfitAndLossReporter {

    /*=========================== Errors =========================*/

    error ZeroValueChange();
    error NotGovernance();
    error NotAssetManager();
    error InvalidSuccessFeeFraction();

    /*=========================== Modifiers =========================*/
    
    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyAssetManager() {
        if (msg.sender != assetManager) revert NotAssetManager();
        _;
    }

    /*=========================== State Variables =========================*/

    IUSX public immutable USX;

    IsUSX public immutable sUSX;

    address public governance;

    address public assetManager;

    address public governanceWarchest;

    uint256 public successFeeFraction;

    /*=========================== Public Functions =========================*/

    // calculates the success fee for the Goverance Warchest based on successFeeFraction
    function successFee(uint256 profitAmount) public view returns (uint256) {
        return profitAmount * successFeeFraction / 100000;
    }

    /*=========================== Governance Functions =========================*/

    // duration of epoch in blocks, (default == 216000 (30days))
    function setEpochDuration(uint256 _epochDurationBlocks) public onlyGovernance {}

    // fraction of success fee determining the success fee, (default 5% == 50000) with precision to 0.001 percent
    function setSuccessFeeFraction(uint256 _successFeeFraction) public onlyGovernance {
        if (_successFeeFraction > 100000) revert InvalidSuccessFeeFraction();
        successFeeFraction = _successFeeFraction;
    }

    /*=========================== Asset Manager Functions =========================*/

    // reports profit or loss for the Asset Manager
    // TODO: Consider just this one function or two seperate functions for reportProfits and reportLosses?
    function makeAssetManagerReport(int256 grossValueChange) public onlyAssetManager {
        if (grossValueChange == 0) revert ZeroValueChange(); // TODO: Should this be allowed? Highly unlikely edge case.
        
        // Profit Reported
        if (grossValueChange > 0) {
            uint256 grossProfit = uint256(grossValueChange);

            // If the usxPrice() < 1 (peg is broken) then update the peg and if there are any remaining profits, distribute them
            uint256 newPeg = _updatePeg();
            if (newPeg >= 1) { // TODO: Consider if should have buffer target (something like >= 0.9995)    
                // Portion of the profits are added to the Insurance Buffer
                uint256 insuranceBufferProfits = _topUpBuffer(grossProfit);

                // Porftion of the profits are added to the Governance Warchest
                uint256 governanceWarchestProfits = successFee(grossProfit);
                USX.mintUSX(governanceWarchest, governanceWarchestProfits);

                // Remaining profits are distributed to sUSX contract (USX stakers)
                uint256 stakerprofits = grossProfit - insuranceBufferProfits - governanceWarchestProfits;
                _distributeProfits(stakerprofits);
            }

        // Loss Reported
        } else {
            uint256 grossLoss = uint256(grossValueChange);

            // 1. Subtract loss from the Insurance Buffer module
            uint256 remainingLossesAfterInsuranceBuffer = _slashInBuffer(grossLoss);

            // 2. Then if losses remain, burn USX held in sUSX contract to cover loss
            if (remainingLossesAfterInsuranceBuffer > 0) {
                uint256 remainingLossesAfterVault = _distributeLosses(remainingLossesAfterInsuranceBuffer);

                // TODO: should peg be updated here? USX has been burned so the ratio should change as well?
            }

            // 3. Finally if neither of these cover the losses, update the peg to adjust the USX:USDC ratio and freeze withdrawal temporarily
            if (remainingLossesAfterVault > 0) {
                _updatePeg();
                USX.freezeWithdrawals();
            }
        }
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

contract InsuranceBuffer {

    /*=========================== Errors =========================*/

    error InvalidBufferRenewalRate();
    error InvalidBufferTargetFraction();

    /*=========================== State Variables =========================*/

    // net deposits for the current epoch
    uint256 public netDeposits;

    // renewal fraction with precision to 0.001 percent (Minimum 10% == 100000)
    uint256 public bufferRenewalFraction;

    // buffer target with precision to 0.001 percent (Minimum 5% == 50000)
    uint256 public bufferTargetFraction;

    /*=========================== Public Functions =========================*/

    // returns current buffer target based on bufferTargetFraction and USX total supply
    function bufferTarget() public view returns (uint256) {
        return USX.totalSupply() * bufferTargetFraction / 100000;
    }

    /*=========================== Governance Functions =========================*/

    // sets renewal fraction with precision to 0.001 percent (Minimal value & default is 10% fee == 100000)
    function setBufferRenewalRate(uint256 _bufferRenewalRate) public onlyGovernance {
        if (_bufferRenewalRate < 100000 || _bufferRenewalRate > 1000000) revert InvalidBufferRenewalRate();
        bufferRenewalFraction = _bufferRenewalRate;
    }

    // sets buffer target with precision to 0.001 percent (Minimal value & default is 5% fee == 50000)
    //TODO: Clarify if default is 5 or 10%?
    function setBufferTargetFraction(uint256 _bufferTargetFraction) public onlyGovernance {
        if (_bufferTargetFraction < 50000 || _bufferTargetFraction > 100000) revert InvalidBufferTargetFraction();
        bufferTargetFraction = _bufferTargetFraction;
    }

    /*=========================== Internal Functions =========================*/

    // tops up insurance buffer
    // it is triggered within every reportProfitAndLoss() call reports positive rewards while insurance buffer is less then bufferTarget(). Tries to replenish buffer up to amount from first netDeposits from the latest epoch, then netEpochProfits
    function topUpBuffer(uint256 _totalProfit) internal returns (uint256 insuranceBufferAccrual) {
        // Check if the buffer is less than the buffer target
        if (USX.balanceOf(address(this)) < bufferTarget()) {
            // Calculate the amount of USX to mint to the buffer
            insuranceBufferAccrual = (_totalProfit * bufferRenewalFraction / 100000) + netDeposits();

            // Mint USX to the buffer
            USX.mintUSX(address(this), insuranceBufferAccrual);
        }
    }

    // deplete insurance buffer
    // it is triggered within every reportProfitAndLoss() call reports a loss. Tries to drain buffer up to amount. If amount <= bufferSize, then it drains the buffer, if amount > bufferSize than the USX:USDC peg is broken to reflect the loss.
    function _slashBuffer(uint256 _amount) internal returns (uint256 remainingLosses) {

    }
}

// receives USDC from USX contract deposits and routes to Asset Managers contract

// facilitates withdrwal requests to Asset Manager, adhering to withdrawal period (15 days)

// withdrawals subject to Asset Manager specific constraints and allocation limits

// standaradized interface for Asset Manager's contract
interface IAssetManager {
    function deposit(uint256 _amount) external;
    function withdraw(uint256 _amount) external;
}

contract AssetManagerAllocator {

    /*=========================== Errors =========================*/

    error ZeroAddress();
    error InvalidMaxLeverage();

    /*=========================== State Variables =========================*/

    // the current Asset Manager for the protocol
    address public assetManager;

    // max leverage of the protocol with precision to 0.001 percent (default == 10%, max == 10% == 100000)
    uint256 public maxLeverage;

    uint256 public assetManagerUSDC; // TODO: Remember to consider USDC has 6 decimals

    /*=========================== Public Functions =========================*/

    // Checks if a deposit on the sUSX contract would exceed the max protocol leverage. Returns true if deposit would be allowed, false if it would exceed the max leverage.
    function checkMaxLeverage(uint256 depositAmount) public view returns (bool) {
        // TODO
    }

    /*=========================== Governance Functions =========================*/

    // sets the current Asset Manager for the protocol
    function setAssetManager(address _assetManager) public onlyGovernance {
        if (_assetManager == address(0)) revert ZeroAddress();
    }

    // sets the max leverage for the protocol
    function setMaxLeverage(uint256 _maxLeverage) public onlyGovernance {
        if (_maxLeverage > 100000) revert InvalidMaxLeverage();
        maxLeverage = _maxLeverage;
    }

    /*=========================== Asset Manager Functions =========================*/

    function transferUSDCtoAssetManager(uint256 _amount) public onlyAssetManager {
        assetManagerUSDC += _amount;
        USDC.transferFrom(address(this), address(assetManager), _amount);
    }

    function transferUSDCFromAssetManager(uint256 _amount) public onlyAssetManager {
        assetManagerUSDC -= _amount;
        USDC.transferFrom(address(assetManager), address(this), _amount);
    }

    /*=========================== Internal Functions =========================*/
}