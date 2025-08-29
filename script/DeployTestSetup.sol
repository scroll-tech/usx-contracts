// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {DeployScroll} from "../script/DeployScroll.s.sol";
import {DeployHelper} from "../script/DeployHelper.s.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {USX} from "../src/USX.sol";
import {sUSX} from "../src/sUSX.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockAssetManager} from "../src/mocks/MockAssetManager.sol";

/**
 * @title DeployTestSetup
 * @dev Base test class that uses the actual deployment script to set up contracts
 * This ensures tests run against the exact same contract setup as production
 */
contract DeployTestSetup is Test {
    // Common addresses for testing
    address public governance;
    address public admin;
    address public assetManager;
    address public governanceWarchest;
    address public user = address(0x999); // Test user address
    
    // Deployed contract addresses
    address public usxProxy;
    address public susxProxy;
    address public treasuryProxy;
    
    // Contract interfaces
    USX public usx;
    sUSX public susx;
    TreasuryDiamond public treasury;
    IERC20 public usdc;
    MockAssetManager public mockAssetManager;
    
    // Deployment script reference
    DeployScroll public deployer;
    
    // Real Scroll mainnet addresses
    address public constant SCROLL_USDC = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    
    // Test addresses (matching deployment script)
    address public deployerAddress;
    
    // Environment variables for deployment
    string public deploymentTarget = "local";
    
    function setUp() public virtual {
        console.log("=== STARTING TEST SETUP ===");
        
        // Set environment variables FIRST
        _setEnvironmentVariables();
        console.log("Environment variables set successfully");
        
        // Deploy MockAssetManager FIRST
        console.log("Deploying MockAssetManager...");
        mockAssetManager = new MockAssetManager(SCROLL_USDC);
        console.log("MockAssetManager deployed at:", address(mockAssetManager));
        
        // Update asset manager address to use the deployed MockAssetManager
        assetManager = address(mockAssetManager);
        vm.setEnv("ASSET_MANAGER_ADDRESS", vm.toString(assetManager));
        console.log("Updated ASSET_MANAGER_ADDRESS to:", assetManager);
        
        // Then run deployment script
        console.log("Running deployment script for test setup...");
        DeployScroll deploymentScript = new DeployScroll();
        deploymentScript.run();
        console.log("Deployment script completed");
        
        // Get deployed contract addresses from the deployment script
        usxProxy = deploymentScript.usxProxy();
        susxProxy = deploymentScript.susxProxy();
        treasuryProxy = deploymentScript.treasuryProxy();
        console.log("Got deployed addresses:", usxProxy, susxProxy, treasuryProxy);

        // Instantiate contract interfaces
        usx = USX(usxProxy);
        susx = sUSX(susxProxy);
        treasury = TreasuryDiamond(payable(treasuryProxy));
        usdc = IERC20(SCROLL_USDC);
        console.log("Contract interfaces instantiated");

        // Set up test environment with USDC balances and allowances
        console.log("Setting up test environment...");
        _setupTestEnvironment();
        console.log("Test environment setup completed");
        
        // Verify MockAssetManager is properly set up
        console.log("Verifying MockAssetManager setup...");
        require(address(mockAssetManager) != address(0), "MockAssetManager not deployed");
        require(address(mockAssetManager.USDC()) == SCROLL_USDC, "MockAssetManager USDC address mismatch");
        console.log("MockAssetManager setup verified");

        console.log("=== TEST SETUP COMPLETE ===");
        console.log("USX Proxy:", usxProxy);
        console.log("sUSX Proxy:", susxProxy);
        console.log("Treasury Proxy:", treasuryProxy);
        console.log("MockAssetManager:", address(mockAssetManager));
        console.log("Chain ID:", block.chainid);
        console.log("=============================");

        _verifyDeployment();
    }

    /**
     * @dev Set up test environment with USDC balances and allowances
     */
    function _setupTestEnvironment() internal {
        console.log("  Setting up USDC balances...");
        // Give treasury some USDC to work with
        deal(SCROLL_USDC, address(treasury), 1000000e6); // 1,000,000 USDC
        
        // Give test user some USDC for testing (increased for large amount tests)
        deal(SCROLL_USDC, user, 10000000e6); // 10,000,000 USDC (increased from 10,000)
        
        // Give USX contract some USDC for withdrawal requests
        deal(SCROLL_USDC, address(usx), 1000000e6); // 1,000,000 USDC
        console.log("  USDC balances set");
        
        console.log("  Setting up USDC approvals...");
        // Approve USDC spending for USX contract
        vm.prank(user);
        usdc.approve(address(usx), type(uint256).max);
        console.log("  USDC approvals set");
        
        console.log("  Whitelisting test user...");
        // Whitelist test user
        vm.prank(admin);
        usx.whitelistUser(user, true);
        console.log("  Test user whitelisted");
        
        // Seed the vault with USX for leverage testing
        console.log("  Seeding vault with USX for testing...");
        _seedVaultWithUSX();
        console.log("  Vault seeded with USX");
        
        // Advance block number to avoid arithmetic underflow in time-based functions
        console.log("  Advancing block number for time-based functions...");
        _advanceBlockForTimeBasedFunctions();
        console.log("  Block number advanced");
    }
    
    /**
     * @dev Seed the sUSX vault with USX for testing leverage functions
     * This is needed because checkMaxLeverage() depends on vault having USX
     */
    function _seedVaultWithUSX() internal {
        // First, deposit USDC to get USX
        vm.prank(user);
        usx.deposit(1000000e6); // Deposit 1,000,000 USDC to get USX
        
        // Then deposit USX to sUSX vault to get sUSX shares
        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);
        vm.prank(user);
        susx.deposit(usxBalance, user);
        
        console.log("  Vault now has USX balance:", usx.balanceOf(address(susx)));
    }
    
    function _setEnvironmentVariables() internal {
        // Set all required environment variables for deployment script
        vm.setEnv("DEPLOYMENT_TARGET", deploymentTarget);
        vm.setEnv("USDC_ADDRESS", vm.toString(SCROLL_USDC));
        
        // Use deterministic addresses that match what we set in the test
        governance = 0x1000000000000000000000000000000000000001;
        governanceWarchest = 0x2000000000000000000000000000000000000002;
        assetManager = 0x3000000000000000000000000000000000000003;
        admin = 0x4000000000000000000000000000000000000004;
        
        // Set environment variables to match our test addresses
        vm.setEnv("GOVERNANCE_ADDRESS", vm.toString(governance));
        vm.setEnv("GOVERNANCE_WARCHEST_ADDRESS", vm.toString(governanceWarchest));
        vm.setEnv("ASSET_MANAGER_ADDRESS", vm.toString(assetManager));
        vm.setEnv("ADMIN_ADDRESS", vm.toString(admin));
        
        // Set RPC URLs
        vm.setEnv("SCROLL_MAINNET_RPC", "https://rpc.scroll.io");
        vm.setEnv("SCROLL_SEPOLIA_RPC", "https://sepolia-rpc.scroll.io");
        
        console.log("Environment variables set:");
        console.log("Governance:", governance);
        console.log("Governance Warchest:", governanceWarchest);
        console.log("Asset Manager:", assetManager);
        console.log("Admin:", admin);
    }
    
    function _runDeployment() internal {
        console.log("Running deployment script for test setup...");
        
        // Create and run the deployment script
        deployer = new DeployScroll();
        deployer.run();
        
        // Get the deployed addresses
        usxProxy = deployer.usxProxy();
        susxProxy = deployer.susxProxy();
        treasuryProxy = deployer.treasuryProxy();
        
        // Verify addresses were returned
        require(usxProxy != address(0), "USX proxy not deployed");
        require(susxProxy != address(0), "sUSX proxy not deployed");
        require(treasuryProxy != address(0), "Treasury proxy not deployed");
        
        console.log("Deployment completed successfully");
    }
    
    function _setupContractInterfaces() internal {
        // Set up contract interfaces for easy testing
        usx = USX(usxProxy);
        susx = sUSX(susxProxy);
        treasury = TreasuryDiamond(payable(treasuryProxy));
        usdc = IERC20(SCROLL_USDC);
        
        // Get deployer address from deployment script
        deployerAddress = deployer.deployer();
    }
    
    function _verifyDeployment() internal {
        console.log("Verifying deployment...");
        
        // Basic verification that contracts are accessible
        require(address(usx) != address(0), "USX interface not set");
        require(address(susx) != address(0), "sUSX interface not set");
        require(address(treasury) != address(0), "Treasury interface not set");
        
        // Verify contract linking
        require(address(usx.treasury()) == address(treasury), "USX not linked to Treasury");
        require(address(susx.treasury()) == address(treasury), "sUSX not linked to Treasury");
        require(address(treasury.USX()) == address(usx), "Treasury not linked to USX");
        require(address(treasury.sUSX()) == address(susx), "Treasury not linked to sUSX");
        require(address(treasury.USDC()) == SCROLL_USDC, "Treasury not linked to USDC");
        require(address(treasury.assetManager()) == address(mockAssetManager), "Treasury not linked to MockAssetManager");
        
        console.log("Deployment verification passed");
    }
    
    // Helper functions for testing
    
    /**
     * @dev Call a facet function through the diamond
     */
    function callFacetFunction(bytes4 selector, bytes memory data) internal returns (bool success, bytes memory result) {
        return address(treasury).call(abi.encodeWithSelector(selector, data));
    }
    
    /**
     * @dev Call a facet function through the diamond with no parameters
     */
    function callFacetFunction(bytes4 selector) internal returns (bool success, bytes memory result) {
        return address(treasury).call(abi.encodeWithSelector(selector));
    }
    
    /**
     * @dev Get the current deployer address
     */
    function getDeployer() internal view returns (address) {
        return deployerAddress != address(0) ? deployerAddress : governance;
    }
    
    /**
     * @dev Check if a facet function is accessible through the diamond
     */
    function isFacetFunctionAccessible(bytes4 selector) internal view returns (bool) {
        // Try to call the function with no parameters
        (bool success,) = address(treasury).staticcall(abi.encodeWithSelector(selector));
        return success;
    }
    
    /**
     * @dev Get contract addresses for verification
     */
    function getDeployedAddresses() internal view returns (address _usx, address _susx, address _treasury) {
        return (usxProxy, susxProxy, treasuryProxy);
    }
    
    /**
     * @dev Switch deployment target for different test scenarios
     */
    function setDeploymentTarget(string memory target) internal {
        deploymentTarget = target;
        vm.setEnv("DEPLOYMENT_TARGET", target);
    }
    
    /**
     * @dev Advance block number to avoid arithmetic underflow in time-based functions
     * This is no longer needed since we fixed the contract initialization
     */
    function _advanceBlockForTimeBasedFunctions() internal {
        // This function is kept for backward compatibility but is no longer needed
        // The contract now properly initializes lastEpochBlock to epoch boundaries
        console.log("  Block advancement not needed - contract properly initialized");
    }
}
