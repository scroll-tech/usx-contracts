// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {USX} from "../src/USX.sol";
import {StakedUSX} from "../src/StakedUSX.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";

/**
 * @title DeployHelper
 * @dev Helper functions for deployment verification and testing
 */
contract DeployHelper is Script {
    // Contract instances
    USX public usx;
    StakedUSX public susx;
    TreasuryDiamond public treasury;

    // Configuration
    address public constant SCROLL_USDC = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    function initialize(address _usx, address _susx, address _treasury) public {
        usx = USX(_usx);
        susx = StakedUSX(_susx);
        treasury = TreasuryDiamond(payable(_treasury));

        console.log("=== DEPLOYMENT HELPER SETUP ===");
        console.log("USX:", _usx);
        console.log("StakedUSX:", _susx);
        console.log("Treasury:", _treasury);
        console.log("=================================");
    }

    function verifyCompleteSystem() external {
        console.log("\n=== COMPLETE SYSTEM VERIFICATION ===");

        // 1. Verify USX configuration
        verifyUSXConfiguration();

        // 2. Verify StakedUSX configuration
        verifySUSXConfiguration();

        // 3. Verify Treasury configuration
        verifyTreasuryConfiguration();

        // 4. Verify contract linking
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
        console.log("Governance Address:", usx.governance());
        console.log("Admin:", usx.admin());

        // Verify USDC is correct
        require(address(usx.USDC()) == SCROLL_USDC, "USX USDC address mismatch");
        console.log("USX USDC address verified");

        // Verify treasury is linked
        require(address(usx.treasury()) != address(0), "USX treasury not linked");
        console.log("USX treasury linking verified");
    }

    function verifySUSXConfiguration() internal view {
        console.log("\n--- StakedUSX Configuration Verification ---");

        // Basic contract info
        console.log("Name:", susx.name());
        console.log("Symbol:", susx.symbol());
        console.log("Decimals:", susx.decimals());

        // Configuration
        console.log("USX Address:", address(susx.USX()));
        console.log("Treasury Address:", address(susx.treasury()));
        console.log("Governance:", susx.governance());

        // Verify USX is linked
        require(address(susx.USX()) != address(0), "StakedUSX USX not linked");
        console.log("StakedUSX USX linking verified");

        // Verify treasury is linked
        require(address(susx.treasury()) != address(0), "StakedUSX treasury not linked");
        console.log("StakedUSX treasury linking verified");
    }

    function verifyTreasuryConfiguration() internal view {
        console.log("\n--- Treasury Configuration Verification ---");

        // Basic configuration
        console.log("USDC Address:", address(treasury.USDC()));
        console.log("USX Address:", address(treasury.USX()));
        console.log("StakedUSX Address:", address(treasury.sUSX()));
        console.log("Governance:", treasury.governance());
        console.log("Asset Manager:", treasury.assetManager());

        // Verify addresses are correct
        require(address(treasury.USDC()) == SCROLL_USDC, "Treasury USDC address mismatch");
        require(address(treasury.USX()) != address(0), "Treasury USX not linked");
        require(address(treasury.sUSX()) != address(0), "Treasury StakedUSX not linked");

        console.log("Treasury address linking verified");
    }

    function verifyContractLinking() internal view {
        console.log("\n--- Contract Linking Verification ---");

        // Verify USX -> Treasury link
        require(address(usx.treasury()) == address(treasury), "USX -> Treasury link broken");
        console.log("USX -> Treasury link verified");

        // Verify StakedUSX -> Treasury link
        require(address(susx.treasury()) == address(treasury), "StakedUSX -> Treasury link broken");
        console.log("StakedUSX -> Treasury link verified");

        // Verify Treasury -> USX link
        require(address(treasury.USX()) == address(usx), "Treasury -> USX link broken");
        console.log("Treasury -> USX link verified");

        // Verify Treasury -> StakedUSX link
        require(address(treasury.sUSX()) == address(susx), "Treasury -> sUSX link broken");
        console.log("Treasury -> sUSX link verified");

        // Verify Treasury -> USDC link
        require(address(treasury.USDC()) == SCROLL_USDC, "Treasury -> USDC link broken");
        console.log("Treasury -> USDC link verified");
    }
}
