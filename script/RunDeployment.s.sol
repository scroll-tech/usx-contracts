// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {DeployScroll} from "./DeployScroll.s.sol";
import {DeployHelper} from "./DeployHelper.s.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RunDeployment
 * @dev Main deployment runner that orchestrates the entire deployment process
 * This script provides a simple interface for running the full deployment
 */
contract RunDeployment is Script {
    
    // Deployment script instance
    DeployScroll public deployer;
    
    // Helper script instance
    DeployHelper public helper;
    
    // Deployed contract addresses
    address public usxProxy;
    address public susxProxy;
    address public treasuryProxy;
    
    function run() external {
        console.log("STARTING FULL SYSTEM DEPLOYMENT");
        console.log("=====================================");
        
        // Step 1: Run the main deployment
        runMainDeployment();
        
        // Step 2: Verify the deployment
        verifyDeployment();
        
        // Step 3: Test basic functionality
        testBasicFunctionality();
        
        // Step 4: Display deployment summary
        displayDeploymentSummary();
        
        console.log("DEPLOYMENT COMPLETE AND VERIFIED!");
        console.log("=====================================");
    }
    
    function runMainDeployment() internal {
        console.log("STEP 1: Running Main Deployment");
        console.log("-------------------------------------");
        
        // Create and run the deployment script
        deployer = new DeployScroll();
        deployer.run();
        
        // Get the deployed addresses
        usxProxy = deployer.usxProxy();
        susxProxy = deployer.susxProxy();
        treasuryProxy = deployer.treasuryProxy();
        
        console.log("Main deployment completed successfully");
        console.log("   USX Proxy:", usxProxy);
        console.log("   sUSX Proxy:", susxProxy);
        console.log("   Treasury Proxy:", treasuryProxy);
    }
    
    function verifyDeployment() internal {
        console.log("STEP 2: Verifying Deployment");
        console.log("--------------------------------");
        
        // Create and run the helper script
        helper = new DeployHelper();
        helper.setUp(usxProxy, susxProxy, treasuryProxy);
        
        // Run comprehensive verification
        helper.verifyCompleteSystem();
        
        console.log("Deployment verification completed successfully");
    }
    
    function testBasicFunctionality() internal {
        console.log("STEP 3: Testing Basic Functionality");
        console.log("---------------------------------------");
        
        // Test basic operations
        helper.testBasicOperations();
        
        console.log("Basic functionality testing completed successfully");
    }
    
    function displayDeploymentSummary() internal {
        console.log("DEPLOYMENT SUMMARY");
        console.log("=====================");
        console.log("Network: Scroll Mainnet Fork");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  USX Token:", usxProxy);
        console.log("  sUSX Vault:", susxProxy);
        console.log("  Treasury Diamond:", treasuryProxy);
        console.log("");
        console.log("Facets Added:");
        console.log("  AssetManagerAllocatorFacet");
        console.log("  InsuranceBufferFacet");
        console.log("  ProfitAndLossReporterFacet");
        console.log("");
        console.log("Configuration:");
        console.log("  USDC Address:", 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        console.log("  Governance:", 0x1000000000000000000000000000000000000001);
        console.log("  Asset Manager:", 0x3000000000000000000000000000000000000003);
        console.log("");
        console.log("Default Values:");
        console.log("  Max Leverage Fraction: 10% (100000)");
        console.log("  Success Fee Fraction: 5% (50000)");
        console.log("  Buffer Target Fraction: 5% (50000)");
        console.log("  Buffer Renewal Fraction: 10% (100000)");
    }
    
    // Additional utility functions for post-deployment operations
    
    function getDeployedAddresses() external view returns (
        address _usx,
        address _susx,
        address _treasury
    ) {
        return (usxProxy, susxProxy, treasuryProxy);
    }
    
    function runPostDeploymentTests() external {
        console.log("RUNNING POST-DEPLOYMENT TESTS");
        console.log("=================================");
        
        // Re-run verification
        helper.verifyCompleteSystem();
        
        // Re-run basic operations
        helper.testBasicOperations();
        
        console.log("Post-deployment tests completed successfully");
    }
    
    function checkContractState() external view {
        console.log("CONTRACT STATE CHECK");
        console.log("=======================");
        
        // Check USX state
        console.log("USX State:");
        console.log("  Total Supply:", IUSX(usxProxy).totalSupply());
        console.log("  Treasury Linked:", address(IUSX(usxProxy).treasury()));
        
        // Check sUSX state
        console.log("sUSX State:");
        console.log("  Total Supply:", IsUSX(susxProxy).totalSupply());
        console.log("  Treasury Linked:", address(IsUSX(susxProxy).treasury()));
        console.log("  Share Price:", IsUSX(susxProxy).sharePrice());
        
        // Check Treasury state
        console.log("Treasury State:");
        console.log("  USDC Balance:", IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4).balanceOf(treasuryProxy));
        console.log("  Asset Manager USDC:", TreasuryDiamond(payable(treasuryProxy)).assetManagerUSDC());
    }
}

// Interface imports for type safety
interface IUSX {
    function totalSupply() external view returns (uint256);
    function treasury() external view returns (address);
}

interface IsUSX {
    function totalSupply() external view returns (uint256);
    function treasury() external view returns (address);
    function sharePrice() external view returns (uint256);
}
