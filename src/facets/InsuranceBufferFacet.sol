// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title InsuranceBufferFacet
/// @notice Handles the Insurance Buffer logic, managing how it is renewed and depleted
/// @dev Facet for USX Protocol Treasury Diamond contract

contract InsuranceBufferFacet is TreasuryStorage {
    /*=========================== Public Functions =========================*/

    /// @notice Returns current buffer target based on bufferTargetFraction and USX total supply
    /// @return The current buffer target
    function bufferTarget() public view returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        return Math.mulDiv($.USX.totalSupply(), $.bufferTargetFraction, 1000000, Math.Rounding.Floor);
    }

    /*=========================== Governance Functions =========================*/

    /// @notice Sets renewal fraction with precision to 0.001 percent (Minimal value & default is 10% fee == 100000, max value is 100%)
    /// @param _bufferRenewalRate The new renewal fraction
    function setBufferRenewalRate(uint256 _bufferRenewalRate) external onlyGovernance {
        if (_bufferRenewalRate < 100000 || _bufferRenewalRate > 1000000) revert InvalidBufferRenewalRate();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 oldRate = $.bufferRenewalFraction;
        $.bufferRenewalFraction = _bufferRenewalRate;
        emit BufferRenewalRateUpdated(oldRate, _bufferRenewalRate);
    }

    /// @notice Sets buffer target with precision to 0.001 percent (Minimum value & default is 5% == 50000, max value is 100%)
    /// @param _bufferTargetFraction The new buffer target fraction
    function setBufferTargetFraction(uint256 _bufferTargetFraction) external onlyGovernance {
        if (_bufferTargetFraction < 50000 || _bufferTargetFraction > 1000000) revert InvalidBufferTargetFraction();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 oldFraction = $.bufferTargetFraction;
        $.bufferTargetFraction = _bufferTargetFraction;
        emit BufferTargetUpdated(oldFraction, _bufferTargetFraction);
    }

    /*=========================== Treasury Functions =========================*/

    /// @notice Tops up insurance buffer if below the target buffer amount.
    /// @param _totalProfit Total profit from the latest epoch in USDC
    /// @return insuranceBufferAccrual The amount of USX to mint to the buffer
    function topUpBuffer(uint256 _totalProfit) public onlyTreasury returns (uint256 insuranceBufferAccrual) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        // Check if the buffer is less than the buffer target
        if ($.USX.balanceOf(address(this)) < bufferTarget()) {
            // Calculate the amount of USX to mint to the buffer based on profits only
            uint256 totalProfitUSDC = _totalProfit;

            // Only use a portion of the profits for insurance buffer (not the entire system's USDC)
            uint256 insuranceBufferAccrualUSDC =
                Math.mulDiv(totalProfitUSDC, $.bufferRenewalFraction, 1000000, Math.Rounding.Floor);

            // Mint USX to the buffer
            $.USX.mintUSX(address(this), insuranceBufferAccrualUSDC * DECIMAL_SCALE_FACTOR);

            insuranceBufferAccrual = insuranceBufferAccrualUSDC;
            emit BufferReplenished(insuranceBufferAccrualUSDC * DECIMAL_SCALE_FACTOR, $.USX.balanceOf(address(this)));
        } else {
            insuranceBufferAccrual = 0;
        }
    }

    /// @notice Depletes Insurance Buffer to cover losses to the protocol
    /// @param _amount The amount of USX to burn
    /// @return remainingLosses The amount of USDC remaining after the buffer is depleted
    function slashBuffer(uint256 _amount) public onlyTreasury returns (uint256 remainingLosses) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 bufferSize = $.USX.balanceOf(address(this));
        // Convert USDC amount to USX: _amount (6 decimals) * DECIMAL_SCALE_FACTOR (10^12) = USX (18 decimals)
        uint256 amountUSX = _amount * DECIMAL_SCALE_FACTOR;

        // Insurance Buffer can absorb the loss
        if (amountUSX <= bufferSize) {
            $.USX.burnUSX(address(this), amountUSX);
            remainingLosses = 0;
            emit BufferDepleted(amountUSX, 0);
            // Insurance Buffer is not sufficient to absorb the loss
        } else {
            // If the amount is greater than the buffer size, burn the buffer and return the remaining losses
            $.USX.burnUSX(address(this), bufferSize);
            // Convert remaining USX back to USDC: remaining USX / DECIMAL_SCALE_FACTOR
            remainingLosses = (amountUSX - bufferSize) / DECIMAL_SCALE_FACTOR;
            emit BufferDepleted(bufferSize, remainingLosses);
        }
    }
}
