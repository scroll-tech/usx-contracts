// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {USX} from "../src/USX.sol";
import {sUSX} from "../src/sUSX.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {ProfitAndLossReporterFacet} from "../src/facets/ProfitAndLossReporterFacet.sol";
import {InsuranceBufferFacet} from "../src/facets/InsuranceBufferFacet.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployScroll
 * @dev Enhanced deployment script for Scroll networks using hybrid approach:
 * - OpenZeppelin tools for basic proxy deployment and security
 * - Custom logic for diamond-specific features and linking
 * - Comprehensive verification and testing
 * - Supports local fork, testnet, and mainnet deployments
 */
contract DeployScroll is Script {
    // Configuration from environment variables
    address public usdcAddress;
    address public governance;
    address public governanceWarchest;
    address public assetManager;
    address public admin;
    string public deploymentTarget;
    string public rpcUrl;

    // Test addresses for fork deployment
    address public deployer;

    // Deployed contract addresses
    address public usxProxy;
    address public susxProxy;
    address public treasuryProxy;

    // Facet addresses
    address public profitLossFacet;
    address public insuranceBufferFacet;
    address public assetManagerFacet;

    function setUp() public {
        // Load configuration from environment variables
        // For testing, use governance address as deployer to avoid access control issues
        deployer = vm.envAddress("GOVERNANCE_ADDRESS");
        usdcAddress = vm.envAddress("USDC_ADDRESS");
        governance = vm.envAddress("GOVERNANCE_ADDRESS");
        governanceWarchest = vm.envAddress("GOVERNANCE_WARCHEST_ADDRESS");
        assetManager = vm.envAddress("ASSET_MANAGER_ADDRESS");
        admin = vm.envAddress("ADMIN_ADDRESS");
        deploymentTarget = vm.envString("DEPLOYMENT_TARGET");

        // Debug logging
        console.log("Environment variables read:");
        console.log("GOVERNANCE_ADDRESS:", governance);
        console.log("GOVERNANCE_WARCHEST_ADDRESS:", governanceWarchest);
        console.log("ASSET_MANAGER_ADDRESS:", assetManager);
        console.log("ADMIN_ADDRESS:", admin);
        console.log("USDC_ADDRESS:", usdcAddress);
        console.log("DEPLOYMENT_TARGET:", deploymentTarget);

        // Set RPC URL based on deployment target
        if (keccak256(abi.encodePacked(deploymentTarget)) == keccak256(abi.encodePacked("mainnet"))) {
            rpcUrl = vm.envString("SCROLL_MAINNET_RPC");
        } else if (keccak256(abi.encodePacked(deploymentTarget)) == keccak256(abi.encodePacked("sepolia"))) {
            rpcUrl = vm.envString("SCROLL_SEPOLIA_RPC");
        } else {
            // Default to local fork for development
            rpcUrl = vm.envString("SCROLL_MAINNET_RPC");
        }

        // For local fork, create the fork automatically
        if (keccak256(abi.encodePacked(deploymentTarget)) == keccak256(abi.encodePacked("local"))) {
            console.log("Creating local fork from Scroll mainnet...");
            vm.createSelectFork(rpcUrl);
        }

        // Ensure we're on the correct network
        if (keccak256(abi.encodePacked(deploymentTarget)) == keccak256(abi.encodePacked("mainnet"))) {
            require(block.chainid == 534352, "Must be on Scroll mainnet");
        } else if (keccak256(abi.encodePacked(deploymentTarget)) == keccak256(abi.encodePacked("sepolia"))) {
            require(block.chainid == 534351, "Must be on Scroll Sepolia testnet");
        }
        // Note: local fork doesn't require chain ID validation

        console.log("=== DEPLOYING TO", deploymentTarget, "===");
        console.log("Deployer:", deployer);
        console.log("Governance:", governance);
        console.log("Asset Manager:", assetManager);
        console.log("Chain ID:", block.chainid);
        console.log("RPC URL:", rpcUrl);
        console.log("=========================================");
    }

    function run() external {
        setUp();

        // Step 1: Deploy core contracts using OpenZeppelin tools
        deployCoreContracts();

        // Step 2: Deploy and configure diamond with custom logic
        deployDiamondWithFacets();

        // Step 3: Link contracts using OpenZeppelin security features
        linkContracts();

        // Step 4: Comprehensive verification
        verifyDeployment();

        // Step 5: Test basic functionality
        testBasicFunctionality();

        console.log("\n=== DEPLOYMENT COMPLETE! ===");
        console.log("USX Token:", usxProxy);
        console.log("sUSX Vault:", susxProxy);
        console.log("Treasury Diamond:", treasuryProxy);
        console.log("=========================================");
    }

    function deployCoreContracts() internal {
        console.log("\n=== STEP 1: Deploying Core Contracts with OpenZeppelin ===");

        vm.startBroadcast(deployer);

        // Deploy USX Token with UUPS proxy using OpenZeppelin
        console.log("1.1. Deploying USX Token...");
        bytes memory usxInitData = abi.encodeCall(
            USX.initialize,
            (
                usdcAddress,
                address(0), // Treasury address (will be set later)
                governanceWarchest,
                admin
            )
        );

        // Deploy implementation first
        USX usxImpl = new USX();

        // Deploy proxy
        usxProxy = address(new ERC1967Proxy(address(usxImpl), usxInitData));
        console.log("USX Token deployed at:", usxProxy);

        // Deploy sUSX Vault with UUPS proxy using OpenZeppelin
        console.log("1.2. Deploying sUSX Vault...");
        bytes memory susxInitData = abi.encodeCall(
            sUSX.initialize,
            (
                address(usxProxy),
                address(0), // Treasury address (will be set later)
                governance
            )
        );

        // Deploy implementation first
        sUSX susxImpl = new sUSX();

        // Deploy proxy
        susxProxy = address(new ERC1967Proxy(address(susxImpl), susxInitData));
        console.log("sUSX Vault deployed at:", susxProxy);

        vm.stopBroadcast();
    }

    function deployDiamondWithFacets() internal {
        console.log("\n=== STEP 2: Deploying Diamond with Custom Logic ===");

        vm.startBroadcast(deployer);

        // Deploy Treasury Diamond implementation
        console.log("2.1. Deploying Treasury Diamond...");
        TreasuryDiamond treasuryImpl = new TreasuryDiamond();

        // Deploy Treasury Diamond proxy
        console.log("2.2. Deploying Treasury Proxy...");
        bytes memory treasuryInitData = abi.encodeCall(
            TreasuryDiamond.initialize,
            (usdcAddress, address(usxProxy), address(susxProxy), governance, governanceWarchest, assetManager)
        );

        treasuryProxy = address(new ERC1967Proxy(address(treasuryImpl), treasuryInitData));
        console.log("Treasury Diamond deployed at:", treasuryProxy);

        // Deploy Facets
        console.log("2.3. Deploying Facets...");
        profitLossFacet = address(new ProfitAndLossReporterFacet());
        insuranceBufferFacet = address(new InsuranceBufferFacet());
        assetManagerFacet = address(new AssetManagerAllocatorFacet());

        console.log("Profit/Loss Facet:", profitLossFacet);
        console.log("Insurance Buffer Facet:", insuranceBufferFacet);
        console.log("Asset Manager Facet:", assetManagerFacet);

        vm.stopBroadcast();
    }

    function linkContracts() internal {
        console.log("\n=== STEP 3: Linking Contracts with OpenZeppelin Security ===");

        // Link USX to Treasury
        console.log("3.1. Linking USX to Treasury...");
        vm.startBroadcast(governanceWarchest);
        USX usx = USX(usxProxy);
        usx.setInitialTreasury(treasuryProxy);
        console.log("USX linked to Treasury");
        vm.stopBroadcast();

        // Link sUSX to Treasury
        console.log("3.2. Linking sUSX to Treasury...");
        vm.startBroadcast(governance);
        sUSX susx = sUSX(susxProxy);
        susx.setInitialTreasury(treasuryProxy);
        console.log("sUSX linked to Treasury");
        vm.stopBroadcast();

        // Add Facets to Diamond
        console.log("3.3. Adding Facets to Diamond...");

        // Create local treasury interface
        TreasuryDiamond treasury = TreasuryDiamond(payable(treasuryProxy));

        // Add AssetManagerAllocatorFacet
        console.log("3.3.1. Adding AssetManagerAllocatorFacet...");
        bytes4[] memory assetManagerSelectors = new bytes4[](7);
        assetManagerSelectors[0] = AssetManagerAllocatorFacet.maxLeverage.selector;
        assetManagerSelectors[1] = AssetManagerAllocatorFacet.checkMaxLeverage.selector;
        assetManagerSelectors[2] = AssetManagerAllocatorFacet.netDeposits.selector;
        assetManagerSelectors[3] = AssetManagerAllocatorFacet.setAssetManager.selector;
        assetManagerSelectors[4] = AssetManagerAllocatorFacet.setMaxLeverageFraction.selector;
        assetManagerSelectors[5] = AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector;
        assetManagerSelectors[6] = AssetManagerAllocatorFacet.transferUSDCFromAssetManager.selector;

        vm.prank(governance);
        treasury.addFacet(assetManagerFacet, assetManagerSelectors);
        console.log("AssetManagerAllocatorFacet added");

        // Add InsuranceBufferFacet
        console.log("3.3.2. Adding InsuranceBufferFacet...");
        bytes4[] memory insuranceBufferSelectors = new bytes4[](5);
        insuranceBufferSelectors[0] = InsuranceBufferFacet.bufferTarget.selector;
        insuranceBufferSelectors[1] = InsuranceBufferFacet.topUpBuffer.selector;
        insuranceBufferSelectors[2] = InsuranceBufferFacet.slashBuffer.selector;
        insuranceBufferSelectors[3] = InsuranceBufferFacet.setBufferTargetFraction.selector;
        insuranceBufferSelectors[4] = InsuranceBufferFacet.setBufferRenewalRate.selector;

        vm.prank(governance);
        treasury.addFacet(insuranceBufferFacet, insuranceBufferSelectors);
        console.log("InsuranceBufferFacet added");

        // Add ProfitAndLossReporterFacet
        console.log("3.3.3. Adding ProfitAndLossReporterFacet...");
        bytes4[] memory profitLossSelectors = new bytes4[](6);
        profitLossSelectors[0] = ProfitAndLossReporterFacet.successFee.selector;
        profitLossSelectors[1] = ProfitAndLossReporterFacet.profitLatestEpoch.selector;
        profitLossSelectors[2] = ProfitAndLossReporterFacet.profitPerBlock.selector;
        profitLossSelectors[3] = ProfitAndLossReporterFacet.substractProfitLatestEpoch.selector;
        profitLossSelectors[4] = ProfitAndLossReporterFacet.assetManagerReport.selector;
        profitLossSelectors[5] = ProfitAndLossReporterFacet.setSuccessFeeFraction.selector;

        vm.prank(governance);
        treasury.addFacet(profitLossFacet, profitLossSelectors);
        console.log("ProfitAndLossReporterFacet added");

        // Note: vm.stopBroadcast() is not needed here since we're not in a broadcast context
    }

    function verifyDeployment() internal {
        console.log("\n=== STEP 4: Comprehensive Verification ===");

        // Verify USX
        USX usx = USX(usxProxy);
        require(
            keccak256(abi.encodePacked(usx.name())) == keccak256(abi.encodePacked("USX Token")),
            "USX name verification failed"
        );
        require(
            keccak256(abi.encodePacked(usx.symbol())) == keccak256(abi.encodePacked("USX")),
            "USX symbol verification failed"
        );
        require(usx.decimals() == 18, "USX decimals verification failed");
        require(address(usx.USDC()) == usdcAddress, "USX USDC address verification failed");
        require(address(usx.treasury()) == treasuryProxy, "USX treasury verification failed");
        console.log("USX verification passed");

        // Verify sUSX
        sUSX susx = sUSX(susxProxy);
        require(
            keccak256(abi.encodePacked(susx.name())) == keccak256(abi.encodePacked("sUSX Token")),
            "sUSX name verification failed"
        );
        require(
            keccak256(abi.encodePacked(susx.symbol())) == keccak256(abi.encodePacked("sUSX")),
            "sUSX symbol verification failed"
        );
        require(susx.decimals() == 18, "sUSX decimals verification failed");
        require(address(susx.USX()) == usxProxy, "sUSX USX address verification failed");
        require(address(susx.treasury()) == treasuryProxy, "sUSX treasury verification failed");
        console.log("sUSX verification passed");

        // Verify Treasury
        TreasuryDiamond treasury = TreasuryDiamond(payable(treasuryProxy));
        require(address(treasury.USDC()) == usdcAddress, "Treasury USDC address verification failed");
        require(address(treasury.USX()) == usxProxy, "Treasury USX address verification failed");
        require(address(treasury.sUSX()) == susxProxy, "Treasury sUSX address verification failed");
        require(treasury.governance() == governance, "Treasury governance verification failed");
        require(treasury.assetManager() == assetManager, "Treasury asset manager verification failed");
        console.log("Treasury verification passed");

        // Verify Facet Accessibility
        (bool success,) = treasuryProxy.call(abi.encodeWithSelector(AssetManagerAllocatorFacet.maxLeverage.selector));
        require(success, "AssetManagerAllocatorFacet not accessible");

        (success,) = treasuryProxy.call(abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector));
        require(success, "InsuranceBufferFacet not accessible");

        (success,) = treasuryProxy.call(abi.encodeWithSelector(ProfitAndLossReporterFacet.successFee.selector, 1000000));
        require(success, "ProfitAndLossReporterFacet not accessible");

        console.log("Facet accessibility verification passed");
    }

    function testBasicFunctionality() internal {
        console.log("\n=== STEP 5: Testing Basic Functionality ===");

        // Test USX basic functionality
        console.log("5.1. Testing USX basic functionality...");
        USX usx = USX(usxProxy);
        require(usx.totalSupply() == 0, "USX initial supply should be 0");
        console.log("USX basic functionality verified");

        // Test sUSX basic functionality
        console.log("5.2. Testing sUSX basic functionality...");
        sUSX susx = sUSX(susxProxy);
        require(susx.totalSupply() == 0, "sUSX initial supply should be 0");
        console.log("sUSX basic functionality verified");

        // Test Treasury basic functionality
        console.log("5.3. Testing Treasury basic functionality...");
        TreasuryDiamond treasury = TreasuryDiamond(payable(treasuryProxy));
        require(treasury.maxLeverageFraction() == 100000, "Treasury maxLeverageFraction should be 100000");
        require(treasury.successFeeFraction() == 50000, "Treasury successFeeFraction should be 50000");
        require(treasury.bufferTargetFraction() == 50000, "Treasury bufferTargetFraction should be 50000");
        console.log("Treasury basic functionality verified");

        // Test facet functionality through diamond
        console.log("5.4. Testing facet functionality through diamond...");
        (bool success, bytes memory data) =
            treasuryProxy.call(abi.encodeWithSelector(AssetManagerAllocatorFacet.maxLeverage.selector));
        require(success, "maxLeverage call failed");
        uint256 maxLeverage = abi.decode(data, (uint256));
        require(maxLeverage == 0, "maxLeverage should be 0 for empty vault");

        (success, data) = treasuryProxy.call(abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector));
        require(success, "bufferTarget call failed");
        uint256 bufferTarget = abi.decode(data, (uint256));
        require(bufferTarget == 0, "bufferTarget should be 0 for empty vault");

        (success, data) =
            treasuryProxy.call(abi.encodeWithSelector(ProfitAndLossReporterFacet.successFee.selector, 1000000));
        require(success, "successFee call failed");
        uint256 successFee = abi.decode(data, (uint256));
        require(successFee == 500000, "successFee should be 500000 (5% of 1000000)");

        console.log("Facet functionality verified");
    }
}
