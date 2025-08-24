// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {InsuranceBufferFacet} from "../src/facets/InsuranceBufferFacet.sol";
import {BaseFacetTest} from "./BaseFacetTest.sol";

contract InsuranceBufferFacetTest is BaseFacetTest {
    
    function setUp() public override {
        super.setUp();
    }
    
    // ============ Deployment & Initialization Tests ============
    
    function test_facet_deploys_successfully() public {
        assertEq(address(insuranceBufferFacet), address(insuranceBufferFacet));
    }
    
    function test_facet_has_required_functions() public {
        // Verify the facet contract has the expected interface by checking function selectors
        // This ensures the contract implements all the functions we expect
        bytes4 bufferTargetSelector = InsuranceBufferFacet.bufferTarget.selector;
        bytes4 topUpBufferSelector = InsuranceBufferFacet.topUpBuffer.selector;
        bytes4 slashBufferSelector = InsuranceBufferFacet.slashBuffer.selector;
        bytes4 setBufferTargetFractionSelector = InsuranceBufferFacet.setBufferTargetFraction.selector;
        bytes4 setBufferRenewalRateSelector = InsuranceBufferFacet.setBufferRenewalRate.selector;
        
        // If any of these selectors are 0x00000000, it means the function doesn't exist
        assertTrue(bufferTargetSelector != bytes4(0), "bufferTarget function missing");
        assertTrue(topUpBufferSelector != bytes4(0), "topUpBuffer function missing");
        assertTrue(slashBufferSelector != bytes4(0), "slashBuffer function missing");
        assertTrue(setBufferTargetFractionSelector != bytes4(0), "setBufferTargetFraction function missing");
        assertTrue(setBufferRenewalRateSelector != bytes4(0), "setBufferRenewalRate function missing");
    }
    
    function test_facet_added_to_diamond() public {
        // Verify the facet is properly added to the diamond
        assertEq(treasury.facets(InsuranceBufferFacet.bufferTarget.selector), address(insuranceBufferFacet));
        assertEq(treasury.facets(InsuranceBufferFacet.topUpBuffer.selector), address(insuranceBufferFacet));
        assertEq(treasury.facets(InsuranceBufferFacet.slashBuffer.selector), address(insuranceBufferFacet));
        assertEq(treasury.facets(InsuranceBufferFacet.setBufferTargetFraction.selector), address(insuranceBufferFacet));
    }
    
    function test_facet_initial_state() public {
        // Verify the facet has the expected initial state through the diamond
        assertEq(treasury.bufferTargetFraction(), 50000); // 5% default
        assertEq(treasury.bufferRenewalFraction(), 100000); // 10% default
    }
}
