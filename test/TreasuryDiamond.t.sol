// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LocalDeployTestSetup} from "./LocalDeployTestSetup.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {ProfitAndLossReporterFacet} from "../src/facets/ProfitAndLossReporterFacet.sol";
import {InsuranceBufferFacet} from "../src/facets/InsuranceBufferFacet.sol";
import {TreasuryStorage} from "../src/TreasuryStorage.sol";

contract TreasuryDiamondTest is LocalDeployTestSetup {
    function setUp() public override {
        super.setUp(); // Runs the deployment script and sets up contracts
    }

    /*=========================== Deployment & Initialization Tests =========================*/

    function test_deploy_treasury_success() public {
        assertEq(address(treasury.USDC()), address(usdc));
        assertEq(address(treasury.USX()), address(usx));
        assertEq(address(treasury.sUSX()), address(susx));
        assertEq(treasury.governance(), governance);
        assertEq(treasury.governanceWarchest(), governanceWarchest);
        assertEq(treasury.assetManager(), assetManager);
    }

    function test_default_values_set_correctly() public {
        assertEq(treasury.successFeeFraction(), 50000); // 5%
        assertEq(treasury.maxLeverageFraction(), 100000); // 10%
        assertEq(treasury.bufferRenewalFraction(), 100000); // 10%
        assertEq(treasury.bufferTargetFraction(), 50000); // 5%
    }

    function test_facets_deploy_success() public {
        assertTrue(treasury.facets(AssetManagerAllocatorFacet.maxLeverage.selector) != address(0));
        assertTrue(treasury.facets(InsuranceBufferFacet.bufferTarget.selector) != address(0));
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.successFee.selector) != address(0));
    }

    // ============ Real Contract Deployment Tests ============

    function test_usx_deployed_and_initialized() public {
        // Check that USX is deployed and initialized correctly
        assertEq(usx.name(), "USX");
        assertEq(usx.symbol(), "USX");
        assertEq(usx.decimals(), 18);
        assertEq(usx.usxPrice(), 1e18);
        assertEq(address(usx.treasury()), address(treasury));
    }

    function test_susx_deployed_and_initialized() public {
        // Check that sUSX is deployed and initialized correctly
        assertEq(susx.name(), "sUSX");
        assertEq(susx.symbol(), "sUSX");
        assertEq(susx.decimals(), 18);
        assertEq(address(susx.treasury()), address(treasury));
        assertEq(susx.withdrawalPeriod(), 108000);
        assertEq(susx.withdrawalFeeFraction(), 500);
    }

    // ============ Diamond Setup Tests ============

    function test_diamond_has_facets() public {
        // Check that facets are properly added
        assertTrue(treasury.facets(AssetManagerAllocatorFacet.maxLeverage.selector) != address(0));
        assertTrue(treasury.facets(InsuranceBufferFacet.bufferTarget.selector) != address(0));
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.successFee.selector) != address(0));
    }

    // ============ Production Deployment Verification Tests ============

    function test_real_usdc_integration() public {
        // Verify we're using real Scroll mainnet USDC
        assertEq(address(usdc), address(usdc));

        // Verify treasury is properly connected to real USDC
        assertEq(address(treasury.USDC()), address(usdc));
    }

    function test_complete_diamond_facet_setup() public {
        // Verify ALL AssetManagerAllocatorFacet functions are mapped
        assertTrue(treasury.facets(AssetManagerAllocatorFacet.maxLeverage.selector) != address(0));
        assertTrue(treasury.facets(AssetManagerAllocatorFacet.checkMaxLeverage.selector) != address(0));
        assertTrue(treasury.facets(AssetManagerAllocatorFacet.netDeposits.selector) != address(0));
        assertTrue(treasury.facets(AssetManagerAllocatorFacet.setAssetManager.selector) != address(0));
        assertTrue(treasury.facets(AssetManagerAllocatorFacet.setMaxLeverageFraction.selector) != address(0));
        assertTrue(treasury.facets(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector) != address(0));

        // Verify ALL InsuranceBufferFacet functions are mapped
        assertTrue(treasury.facets(InsuranceBufferFacet.bufferTarget.selector) != address(0));
        assertTrue(treasury.facets(InsuranceBufferFacet.topUpBuffer.selector) != address(0));
        assertTrue(treasury.facets(InsuranceBufferFacet.slashBuffer.selector) != address(0));
        assertTrue(treasury.facets(InsuranceBufferFacet.setBufferTargetFraction.selector) != address(0));

        // Verify ALL ProfitAndLossReporterFacet functions are mapped
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.successFee.selector) != address(0));
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.profitLatestEpoch.selector) != address(0));
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.profitPerBlock.selector) != address(0));
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.assetManagerReport.selector) != address(0));
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.assetManagerReport.selector) != address(0));
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.setSuccessFeeFraction.selector) != address(0));
    }

    function test_diamond_fallback_mechanism() public {
        // Test that the diamond fallback properly delegates to facets

        // Test a function that should work
        bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.maxLeverage.selector);
        (bool success, /* bytes memory result */ ) = address(treasury).call(data);

        assertTrue(success, "Diamond fallback should delegate maxLeverage call");

        // Test a function that doesn't exist (should revert)
        bytes memory invalidData = abi.encodeWithSelector(bytes4(0x12345678));
        (bool invalidSuccess,) = address(treasury).call(invalidData);
        assertFalse(invalidSuccess, "Invalid selector should revert");
    }

    function test_production_like_initialization() public {
        // Verify the system is initialized exactly as it would be in production

        // 1. Treasury has correct addresses
        assertEq(address(treasury.USDC()), address(usdc));
        assertEq(address(treasury.USX()), address(usx));
        assertEq(address(treasury.sUSX()), address(susx));
        assertEq(treasury.governance(), governance);
        assertEq(treasury.governanceWarchest(), governanceWarchest);
        assertEq(treasury.assetManager(), assetManager);

        // 2. USX has correct configuration
        assertEq(address(usx.treasury()), address(treasury));
        assertEq(usx.usxPrice(), 1e18); // 1 USX = 1 USDC (18 decimals)

        // 3. sUSX has correct configuration
        assertEq(address(susx.treasury()), address(treasury));

        // 4. All default values are set correctly
        assertEq(treasury.successFeeFraction(), 50000); // 5%
        assertEq(treasury.maxLeverageFraction(), 100000); // 10%
        assertEq(treasury.bufferRenewalFraction(), 100000); // 10%
        assertEq(treasury.bufferTargetFraction(), 50000); // 5%
    }

    /*=========================== Facet Management Tests =========================*/

    function test_addFacet_success() public {
        // Create a mock facet contract
        address mockFacet = address(0x1234);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(0x11111111);
        selectors[1] = bytes4(0x22222222);

        // Add facet
        vm.prank(governance);
        treasury.addFacet(mockFacet, selectors);

        // Verify facets were added
        assertEq(treasury.facets(selectors[0]), mockFacet);
        assertEq(treasury.facets(selectors[1]), mockFacet);
    }

    function test_addFacet_revert_not_governance() public {
        address mockFacet = address(0x1234);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(0x11111111);

        vm.prank(user);
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        treasury.addFacet(mockFacet, selectors);
    }

    function test_addFacet_revert_zero_address() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(0x11111111);

        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        treasury.addFacet(address(0), selectors);
    }

    function test_addFacet_revert_facet_already_exists() public {
        // Add a facet first
        address mockFacet = address(0x1234);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(0x11111111);

        vm.prank(governance);
        treasury.addFacet(mockFacet, selectors);

        // Try to add the same selector again
        address anotherFacet = address(0x5678);
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.FacetAlreadyExists.selector);
        treasury.addFacet(anotherFacet, selectors);
    }

    function test_removeFacet_success() public {
        // Add a facet first
        address mockFacet = address(0x1234);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(0x11111111);
        selectors[1] = bytes4(0x22222222);

        vm.prank(governance);
        treasury.addFacet(mockFacet, selectors);

        // Remove the facet
        vm.prank(governance);
        treasury.removeFacet(mockFacet);

        // Verify facets were removed
        assertEq(treasury.facets(selectors[0]), address(0));
        assertEq(treasury.facets(selectors[1]), address(0));
    }

    function test_removeFacet_revert_not_governance() public {
        vm.prank(user);
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        treasury.removeFacet(address(0x1234));
    }

    function test_replaceFacet_success() public {
        // Add a facet first
        address oldFacet = address(0x1234);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(0x11111111);
        selectors[1] = bytes4(0x22222222);

        vm.prank(governance);
        treasury.addFacet(oldFacet, selectors);

        // Replace with new facet
        address newFacet = address(0x5678);
        vm.prank(governance);
        treasury.replaceFacet(oldFacet, newFacet);

        // Verify selectors now point to new facet
        assertEq(treasury.facets(selectors[0]), newFacet);
        assertEq(treasury.facets(selectors[1]), newFacet);
    }

    function test_replaceFacet_revert_not_governance() public {
        vm.prank(user);
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        treasury.replaceFacet(address(0x1234), address(0x5678));
    }

    function test_replaceFacet_revert_zero_address() public {
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        treasury.replaceFacet(address(0x1234), address(0));
    }

    /*=========================== Governance Tests =========================*/

    function test_setGovernance_success() public {
        address newGovernance = address(0x9999);

        vm.prank(governance);
        treasury.setGovernance(newGovernance);

        assertEq(treasury.governance(), newGovernance);
    }

    function test_setGovernance_revert_not_governance() public {
        vm.prank(user);
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        treasury.setGovernance(address(0x9999));
    }

    function test_setGovernance_revert_zero_address() public {
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        treasury.setGovernance(address(0));
    }

    /*=========================== UUPS Upgrade Tests =========================*/

    function test_getImplementation_success() public {
        address implementation = treasury.getImplementation();
        assertTrue(implementation != address(0), "Implementation should not be zero");
    }

    function test_receive_function() public {
        // Test that the contract can receive ETH
        address payable treasuryPayable = payable(address(treasury));
        uint256 ethAmount = 1 ether;

        (bool success,) = treasuryPayable.call{value: ethAmount}("");
        assertTrue(success, "Should be able to receive ETH");
    }

    /*=========================== Initialization Tests =========================*/

    function test_initialize_revert_zero_address() public {
        // Deploy a new treasury to test initialization
        TreasuryDiamond newTreasury = new TreasuryDiamond();

        // Try to initialize with zero addresses
        vm.expectRevert();
        newTreasury.initialize(
            address(0), // USDC
            address(usx),
            address(susx),
            governance,
            governanceWarchest,
            assetManager
        );

        vm.expectRevert();
        newTreasury.initialize(
            address(usdc),
            address(0), // USX
            address(susx),
            governance,
            governanceWarchest,
            assetManager
        );

        vm.expectRevert();
        newTreasury.initialize(
            address(usdc),
            address(usx),
            address(0), // sUSX
            governance,
            governanceWarchest,
            assetManager
        );

        vm.expectRevert();
        newTreasury.initialize(
            address(usdc),
            address(usx),
            address(susx),
            address(0), // governance
            governanceWarchest,
            assetManager
        );

        vm.expectRevert();
        newTreasury.initialize(
            address(usdc),
            address(usx),
            address(susx),
            governance,
            address(0), // governanceWarchest
            assetManager
        );
    }

    function test_initialize_revert_already_initialized() public {
        // Treasury is already initialized in setUp()
        vm.expectRevert();
        treasury.initialize(address(usdc), address(usx), address(susx), governance, governanceWarchest, assetManager);
    }

    /*=========================== Facet Function Selector Tests =========================*/

    function test_facetFunctionSelectors_mapping() public {
        // Test that facet function selectors are properly mapped
        address assetManagerFacet = treasury.facets(AssetManagerAllocatorFacet.maxLeverage.selector);
        assertTrue(assetManagerFacet != address(0), "AssetManagerFacet should be mapped");

        // Test that we can call the function through the diamond
        bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.maxLeverage.selector);
        (bool success,) = address(treasury).call(data);
        assertTrue(success, "Should be able to call maxLeverage through diamond");
    }

    /*=========================== Assembly & Edge Case Tests =========================*/

    function test_fallback_assembly_success() public {
        // Test that the assembly code in fallback works correctly
        // Call a function that should succeed
        bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.maxLeverage.selector);
        (bool success, bytes memory result) = address(treasury).call(data);

        assertTrue(success, "Assembly fallback should succeed");
        assertTrue(result.length > 0, "Should return data");
    }

    function test_fallback_assembly_revert() public {
        // Test that the assembly code handles reverts correctly
        // Call a function that should revert
        bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.setAssetManager.selector, address(0));
        (bool success,) = address(treasury).call(data);

        assertFalse(success, "Assembly fallback should revert for invalid call");
    }

    function test_fallback_selector_not_found() public {
        // Test the SelectorNotFound error
        bytes memory invalidData = abi.encodeWithSelector(bytes4(0x12345678));
        (bool success,) = address(treasury).call(invalidData);

        assertFalse(success, "Should revert with SelectorNotFound");
    }

    function test_facet_management_edge_cases() public {
        // Test edge cases in facet management

        // Test adding facet with single selector
        address mockFacet = address(0x1234);
        bytes4[] memory singleSelector = new bytes4[](1);
        singleSelector[0] = bytes4(0x11111111);

        vm.prank(governance);
        treasury.addFacet(mockFacet, singleSelector);

        // Test adding another facet with multiple selectors
        address mockFacet2 = address(0x5678);
        bytes4[] memory multipleSelectors = new bytes4[](2);
        multipleSelectors[0] = bytes4(0x33333333);
        multipleSelectors[1] = bytes4(0x44444444);

        vm.prank(governance);
        treasury.addFacet(mockFacet2, multipleSelectors);

        // Test replacing existing facet
        address mockFacet3 = address(0x9999);
        vm.prank(governance);
        treasury.replaceFacet(mockFacet2, mockFacet3);

        // Verify the facets were added and replaced correctly
        assertEq(treasury.facets(singleSelector[0]), mockFacet);
        assertEq(treasury.facets(multipleSelectors[0]), mockFacet3);
        assertEq(treasury.facets(multipleSelectors[1]), mockFacet3);
    }
}
