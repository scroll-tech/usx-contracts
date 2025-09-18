// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {AssetManagerAllocatorFacet} from "./AssetManagerAllocatorFacet.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStakedUSX} from "../interfaces/IStakedUSX.sol";

/// @title RewardDistributorFacet
/// @notice Handles the distribution of rewards to the protocol by the Asset Manager
/// @dev Facet for USX Protocol Treasury Diamond contract

contract RewardDistributorFacet is TreasuryStorage, ReentrancyGuardUpgradeable {
    /*=========================== Constants =========================*/

    /// @dev Precision for the fee fractions
    uint256 private constant FEE_PRECISION = 1000000;

    /// @dev Maximum fee fraction
    uint256 private constant MAX_FEE_FRACTION = 100000; // 10%

    /*=========================== Public Functions =========================*/

    /// @notice Calculates the success fee for the Goverance Warchest based on successFeeFraction
    /// @param profitAmount The amount of profits to calculate the success fee for
    /// @return The success fee for the Goverance Warchest
    function successFee(uint256 profitAmount) public view returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        return
            Math.mulDiv(
                profitAmount,
                $.successFeeFraction,
                FEE_PRECISION,
                Math.Rounding.Floor
            );
    }

    /// @notice Calculates the insurance fund for the Insurance Fund based on insuranceFundFraction
    /// @param profitAmount The amount of profits to calculate the insurance fund for
    /// @return The insurance fund for the Insurance Fund
    function insuranceFund(uint256 profitAmount) public view returns (uint256) {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        return
            Math.mulDiv(
                profitAmount,
                $.insuranceFundFraction,
                FEE_PRECISION,
                Math.Rounding.Floor
            );
    }

    /*=========================== Asset Manager Functions =========================*/

    /// @notice Asset Manager reports rewards
    /// @param rewards The rewards to report
    function reportRewards(uint256 rewards) public onlyReporter nonReentrant {
        // Handle rewards
        emit ReportSubmitted(uint256(rewards), true);

        // Distribute rewards to the stakers, with a portion going to the Insurance Buffer and Governance Warchest
        _distributeRewards(rewards);
    }

    /*=========================== Governance Functions =========================*/

    /// @notice Sets the success fee fraction determining the success fee, (default 5% == 50000) with precision to 0.001 percent
    /// @param _successFeeFraction The new success fee fraction
    function setSuccessFeeFraction(
        uint256 _successFeeFraction
    ) external onlyGovernance {
        if (_successFeeFraction > MAX_FEE_FRACTION)
            revert InvalidSuccessFeeFraction();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 oldFraction = $.successFeeFraction;
        $.successFeeFraction = _successFeeFraction;
        emit SuccessFeeUpdated(oldFraction, _successFeeFraction);
    }

    /// @notice Sets the insurance fund fraction determining the insurance fund, (default 5% == 50000) with precision to 0.001 percent
    /// @param _insuranceFundFraction The new insurance fund fraction
    function setInsuranceFundFraction(
        uint256 _insuranceFundFraction
    ) external onlyGovernance {
        if (_insuranceFundFraction > MAX_FEE_FRACTION)
            revert InvalidInsuranceFundFraction();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        uint256 oldFraction = $.insuranceFundFraction;
        $.insuranceFundFraction = _insuranceFundFraction;
        emit InsuranceFundFractionUpdated(oldFraction, _insuranceFundFraction);
    }

    /// @notice Sets the current Reporter for the protocol
    /// @param _reporter The address of the new Reporter
    function setReporter(address _reporter) external onlyGovernance {
        if (_reporter == address(0)) revert ZeroAddress();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        address oldReporter = $.reporter;
        $.reporter = _reporter;
        emit ReporterUpdated(oldReporter, _reporter);
    }

    /*=========================== Internal Functions =========================*/

    /// @notice Distributes rewards to the Insurance Buffer and Governance Warchest, and sUSX contract (USX stakers)
    /// @param rewards The total amount of rewards to distribute in USDC
    function _distributeRewards(uint256 rewards) internal {
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();

        // Portion of the profits are added to the Insurance Buffer
        uint256 insuranceBufferProfits = insuranceFund(rewards);
        uint256 insuranceBufferUSX = insuranceBufferProfits *
            DECIMAL_SCALE_FACTOR;
        $.USX.mintUSX($.insuranceVault, insuranceBufferUSX);

        // Portion of the profits are added to the Governance Warchest
        uint256 governanceWarchestProfits = successFee(rewards);
        uint256 governanceWarchestUSX = governanceWarchestProfits *
            DECIMAL_SCALE_FACTOR;
        $.USX.mintUSX($.governanceWarchest, governanceWarchestUSX);

        // Remaining profits are distributed to sUSX contract (USX stakers)
        uint256 stakerProfits = rewards -
            insuranceBufferProfits -
            governanceWarchestProfits;
        uint256 stakerProfitsUSX = stakerProfits * DECIMAL_SCALE_FACTOR;
        $.USX.mintUSX(address($.sUSX), stakerProfitsUSX);
        IStakedUSX($.sUSX).notifyRewards(stakerProfitsUSX);

        // Update netEpochProfits to include all profits in all epochs
        $.netEpochProfits = $.netEpochProfits + stakerProfits;

        emit RewardsDistributed(
            rewards,
            stakerProfits,
            insuranceBufferProfits,
            governanceWarchestProfits
        );
    }
}
