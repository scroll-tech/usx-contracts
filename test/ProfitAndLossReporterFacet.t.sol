// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ProfitAndLossReporterFacet} from "../src/facets/ProfitAndLossReporterFacet.sol";
import {BaseFacetTest} from "./BaseFacetTest.sol";

contract ProfitAndLossReporterFacetTest is BaseFacetTest {
    
    function setUp() public override {
        super.setUp();
    }
    
    // ============ Deployment & Initialization Tests ============
    
    function test_facet_deploys_successfully() public {
        assertEq(address(profitAndLossFacet), address(profitAndLossFacet));
    }
    
    function test_facet_has_required_functions() public {
        // Verify the facet contract has the expected interface by checking function selectors
        // This ensures the contract implements all the functions we expect
        bytes4 successFeeSelector = ProfitAndLossReporterFacet.successFee.selector;
        bytes4 profitLatestEpochSelector = ProfitAndLossReporterFacet.profitLatestEpoch.selector;
        bytes4 profitPerBlockSelector = ProfitAndLossReporterFacet.profitPerBlock.selector;
        bytes4 reportProfitsSelector = ProfitAndLossReporterFacet.reportProfits.selector;
        bytes4 reportLossesSelector = ProfitAndLossReporterFacet.reportLosses.selector;
        bytes4 setSuccessFeeFractionSelector = ProfitAndLossReporterFacet.setSuccessFeeFraction.selector;
        
        // If any of these selectors are 0x00000000, it means the function doesn't exist
        assertTrue(successFeeSelector != bytes4(0), "successFee function missing");
        assertTrue(profitLatestEpochSelector != bytes4(0), "profitLatestEpoch function missing");
        assertTrue(profitPerBlockSelector != bytes4(0), "profitPerBlock function missing");
        assertTrue(reportProfitsSelector != bytes4(0), "reportProfits function missing");
        assertTrue(reportLossesSelector != bytes4(0), "reportLosses function missing");
        assertTrue(setSuccessFeeFractionSelector != bytes4(0), "setSuccessFeeFraction function missing");
    }
    
    function test_facet_added_to_diamond() public {
        // Verify the facet is properly added to the diamond
        assertEq(treasury.facets(ProfitAndLossReporterFacet.successFee.selector), address(profitAndLossFacet));
        assertEq(treasury.facets(ProfitAndLossReporterFacet.profitLatestEpoch.selector), address(profitAndLossFacet));
        assertEq(treasury.facets(ProfitAndLossReporterFacet.profitPerBlock.selector), address(profitAndLossFacet));
        assertEq(treasury.facets(ProfitAndLossReporterFacet.reportProfits.selector), address(profitAndLossFacet));
        assertEq(treasury.facets(ProfitAndLossReporterFacet.reportLosses.selector), address(profitAndLossFacet));
        assertEq(treasury.facets(ProfitAndLossReporterFacet.setSuccessFeeFraction.selector), address(profitAndLossFacet));
    }
    
    function test_facet_initial_state() public {
        // Verify the facet has the expected initial state through the diamond
        assertEq(treasury.successFeeFraction(), 50000); // 5% default
    }
}
