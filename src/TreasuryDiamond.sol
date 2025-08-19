// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {TreasuryStorage} from "./TreasuryStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUSX} from "./interfaces/IUSX.sol";
import {IsUSX} from "./interfaces/IsUSX.sol";
import {IAssetManager} from "./interfaces/IAssetManager.sol"; // TODO: Remove, or integrate.

contract TreasuryDiamond is TreasuryStorage, UUPSUpgradeable, Initializable {
    
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
    
    /**
     * @dev Initialize the Treasury Diamond
     * @param _USDC Address of USDC token
     * @param _USX Address of USX token
     * @param _sUSX Address of sUSX vault
     * @param _governance Address of governance
     * @param _governanceWarchest Address of governance warchest
     */
    function initialize(
        address _USDC,
        address _USX,
        address _sUSX,
        address _governance,
        address _governanceWarchest
    ) public initializer {
        if (_USDC == address(0) || _USX == address(0) || _sUSX == address(0) || 
            _governance == address(0) || _governanceWarchest == address(0)) {
            revert ZeroAddress();
        }
        
        USDC = IERC20(_USDC);
        USX = IUSX(_USX);
        sUSX = IsUSX(_sUSX);
        governance = _governance;
        governanceWarchest = _governanceWarchest;
        
        // Set default values
        successFeeFraction = 50000;      // 5%
        maxLeverage = 100000;            // 10%
        bufferRenewalFraction = 100000;  // 10%
        bufferTargetFraction = 50000;    // 5%
        
        emit TreasuryInitialized(_USDC, _USX, _sUSX);
    }
    
    /*=========================== Diamond Functions =========================*/
    
    /**
     * @dev Add a new facet to the diamond
     * @param _facet Address of the facet to add
     * @param _selectors Array of function selectors to add
     */
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
    
    /**
     * @dev Remove a facet from the diamond
     * @param _facet Address of the facet to remove
     */
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
    
    /**
     * @dev Replace a facet with a new one
     * @param _oldFacet Address of the old facet
     * @param _newFacet Address of the new facet
     */
    function replaceFacet(address _oldFacet, address _newFacet) external onlyGovernance {
        if (_newFacet == address(0)) revert ZeroAddress();
        
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
    
    /*=========================== Fallback =========================*/
    
    /**
     * @dev Fallback function that delegates calls to facets
     */
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
    
    /**
     * @dev Receive function for ETH
     */
    receive() external payable {}
    
    /*=========================== UUPS Functions =========================*/
    
    /**
     * @dev Authorize upgrade to new implementation
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}
    
    /**
     * @dev Get current implementation version
     */
    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}
