// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUSX} from "./interfaces/IUSX.sol";
import {IStakedUSX} from "./interfaces/IStakedUSX.sol";

/// @title TreasuryStorage
/// @notice Contains state for the USX Protocols Treasury contracts
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
    error USDCWithdrawalFailed();

    // Profit/Loss Reporter errors
    error InvalidSuccessFeeFraction();
    error InvalidInsuranceFundFraction();

    // Access control errors
    error NotGovernance();
    error NotAllocator();
    error NotTreasury();
    error NotReporter();

    /*=========================== Events =========================*/

    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceWarchestTransferred(address indexed oldGovernanceWarchest, address indexed newGovernanceWarchest);
    event InsuranceVaultTransferred(address indexed oldInsuranceVault, address indexed newInsuranceVault);

    // Asset Manager Allocator Facet Events
    event AssetManagerUpdated(address indexed oldAssetManager, address indexed newAssetManager);
    event AllocatorUpdated(address indexed oldAllocator, address indexed newAllocator);
    event USDCAllocated(uint256 amount, uint256 newAllocation);
    event USDCDeallocated(uint256 amount, uint256 newAllocation);
    event USDCTransferredForWithdrawal(uint256 amount);

    // Profit and Loss Reporter Facet Events
    event SuccessFeeUpdated(uint256 oldFraction, uint256 newFraction);
    event InsuranceFundFractionUpdated(uint256 oldFraction, uint256 newFraction);
    event ReporterUpdated(address indexed oldReporter, address indexed newReporter);
    event ReportSubmitted(uint256 profitLoss, bool isProfit);
    event RewardsDistributed(
        uint256 totalProfits, uint256 stakerProfits, uint256 bufferProfits, uint256 governanceProfits
    );
    event ProtocolFrozen(string reason);

    /*=========================== Modifiers =========================*/

    // Modifier to restrict access to governance functions
    modifier onlyGovernance() {
        if (msg.sender != _getStorage().governance) revert NotGovernance();
        _;
    }

    // Modifier to restrict access to asset manager functions
    modifier onlyAllocator() {
        if (msg.sender != _getStorage().allocator) revert NotAllocator();
        _;
    }

    // Modifier to restrict access to reporter functions
    modifier onlyReporter() {
        if (msg.sender != _getStorage().reporter) revert NotReporter();
        _;
    }

    // Modifier to restrict access to treasury functions
    modifier onlyTreasury() {
        if (msg.sender != address(this)) revert NotTreasury();
        _;
    }

    /*=========================== Storage =========================*/

    /// @custom:storage-location erc7201:treasury.main
    struct TreasuryStorageStruct {
        IUSX USX; // USX token contract
        IStakedUSX sUSX; // sUSX vault contract
        IERC20 USDC; // USDC token contract
        address governance; // Governance address
        address reporter; // Reporter address
        address allocator; // Allocator address
        address assetManager; // The current Asset Manager for the protocol
        address insuranceVault; // Insurance vault address
        address governanceWarchest; // Governance warchest address
        uint256 successFeeFraction; // Success fee fraction (default 5% == 50000)
        uint256 insuranceFundFraction; // Insurance fund fraction (default 5% == 50000)
        uint256 assetManagerUSDC; // USDC allocated to Asset Manager
        uint256 netEpochProfits; // total profits reported for all epoches, after deducting Insurance Buffer and Governance Warchest fees
    }

    uint256 public constant DECIMAL_SCALE_FACTOR = 10 ** 12; // Decimal scaling: 10^12. USDC is 6 decimals, USX is 18 decimals (18 - 6 = 12)

    // keccak256(abi.encode(uint256(keccak256("treasury.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TREASURY_STORAGE_LOCATION =
        0x0c53c51c00000000000000000000000000000000000000000000000000000000;

    function _getStorage() internal pure returns (TreasuryStorageStruct storage $) {
        assembly {
            $.slot := TREASURY_STORAGE_LOCATION
        }
    }

    /*=========================== View Functions =========================*/

    function USX() public view returns (IUSX) {
        return _getStorage().USX;
    }

    function sUSX() public view returns (IStakedUSX) {
        return _getStorage().sUSX;
    }

    function USDC() public view returns (IERC20) {
        return _getStorage().USDC;
    }

    function governance() public view returns (address) {
        return _getStorage().governance;
    }

    function assetManager() public view returns (address) {
        return _getStorage().assetManager;
    }

    function governanceWarchest() public view returns (address) {
        return _getStorage().governanceWarchest;
    }

    function successFeeFraction() public view returns (uint256) {
        return _getStorage().successFeeFraction;
    }

    function insuranceFundFraction() public view returns (uint256) {
        return _getStorage().insuranceFundFraction;
    }

    function assetManagerUSDC() public view returns (uint256) {
        return _getStorage().assetManagerUSDC;
    }

    function netEpochProfits() public view returns (uint256) {
        return _getStorage().netEpochProfits;
    }
}
