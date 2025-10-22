// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {TreasuryStorage} from "./TreasuryStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUSX} from "./interfaces/IUSX.sol";
import {IStakedUSX} from "./interfaces/IStakedUSX.sol";

/// @title TreasuryDiamond
/// @notice The main contract for the USX Protocol Treasury
/// @dev The TreasuryDiamond contract is a proxy contract that delegates calls to the various facets of the Treasury

contract TreasuryDiamond is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, TreasuryStorage {
    /*=========================== Events =========================*/

    event FacetAdded(bytes4 indexed selector, address indexed facet);
    event FacetRemoved(bytes4 indexed selector);
    event FacetReplaced(bytes4 indexed selector, address indexed oldFacet, address indexed newFacet);
    event TreasuryInitialized(address indexed USDC, address indexed USX, address indexed sUSX);

    /*=========================== Storage =========================*/

    // Mapping from function selector to facet address
    mapping(bytes4 => address) public facets;

    // Array of all facet addresses
    address[] public facetAddresses;

    // Mapping from facet address to array of function selectors
    mapping(address => bytes4[]) public facetFunctionSelectors;

    /*=========================== Initialization =========================*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the Treasury Diamond
    /// @dev Initialize the Treasury Diamond
    /// @param _USDC Address of USDC token
    /// @param _USX Address of USX token
    /// @param _sUSX Address of sUSX vault
    /// @param _governance Address of governance
    /// @param _governanceWarchest Address of governance warchest
    /// @param _assetManager Address of asset manager
    function initialize(
        address _USDC,
        address _USX,
        address _sUSX,
        address _admin,
        address _governance,
        address _governanceWarchest,
        address _assetManager,
        address _insuranceVault
    ) public initializer {
        if (
            _USDC == address(0) || _USX == address(0) || _sUSX == address(0) || _admin == address(0) || _governance == address(0)
                || _governanceWarchest == address(0)
        ) {
            revert ZeroAddress();
        }

        // Initialize ReentrancyGuard
        __ReentrancyGuard_init();

        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        $.USDC = IERC20(_USDC);
        $.USX = IUSX(_USX);
        $.sUSX = IStakedUSX(_sUSX);
        $.admin = _admin;
        $.governance = _governance;
        $.assetManager = _assetManager;
        $.governanceWarchest = _governanceWarchest;
        $.insuranceVault = _insuranceVault;

        // Set default values
        $.successFeeFraction = 50000; // 5%
        $.insuranceFundFraction = 50000; // 5%

        emit TreasuryInitialized(_USDC, _USX, _sUSX);
    }

    /*=========================== Diamond Functions =========================*/

    /// @notice Add a new facet to the diamond
    /// @param _facet Address of the facet to add
    /// @param _selectors Array of function selectors to add
    function addFacet(address _facet, bytes4[] calldata _selectors) external onlyGovernance {
        if (_facet == address(0)) revert ZeroAddress();

        for (uint256 i = 0; i < _selectors.length; i++) {
            bytes4 selector = _selectors[i];
            if (facets[selector] != address(0)) revert FacetAlreadyExists();

            facets[selector] = _facet;
            facetFunctionSelectors[_facet].push(selector);
        }

        // Add facet to array if it's new
        bool facetExists = false;
        for (uint256 i = 0; i < facetAddresses.length; i++) {
            if (facetAddresses[i] == _facet) {
                facetExists = true;
                break;
            }
        }

        if (!facetExists) {
            facetAddresses.push(_facet);
        }

        emit FacetAdded(_selectors[0], _facet);
    }

    /// @notice Remove a facet from the diamond
    /// @param _facet Address of the facet to remove
    function removeFacet(address _facet) external onlyGovernance {
        bytes4[] memory selectors = facetFunctionSelectors[_facet];

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            delete facets[selector];
        }

        // Remove facet from array
        for (uint256 i = 0; i < facetAddresses.length; i++) {
            if (facetAddresses[i] == _facet) {
                facetAddresses[i] = facetAddresses[facetAddresses.length - 1];
                facetAddresses.pop();
                break;
            }
        }

        delete facetFunctionSelectors[_facet];
        emit FacetRemoved(selectors[0]);
    }

    /// @notice Replace a facet with a new one
    /// @param _oldFacet Address of the old facet
    /// @param _newFacet Address of the new facet
    function replaceFacet(address _oldFacet, address _newFacet) external onlyGovernance {
        if (_newFacet == address(0)) revert ZeroAddress();
        if (_oldFacet == _newFacet) revert InvalidFacet();

        bytes4[] memory selectors = facetFunctionSelectors[_oldFacet];

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            facets[selector] = _newFacet;
        }

        // Update facet arrays
        for (uint256 i = 0; i < facetAddresses.length; i++) {
            if (facetAddresses[i] == _oldFacet) {
                facetAddresses[i] = _newFacet;
                break;
            }
        }

        // Transfer selectors to new facet
        facetFunctionSelectors[_newFacet] = facetFunctionSelectors[_oldFacet];
        delete facetFunctionSelectors[_oldFacet];

        emit FacetReplaced(selectors[0], _oldFacet, _newFacet);
    }

    /// @notice Set new governance address
    /// @param newGovernance Address of new governance
    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();

        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        address oldGovernance = $.governance;
        $.governance = newGovernance;

        emit GovernanceTransferred(oldGovernance, newGovernance);
    }

    /// @notice Set new governance warchest address
    /// @param newGovernanceWarchest Address of new governance warchest
    function setGovernanceWarchest(address newGovernanceWarchest) external onlyGovernance {
        if (newGovernanceWarchest == address(0)) revert ZeroAddress();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        address oldGovernanceWarchest = $.governanceWarchest;
        $.governanceWarchest = newGovernanceWarchest;
        emit GovernanceWarchestTransferred(oldGovernanceWarchest, newGovernanceWarchest);
    }

    /// @notice Set new insurance vault address
    /// @param newInsuranceVault Address of new insurance vault
    function setInsuranceVault(address newInsuranceVault) external onlyGovernance {
        if (newInsuranceVault == address(0)) revert ZeroAddress();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        address oldInsuranceVault = $.insuranceVault;
        $.insuranceVault = newInsuranceVault;
        emit InsuranceVaultTransferred(oldInsuranceVault, newInsuranceVault);
    }

    /// @notice Set new admin address
    /// @param newAdmin Address of new admin
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        TreasuryStorage.TreasuryStorageStruct storage $ = _getStorage();
        address oldAdmin = $.admin;
        $.admin = newAdmin;

        emit AdminTransferred(oldAdmin, newAdmin);
    }
    /*=========================== Fallback =========================*/

    /// @dev Fallback function that delegates calls to facets
    fallback() external payable {
        address facet = facets[msg.sig];
        if (facet == address(0)) revert SelectorNotFound();

        // Execute external call
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @dev Receive function for ETH
    receive() external payable {}

    /*=========================== UUPS Functions =========================*/

    /// @notice Authorize upgrade to new implementation
    /// @param newImplementation Address of new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}

    /// @notice Get current implementation version
    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}
