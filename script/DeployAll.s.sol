// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {USX} from "../src/USX.sol";
import {sUSX} from "../src/sUSX.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {ProfitAndLossReporterFacet} from "../src/facets/ProfitAndLossReporterFacet.sol";
import {InsuranceBufferFacet} from "../src/facets/InsuranceBufferFacet.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";

/**
 * @title DeployAll
 * @dev Complete deployment script for the entire USX ecosystem
 */
contract DeployAll is Script {
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address governanceAddress = vm.envAddress("GOVERNANCE_ADDRESS");
        
        // Deployment target selection
        string memory deploymentTarget = vm.envString("DEPLOYMENT_TARGET");
        string memory rpcUrl;
        
        if (keccak256(abi.encodePacked(deploymentTarget)) == keccak256(abi.encodePacked("mainnet"))) {
            rpcUrl = vm.envString("SCROLL_MAINNET_RPC");
            console.log("=== DEPLOYING TO SCROLL MAINNET ===");
        } else if (keccak256(abi.encodePacked(deploymentTarget)) == keccak256(abi.encodePacked("sepolia"))) {
            rpcUrl = vm.envString("SCROLL_SEPOLIA_RPC");
            console.log("=== DEPLOYING TO SCROLL SEPOLIA TESTNET ===");
        } else if (keccak256(abi.encodePacked(deploymentTarget)) == keccak256(abi.encodePacked("local"))) {
            rpcUrl = "http://localhost:8545";
            console.log("=== DEPLOYING TO LOCAL SCROLL FORK ===");
        } else {
            revert("Invalid DEPLOYMENT_TARGET. Use 'mainnet', 'sepolia', or 'local'");
        }
        
        console.log("RPC URL:", rpcUrl);
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Target Governance:", governanceAddress);
        console.log("Note: Deployer will act as governance during setup, then transfer to target governance");
        console.log("=========================================");
        
        // Note: RPC URL is set via --fork-url flag when running the script
        
        console.log("=== DEPLOYING WITH OPENZEPPELIN FOUNDRY UPGRADES ===");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Network:", block.chainid);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Deploy USX Token with UUPS proxy
        console.log("\n=== STEP 1: Deploying USX Token ===");
        address usxProxy = Upgrades.deployUUPSProxy(
            "USX.sol",
            abi.encodeCall(USX.initialize, (
                vm.envAddress("USDC_ADDRESS"),
                address(0), // Treasury address (will be set later)
                vm.addr(deployerPrivateKey), // Deployer acts as governance during setup
                vm.envAddress("ADMIN_ADDRESS")
            ))
        );
        console.log("USX Token deployed at:", usxProxy);
        
        // Step 2: Deploy sUSX Vault with UUPS proxy
        console.log("\n=== STEP 2: Deploying sUSX Vault ===");
        address susxProxy = Upgrades.deployUUPSProxy(
            "sUSX.sol",
            abi.encodeCall(sUSX.initialize, (
                usxProxy, // USX address
                address(0), // Treasury address (will be set later)
                vm.addr(deployerPrivateKey) // Deployer acts as governance during setup
            ))
        );
        console.log("sUSX Vault deployed at:", susxProxy);
        
        // Step 3: Deploy Treasury Diamond with UUPS proxy
        console.log("\n=== STEP 3: Deploying Treasury Diamond ===");
        address treasuryProxy = Upgrades.deployUUPSProxy(
            "TreasuryDiamond.sol",
            abi.encodeCall(TreasuryDiamond.initialize, (
                vm.envAddress("USDC_ADDRESS"),
                usxProxy,
                susxProxy,
                vm.addr(deployerPrivateKey), // Deployer acts as governance during setup
                vm.addr(deployerPrivateKey), // Deployer acts as governance for warchest too
                vm.envAddress("ASSET_MANAGER_ADDRESS")
            ))
        );
        console.log("Treasury Diamond deployed at:", treasuryProxy);
        
        // Step 4: Deploy Facets
        console.log("\n=== STEP 4: Deploying Facets ===");
        ProfitAndLossReporterFacet profitLossFacet = new ProfitAndLossReporterFacet();
        InsuranceBufferFacet insuranceBufferFacet = new InsuranceBufferFacet();
        AssetManagerAllocatorFacet assetManagerFacet = new AssetManagerAllocatorFacet();
        
        console.log("Profit/Loss Facet:", address(profitLossFacet));
        console.log("Insurance Buffer Facet:", address(insuranceBufferFacet));
        console.log("Asset Manager Facet:", address(assetManagerFacet));
        
        // Step 5: Add facets to Treasury Diamond
        console.log("\n=== STEP 5: Adding Facets to Treasury Diamond ===");
        
        // Deployer acts as governance during initial setup
        vm.stopBroadcast();
        vm.startBroadcast(deployerPrivateKey);
        
        TreasuryDiamond treasury = TreasuryDiamond(payable(treasuryProxy));
        
        // Add Profit/Loss facet
        bytes4[] memory profitLossSelectors = new bytes4[](2);
        profitLossSelectors[0] = ProfitAndLossReporterFacet.makeAssetManagerReport.selector;
        profitLossSelectors[1] = ProfitAndLossReporterFacet.setSuccessFeeFraction.selector;
        treasury.addFacet(address(profitLossFacet), profitLossSelectors);
        console.log("Added Profit/Loss facet");
        
        // Add Insurance Buffer facet
        bytes4[] memory insuranceBufferSelectors = new bytes4[](5);
        insuranceBufferSelectors[0] = InsuranceBufferFacet._topUpBuffer.selector;
        insuranceBufferSelectors[1] = InsuranceBufferFacet._slashBuffer.selector;
        insuranceBufferSelectors[2] = InsuranceBufferFacet.bufferTarget.selector;
        insuranceBufferSelectors[3] = InsuranceBufferFacet.setBufferRenewalRate.selector;
        insuranceBufferSelectors[4] = InsuranceBufferFacet.setBufferTargetFraction.selector;
        treasury.addFacet(address(insuranceBufferFacet), insuranceBufferSelectors);
        console.log("Added Insurance Buffer facet");
        
        // Add Asset Manager facet
        bytes4[] memory assetManagerSelectors = new bytes4[](6);
        assetManagerSelectors[0] = AssetManagerAllocatorFacet.setAssetManager.selector;
        assetManagerSelectors[1] = AssetManagerAllocatorFacet.setMaxLeverage.selector;
        assetManagerSelectors[2] = AssetManagerAllocatorFacet.checkMaxLeverage.selector;
        assetManagerSelectors[3] = AssetManagerAllocatorFacet.netDeposits.selector;
        assetManagerSelectors[4] = AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector;
        assetManagerSelectors[5] = AssetManagerAllocatorFacet.transferUSDCFromAssetManager.selector;
        treasury.addFacet(address(assetManagerFacet), assetManagerSelectors);
        console.log("Added Asset Manager facet");
        
        vm.stopBroadcast();
        

        
        console.log("\n=== DEPLOYMENT COMPLETE! ===");
        console.log("USX Token:", usxProxy);
        console.log("sUSX Vault:", susxProxy);
        console.log("Treasury Diamond:", treasuryProxy);
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("=========================================");
        
        // Step 7: Upgrade USX and sUSX to include Treasury linking functionality
        console.log("\n=== STEP 7: Upgrading USX and sUSX with Treasury Linking ===");
        
        // Upgrade USX proxy to include setInitialTreasury function
        console.log("7.1. Upgrading USX proxy...");
        vm.startBroadcast(deployerPrivateKey);
        Options memory opts;
        opts.unsafeSkipStorageCheck = true;
        Upgrades.upgradeProxy(
            usxProxy,
            "USX.sol",
            "",  // No initialization data needed
            opts
        );
        console.log("USX upgraded successfully");
        vm.stopBroadcast();

        // Upgrade sUSX proxy to include setInitialTreasury function
        console.log("7.2. Upgrading sUSX proxy...");
        vm.startBroadcast(deployerPrivateKey);
        Upgrades.upgradeProxy(
            susxProxy,
            "sUSX.sol",
            "",  // No initialization data needed
            opts
        );
        console.log("sUSX upgraded successfully");
        vm.stopBroadcast();

        // Link USX to Treasury
        console.log("7.3. Linking USX to Treasury...");
        vm.startBroadcast(deployerPrivateKey);
        USX usx = USX(usxProxy);
        usx.setInitialTreasury(treasuryProxy);
        console.log("USX linked to Treasury successfully");
        vm.stopBroadcast();

        // Link sUSX to Treasury
        console.log("7.4. Linking sUSX to Treasury...");
        vm.startBroadcast(deployerPrivateKey);
        sUSX susx = sUSX(susxProxy);
        susx.setInitialTreasury(treasuryProxy);
        console.log("sUSX linked to Treasury successfully");
        vm.stopBroadcast();

        // Step 8: Transfer governance to target governance addresses
        console.log("\n=== STEP 8: Transferring Governance to Target Addresses ===");
        console.log("Transferring governance from deployer to:", governanceAddress);
        
        // Transfer Treasury governance
        vm.startBroadcast(deployerPrivateKey);
        TreasuryDiamond treasuryForTransfer = TreasuryDiamond(payable(treasuryProxy));
        treasuryForTransfer.setGovernance(governanceAddress);
        console.log("Treasury Diamond governance transferred successfully");
        
        // Transfer USX governance  
        USX usxForTransfer = USX(usxProxy);
        usxForTransfer.setGovernance(governanceAddress);
        console.log("USX governance transferred successfully");
        
        // Transfer sUSX governance
        sUSX susxForTransfer = sUSX(susxProxy);
        susxForTransfer.setGovernance(governanceAddress);
        console.log("sUSX governance transferred successfully");
        vm.stopBroadcast();

        console.log("\n=== COMPLETE SYSTEM DEPLOYMENT FINISHED! ===");
        console.log("SUCCESS: All contracts deployed and linked successfully");
        console.log("SUCCESS: All governance transferred to target addresses");
        console.log("SUCCESS: System is ready for use");
        
        console.log("\nDeployment verification can be done by checking contract state variables");
        console.log("and calling basic functions on the deployed contracts.");
    }
}
