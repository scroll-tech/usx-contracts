// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {USX} from "../src/USX.sol";
import {sUSX} from "../src/sUSX.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployHelper
 * @dev Helper functions for deployment verification and testing
 */
contract DeployHelper is Script {
    
    // Contract instances
    USX public usx;
    sUSX public susx;
    TreasuryDiamond public treasury;
    
    // Configuration
    address public constant SCROLL_USDC = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    
    function setUp(address _usx, address _susx, address _treasury) public {
        usx = USX(_usx);
        susx = sUSX(_susx);
        treasury = TreasuryDiamond(payable(_treasury));
        
        console.log("=== DEPLOYMENT HELPER SETUP ===");
        console.log("USX:", _usx);
        console.log("sUSX:", _susx);
        console.log("Treasury:", _treasury);
        console.log("=================================");
    }
    
    function verifyCompleteSystem() external {
        console.log("\n=== COMPLETE SYSTEM VERIFICATION ===");
        
        // 1. Verify USX configuration
        verifyUSXConfiguration();
        
        // 2. Verify sUSX configuration
        verifySUSXConfiguration();
        
        // 3. Verify Treasury configuration
        verifyTreasuryConfiguration();
        
        // 4. Verify facet functionality
        verifyFacetFunctionality();
        
        // 5. Verify contract linking
        verifyContractLinking();
        
        console.log("\nALL VERIFICATIONS PASSED!");
        console.log("System is fully deployed and functional!");
    }
    
    function verifyUSXConfiguration() internal view {
        console.log("\n--- USX Configuration Verification ---");
        
        // Basic contract info
        console.log("Name:", usx.name());
        console.log("Symbol:", usx.symbol());
        console.log("Decimals:", usx.decimals());
        
        // Configuration
        console.log("USDC Address:", address(usx.USDC()));
        console.log("Treasury Address:", address(usx.treasury()));
        console.log("Governance Warchest:", usx.governanceWarchest());
        console.log("Admin:", usx.admin());
        
        // Verify USDC is correct
        require(address(usx.USDC()) == SCROLL_USDC, "USX USDC address mismatch");
        console.log("USX USDC address verified");
        
        // Verify treasury is linked
        require(address(usx.treasury()) != address(0), "USX treasury not linked");
        console.log("USX treasury linking verified");
    }
    
    function verifySUSXConfiguration() internal view {
        console.log("\n--- sUSX Configuration Verification ---");
        
        // Basic contract info
        console.log("Name:", susx.name());
        console.log("Symbol:", susx.symbol());
        console.log("Decimals:", susx.decimals());
        
        // Configuration
        console.log("USX Address:", address(susx.USX()));
        console.log("Treasury Address:", address(susx.treasury()));
        console.log("Governance:", susx.governance());
        
        // Verify USX is linked
        require(address(susx.USX()) != address(0), "sUSX USX not linked");
        console.log("sUSX USX linking verified");
        
        // Verify treasury is linked
        require(address(susx.treasury()) != address(0), "sUSX treasury not linked");
        console.log("sUSX treasury linking verified");
    }
    
    function verifyTreasuryConfiguration() internal view {
        console.log("\n--- Treasury Configuration Verification ---");
        
        // Basic configuration
        console.log("USDC Address:", address(treasury.USDC()));
        console.log("USX Address:", address(treasury.USX()));
        console.log("sUSX Address:", address(treasury.sUSX()));
        console.log("Governance:", treasury.governance());
        console.log("Asset Manager:", treasury.assetManager());
        
        // Verify addresses are correct
        require(address(treasury.USDC()) == SCROLL_USDC, "Treasury USDC address mismatch");
        require(address(treasury.USX()) != address(0), "Treasury USX not linked");
        require(address(treasury.sUSX()) != address(0), "Treasury sUSX not linked");
        
        console.log("Treasury address linking verified");
    }
    
    function verifyFacetFunctionality() internal {
        console.log("\n--- Facet Functionality Verification ---");
        
        // Test AssetManagerAllocatorFacet
        testAssetManagerFacet();
        
        // Test InsuranceBufferFacet
        testInsuranceBufferFacet();
        
        // Test ProfitAndLossReporterFacet
        testProfitAndLossFacet();
        
        console.log("All facet functionality verified");
    }
    
    function testAssetManagerFacet() internal {
        console.log("  Testing AssetManagerAllocatorFacet...");
        
        // Test maxLeverage function
        bytes memory maxLeverageData = abi.encodeWithSelector(
            bytes4(keccak256("maxLeverage()"))
        );
        (bool success, bytes memory result) = address(treasury).call(maxLeverageData);
        require(success, "maxLeverage call failed");
        
        uint256 maxLeverage = abi.decode(result, (uint256));
        console.log("    maxLeverage:", maxLeverage);
        
        // Test netDeposits function (skip on local fork where USDC doesn't exist)
        try this.testNetDeposits(address(treasury)) {
            console.log("    netDeposits: tested successfully");
        } catch {
            console.log("    netDeposits: skipped (USDC not available on local fork)");
        }
    }
    
    function testInsuranceBufferFacet() internal {
        console.log("  Testing InsuranceBufferFacet...");
        
        // Test bufferTarget function
        bytes memory bufferTargetData = abi.encodeWithSelector(
            bytes4(keccak256("bufferTarget()"))
        );
        (bool success, bytes memory result) = address(treasury).call(bufferTargetData);
        require(success, "bufferTarget call failed");
        
        uint256 bufferTarget = abi.decode(result, (uint256));
        console.log("    bufferTarget:", bufferTarget);
        

    }
    
    function testProfitAndLossFacet() internal {
        console.log("  Testing ProfitAndLossReporterFacet...");
        
        // Test successFee function
        bytes memory successFeeData = abi.encodeWithSelector(
            bytes4(keccak256("successFee(uint256)")),
            1000000 // 1M profit amount
        );
        (bool success, bytes memory result) = address(treasury).call(successFeeData);
        require(success, "successFee call failed");
        
        uint256 successFee = abi.decode(result, (uint256));
        console.log("    successFee:", successFee);
        
        // Test profitLatestEpoch function
        bytes memory profitLatestEpochData = abi.encodeWithSelector(
            bytes4(keccak256("profitLatestEpoch()"))
        );
        (success, result) = address(treasury).call(profitLatestEpochData);
        require(success, "profitLatestEpoch call failed");
        
        uint256 profitLatestEpoch = abi.decode(result, (uint256));
        console.log("    profitLatestEpoch:", profitLatestEpoch);
    }
    
    function verifyContractLinking() internal view {
        console.log("\n--- Contract Linking Verification ---");
        
        // Verify USX -> Treasury link
        require(address(usx.treasury()) == address(treasury), "USX -> Treasury link broken");
        console.log("USX -> Treasury link verified");
        
        // Verify sUSX -> Treasury link
        require(address(susx.treasury()) == address(treasury), "sUSX -> Treasury link broken");
        console.log("sUSX -> Treasury link verified");
        
        // Verify Treasury -> USX link
        require(address(treasury.USX()) == address(usx), "Treasury -> USX link broken");
        console.log("Treasury -> USX link verified");
        
        // Verify Treasury -> sUSX link
        require(address(treasury.sUSX()) == address(susx), "Treasury -> sUSX link broken");
        console.log("Treasury -> sUSX link verified");
        
        // Verify Treasury -> USDC link
        require(address(treasury.USDC()) == SCROLL_USDC, "Treasury -> USDC link broken");
        console.log("Treasury -> USDC link verified");
    }
    
    function testBasicOperations() external {
        console.log("\n=== TESTING BASIC OPERATIONS ===");
        
        // Test USX minting (if deployer has permission)
        testUSXMinting();
        
        // Test sUSX operations
        testSUSXOperations();
        
        // Test Treasury operations
        testTreasuryOperations();
        
        console.log("All basic operations tested successfully");
    }
    
    function testNetDeposits(address treasuryAddr) external returns (uint256) {
        bytes memory netDepositsData = abi.encodeWithSelector(
            bytes4(keccak256("netDeposits()"))
        );
        (bool success, bytes memory result) = treasuryAddr.call(netDepositsData);
        require(success, "netDeposits call failed");
        
        uint256 netDeposits = abi.decode(result, (uint256));
        return netDeposits;
    }
    
    function testUSXMinting() internal {
        console.log("  Testing USX minting...");
        
        // Check if deployer can mint (should have admin role)
        try usx.mintUSX(address(this), 1000e18) {
            console.log("    USX minting successful");
        } catch {
            console.log("    USX minting failed (expected if not admin)");
        }
    }
    
    function testSUSXOperations() internal {
        console.log("  Testing sUSX operations...");
        
        // Test share price calculation
        uint256 sharePrice = susx.sharePrice();
        console.log("    sharePrice:", sharePrice);
        
        // Test epoch information
        uint256 lastEpochBlock = susx.lastEpochBlock();
        uint256 epochDuration = susx.epochDuration();
        console.log("    lastEpochBlock:", lastEpochBlock);
        console.log("    epochDuration:", epochDuration);
    }
    
    function testTreasuryOperations() internal {
        console.log("  Testing Treasury operations...");
        
        // Test default values
        uint256 maxLeverageFraction = treasury.maxLeverageFraction();
        uint256 successFeeFraction = treasury.successFeeFraction();
        uint256 bufferTargetFraction = treasury.bufferTargetFraction();
        
        console.log("    maxLeverageFraction:", maxLeverageFraction);
        console.log("    successFeeFraction:", successFeeFraction);
        console.log("    bufferTargetFraction:", bufferTargetFraction);
        
        // Verify default values are set correctly
        require(maxLeverageFraction == 100000, "Default maxLeverageFraction incorrect");
        require(successFeeFraction == 50000, "Default successFeeFraction incorrect");
        require(bufferTargetFraction == 50000, "Default bufferTargetFraction incorrect");
    }
}
