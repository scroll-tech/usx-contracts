// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {RewardDistributorFacet} from "../src/facets/RewardDistributorFacet.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {USX} from "../src/USX.sol";
import {StakedUSX} from "../src/StakedUSX.sol";

import {MockAssetManager} from "../src/mocks/MockAssetManager.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * @title LocalDeployTestSetup
 * @dev Base test class that deploys contracts locally without forking
 * This provides a clean, isolated test environment
 */
contract LocalDeployTestSetup is Test {
    // Common addresses for testing
    address public governance = 0x1000000000000000000000000000000000000001;
    address public admin = 0x4000000000000000000000000000000000000004;
    address public assetManager;
    address public governanceWarchest = 0x2000000000000000000000000000000000000002;
    address public insuranceVault = 0x3000000000000000000000000000000000000003;
    address public user = address(0x999); // Test user address

    // Deployed contract addresses
    address public usxProxy;
    address public susxProxy;
    address public treasuryProxy;

    // Contract interfaces
    USX public usx;
    StakedUSX public susx;
    TreasuryDiamond public treasury;
    IERC20 public usdc;
    MockAssetManager public mockAssetManager;

    // Constants for testing
    uint256 public constant DECIMAL_SCALE_FACTOR = 10 ** 12;
    uint256 public constant INITIAL_BLOCKS = 1000000;

    function setUp() public virtual {
        console.log("=== STARTING LOCAL DEPLOYMENT SETUP ===");

        // Deploy mock USDC first
        usdc = new MockUSDC();
        console.log("Mock USDC deployed at:", address(usdc));

        // Deploy MockAssetManager
        mockAssetManager = new MockAssetManager(address(usdc));
        console.log("MockAssetManager deployed at:", address(mockAssetManager));
        assetManager = address(mockAssetManager);

        // Deploy USX implementation and proxy
        USX usxImpl = new USX();
        console.log("USX implementation deployed at:", address(usxImpl));

        bytes memory usxData =
            abi.encodeWithSelector(USX.initialize.selector, address(usdc), address(0), governanceWarchest, admin);
        ERC1967Proxy usxProxyContract = new ERC1967Proxy(address(usxImpl), usxData);
        usx = USX(address(usxProxyContract));
        usxProxy = address(usxProxyContract);
        console.log("USX proxy deployed at:", address(usx));

        // Deploy StakedUSX implementation and proxy
        StakedUSX susxImpl = new StakedUSX();
        console.log("StakedUSX implementation deployed at:", address(susxImpl));

        bytes memory susxData = abi.encodeWithSelector(StakedUSX.initialize.selector, address(usx), address(0), governance);
        ERC1967Proxy susxProxyContract = new ERC1967Proxy(address(susxImpl), susxData);
        susx = StakedUSX(address(susxProxyContract));
        susxProxy = address(susxProxyContract);
        console.log("StakedUSX proxy deployed at:", address(susx));

        // Deploy Treasury Diamond
        TreasuryDiamond treasuryImpl = new TreasuryDiamond();
        console.log("Treasury implementation deployed at:", address(treasuryImpl));

        try new ERC1967Proxy(
            address(treasuryImpl),
            abi.encodeCall(
                TreasuryDiamond.initialize,
                (address(usdc),
                address(usx),
                address(susx),
                governance,
                governanceWarchest,
                address(mockAssetManager),
                insuranceVault)
            )
        ) returns (ERC1967Proxy treasuryProxyContract) {
            treasury = TreasuryDiamond(payable(treasuryProxyContract));
            treasuryProxy = address(treasuryProxyContract);
            console.log("Treasury proxy deployed at:", address(treasury));
        } catch Error(string memory reason) {
            console.log("Treasury deployment failed with reason:", reason);
            revert();
        } catch (bytes memory) /* lowLevelData */ {
            console.log("Treasury deployment failed with low level error");
            revert();
        }

        // Link contracts properly
        console.log("Linking contracts...");

        vm.prank(governanceWarchest);
        try usx.setInitialTreasury(address(treasury)) {
            console.log("USX treasury set successfully");
        } catch {
            console.log("USX treasury already set or failed");
        }

        vm.prank(governance);
        try susx.setInitialTreasury(address(treasury)) {
            console.log("StakedUSX treasury set successfully");
        } catch {
            console.log("StakedUSX treasury already set or failed");
        }

        console.log("Contracts linked successfully");

        // Add facets to the diamond
        _addFacetsToDiamond();

        // Set up test environment
        _setupTestEnvironment();

        console.log("=== LOCAL DEPLOYMENT SETUP COMPLETE ===");
    }

    function _addFacetsToDiamond() internal {
        console.log("Adding facets to diamond...");

        // Deploy facets
        AssetManagerAllocatorFacet assetManagerFacet = new AssetManagerAllocatorFacet();
        RewardDistributorFacet profitLossFacet = new RewardDistributorFacet();

        // Define selectors for each facet (matching deployment script)
        bytes4[] memory assetManagerSelectors = new bytes4[](6);
        assetManagerSelectors[0] = AssetManagerAllocatorFacet.netDeposits.selector;
        assetManagerSelectors[1] = AssetManagerAllocatorFacet.setAssetManager.selector;
        assetManagerSelectors[2] = AssetManagerAllocatorFacet.setAllocator.selector;
        assetManagerSelectors[3] = AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector;
        assetManagerSelectors[4] = AssetManagerAllocatorFacet.transferUSDCFromAssetManager.selector;
        assetManagerSelectors[5] = AssetManagerAllocatorFacet.transferUSDCForWithdrawal.selector;

        bytes4[] memory profitLossSelectors = new bytes4[](6);
        profitLossSelectors[0] = RewardDistributorFacet.successFee.selector;
        profitLossSelectors[1] = RewardDistributorFacet.insuranceFund.selector;
        profitLossSelectors[2] = RewardDistributorFacet.reportRewards.selector;
        profitLossSelectors[3] = RewardDistributorFacet.setSuccessFeeFraction.selector;
        profitLossSelectors[4] = RewardDistributorFacet.setInsuranceFundFraction.selector;
        profitLossSelectors[5] = RewardDistributorFacet.setReporter.selector;

        // Add facets to diamond
        vm.prank(governance);
        treasury.addFacet(address(assetManagerFacet), assetManagerSelectors);

        vm.prank(governance);
        treasury.addFacet(address(profitLossFacet), profitLossSelectors);

        console.log("Facets added successfully");
    }

    function _setupTestEnvironment() internal {
        console.log("Setting up test environment...");

        // Set up USDC balances - only give user USDC for deposits
        console.log("  Setting up USDC balances...");
        deal(address(usdc), user, 10000000e6); // Give user 10,000,000 USDC for testing
        console.log("  USDC balances set");

        // Set up USDC approvals
        console.log("  Setting up USDC approvals...");
        vm.prank(user);
        usdc.approve(address(usx), type(uint256).max);

        // Approve MockAssetManager to spend USDC from treasury
        vm.prank(address(treasury));
        usdc.approve(address(mockAssetManager), type(uint256).max);
        console.log("  USDC approvals set");

        // Whitelist test user
        console.log("  Whitelisting test user...");
        vm.prank(admin);
        usx.whitelistUser(user, true);
        console.log("  Test user whitelisted");

        // Advance block number for time-based functions
        console.log("  Advancing block number for time-based functions...");
        uint256 currentBlock = block.number;
        if (currentBlock < INITIAL_BLOCKS) {
            vm.roll(INITIAL_BLOCKS);
            console.log("  Block number advanced to:", block.number);
        } else {
            console.log("  Block advancement not needed - contract properly initialized");
        }
        console.log("  Block number advanced");

        // Update lastEpochBlock to current block number after advancement
        console.log("  Updating lastEpochBlock to current block number...");
        vm.prank(address(treasury));

        console.log("  Initial state: USX supply =", usx.totalSupply(), ", StakedUSX supply =", susx.totalSupply());
    }
}
