// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUSX} from "./interfaces/IUSX.sol";
import {IsUSX} from "./interfaces/IsUSX.sol";

contract TreasuryStorage {
    
    /*=========================== Errors =========================*/
    
    // Core Diamond errors
    error FacetAlreadyExists();
    error FacetNotFound();
    error SelectorNotFound();
    error InvalidFacet();

    // Core contract errors
    error ZeroAddress();
    
    // Asset Manager errors
    error InvalidMaxLeverage();
    error MaxLeverageExceeded();
    
    // Insurance Buffer errors
    error InvalidBufferRenewalRate();
    error InvalidBufferTargetFraction();
    
    // Profit/Loss Reporter errors
    error ZeroValueChange();
    error InvalidSuccessFeeFraction();
    error ProfitsDetectedUseReportProfitsFunction();
    error LossesDetectedUseReportLossesFunction();
    
    // Access control errors
    error NotGovernance();
    error NotAssetManager();
    
    /*=========================== Events =========================*/
    
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);

    /*=========================== Modifiers =========================*/
    
    // Modifier to restrict access to governance functions
    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }
    
    // Modifier to restrict access to asset manager functions
    modifier onlyAssetManager() {
        if (msg.sender != assetManager) revert NotAssetManager();
        _;
    }

    /*=========================== State Variables =========================*/
    
    IUSX public USX;                           // USX token contract
    IsUSX public sUSX;                         // sUSX vault contract
    IERC20 public USDC;                        // USDC token contract
    address public governance;                  // Governance address
    address public assetManager;                // The current Asset Manager for the protocol
    address public governanceWarchest;          // Governance warchest address
    uint256 public successFeeFraction;          // Success fee fraction (default 5% == 50000)
    uint256 public maxLeverage;                 // Max leverage (default 10% == 100000)
    uint256 public bufferRenewalFraction;       // Buffer renewal fraction (default 10% == 100000)
    uint256 public bufferTargetFraction;        // Buffer target fraction (default 5% == 50000)    
    uint256 public assetManagerUSDC;            // USDC allocated to Asset Manager
    // (TODO: Remember to consider USDC has 6 decimals)
    // TODO: assetManagerUSDC may need to be updated at each asset manager report
    uint256 public netEpochProfits;     // profits reported for previous epoch, after deducting Insurance Buffer and Governance Warchest fees
}
