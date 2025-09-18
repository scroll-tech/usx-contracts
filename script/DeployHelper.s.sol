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

    function verifyFacetFunctionality() internal {
        console.log("\n--- Facet Functionality Verification ---");

        // Test AssetManagerAllocatorFacet
        testAssetManagerFacet();

        // Test InsuranceBufferFacet
        testInsuranceBufferFacet();

        // Test RewardDistributorFacet
        testProfitAndLossFacet();

        console.log("All facet functionality verified");
    }

    function testAssetManagerFacet() internal {
        console.log("  Testing AssetManagerAllocatorFacet...");

        // Test maxLeverage function
        bytes memory maxLeverageData = abi.encodeWithSelector(bytes4(keccak256("maxLeverage()")));
        (bool success, bytes memory result) = address(treasury).call(maxLeverageData);
        require(success, "maxLeverage call failed");

        uint256 maxLeverage = abi.decode(result, (uint256));
        console.log("    maxLeverage:", maxLeverage);

        // Test netDeposits function - USDC is available on Scroll mainnet fork
        bytes memory netDepositsData = abi.encodeWithSelector(bytes4(keccak256("netDeposits()")));
        (success, result) = address(treasury).call(netDepositsData);
        require(success, "netDeposits call failed");

        uint256 netDeposits = abi.decode(result, (uint256));
        console.log("    netDeposits:", netDeposits);

        // Test checkMaxLeverage function
        bytes memory checkMaxLeverageData = abi.encodeWithSelector(
            bytes4(keccak256("checkMaxLeverage(uint256)")),
            1000000 // 1M USDC allocation
        );
        (success, result) = address(treasury).call(checkMaxLeverageData);
        require(success, "checkMaxLeverage call failed");

        bool isWithinLimit = abi.decode(result, (bool));
        console.log("    checkMaxLeverage(1M):", isWithinLimit ? "within limit" : "exceeds limit");
    }

    function testInsuranceBufferFacet() internal {
        console.log("  Testing InsuranceBufferFacet...");

        // Test bufferTarget function
        bytes memory bufferTargetData = abi.encodeWithSelector(bytes4(keccak256("bufferTarget()")));
        (bool success, bytes memory result) = address(treasury).call(bufferTargetData);
        require(success, "bufferTarget call failed");

        uint256 bufferTarget = abi.decode(result, (uint256));
        console.log("    bufferTarget:", bufferTarget);

        // Test bufferRenewalRate function
        bytes memory bufferRenewalRateData = abi.encodeWithSelector(bytes4(keccak256("bufferRenewalRate()")));
        (success, result) = address(treasury).call(bufferRenewalRateData);
        require(success, "bufferRenewalRate call failed");

        uint256 bufferRenewalRate = abi.decode(result, (uint256));
        console.log("    bufferRenewalRate:", bufferRenewalRate);

        // Note: topUpBuffer and slashBuffer are internal functions that get called during other operations
        // They will be tested as part of the full flow in the actual test suite
        console.log("    topUpBuffer: internal function (tested in full flow)");
        console.log("    slashBuffer: internal function (tested in full flow)");
    }

    function testProfitAndLossFacet() internal {
        console.log("  Testing RewardDistributorFacet...");

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
        bytes memory profitLatestEpochData = abi.encodeWithSelector(bytes4(keccak256("profitLatestEpoch()")));
        (success, result) = address(treasury).call(profitLatestEpochData);
        require(success, "profitLatestEpoch call failed");

        uint256 profitLatestEpoch = abi.decode(result, (uint256));
        console.log("    profitLatestEpoch:", profitLatestEpoch);

        // Test profitPerBlock function
        bytes memory profitPerBlockData = abi.encodeWithSelector(bytes4(keccak256("profitPerBlock()")));
        (success, result) = address(treasury).call(profitPerBlockData);
        require(success, "profitPerBlock call failed");

        uint256 profitPerBlock = abi.decode(result, (uint256));
        console.log("    profitPerBlock:", profitPerBlock);

        // Note: assetManagerReport is a state-changing function that gets called during other operations
        // It will be tested as part of the full flow in the actual test suite
        console.log("    assetManagerReport: state-changing function (tested in full flow)");
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
