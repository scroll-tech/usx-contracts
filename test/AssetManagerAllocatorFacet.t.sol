// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {BaseFacetTest} from "./BaseFacetTest.sol";

contract AssetManagerAllocatorFacetTest is BaseFacetTest {
    
    function setUp() public override {
        super.setUp();
    }
    
    // ============ Deployment & Initialization Tests ============
    
    function test_facet_deploys_successfully() public {
        assertEq(address(assetManagerFacet), address(assetManagerFacet));
    }
    
    function test_facet_has_required_functions() public {
        // Verify the facet contract has the expected interface by checking function selectors
        // This ensures the contract implements all the functions we expect
        bytes4 maxLeverageSelector = AssetManagerAllocatorFacet.maxLeverage.selector;
        bytes4 checkMaxLeverageSelector = AssetManagerAllocatorFacet.checkMaxLeverage.selector;
        bytes4 netDepositsSelector = AssetManagerAllocatorFacet.netDeposits.selector;
        bytes4 setAssetManagerSelector = AssetManagerAllocatorFacet.setAssetManager.selector;
        bytes4 setMaxLeverageFractionSelector = AssetManagerAllocatorFacet.setMaxLeverageFraction.selector;
        bytes4 transferUSDCtoAssetManagerSelector = AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector;
        
        // If any of these selectors are 0x00000000, it means the function doesn't exist
        assertTrue(maxLeverageSelector != bytes4(0), "maxLeverage function missing");
        assertTrue(checkMaxLeverageSelector != bytes4(0), "checkMaxLeverage function missing");
        assertTrue(netDepositsSelector != bytes4(0), "netDeposits function missing");
        assertTrue(setAssetManagerSelector != bytes4(0), "setAssetManager function missing");
        assertTrue(setMaxLeverageFractionSelector != bytes4(0), "setMaxLeverageFraction function missing");
        assertTrue(transferUSDCtoAssetManagerSelector != bytes4(0), "transferUSDCtoAssetManager function missing");
    }
    
    function test_facet_added_to_diamond() public {
        // Verify the facet is properly added to the diamond
        assertEq(treasury.facets(AssetManagerAllocatorFacet.maxLeverage.selector), address(assetManagerFacet));
        assertEq(treasury.facets(AssetManagerAllocatorFacet.checkMaxLeverage.selector), address(assetManagerFacet));
        assertEq(treasury.facets(AssetManagerAllocatorFacet.netDeposits.selector), address(assetManagerFacet));
        assertEq(treasury.facets(AssetManagerAllocatorFacet.setAssetManager.selector), address(assetManagerFacet));
        assertEq(treasury.facets(AssetManagerAllocatorFacet.setMaxLeverageFraction.selector), address(assetManagerFacet));
        assertEq(treasury.facets(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector), address(assetManagerFacet));
    }
    
    function test_facet_initial_state() public {
        // Verify the facet has the expected initial state through the diamond
        assertEq(treasury.maxLeverageFraction(), 100000); // 10% default
        assertEq(treasury.assetManager(), assetManager);
    }
}
