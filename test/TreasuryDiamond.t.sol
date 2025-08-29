// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {DeployTestSetup} from "../script/DeployTestSetup.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {InsuranceBufferFacet} from "../src/facets/InsuranceBufferFacet.sol";
import {ProfitAndLossReporterFacet} from "../src/facets/ProfitAndLossReporterFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TreasuryDiamondTest is DeployTestSetup {
    function setUp() public override {
        super.setUp(); // Runs the deployment script and sets up contracts
    }

    /*=========================== Deployment & Initialization Tests =========================*/
    
    function test_deploy_treasury_success() public {
        assertEq(address(treasury.USDC()), SCROLL_USDC);
        assertEq(address(treasury.USX()), address(usx));
        assertEq(address(treasury.sUSX()), address(susx));
        assertEq(treasury.governance(), governance);
        assertEq(treasury.governanceWarchest(), governanceWarchest);
        assertEq(treasury.assetManager(), assetManager);
    }
    
    function test_default_values_set_correctly() public {
        assertEq(treasury.successFeeFraction(), 50000);      // 5%
        assertEq(treasury.maxLeverageFraction(), 100000);    // 10%
        assertEq(treasury.bufferRenewalFraction(), 100000);  // 10%
        assertEq(treasury.bufferTargetFraction(), 50000);    // 5%
    }
    
    function test_facets_deploy_success() public {
        assertTrue(treasury.facets(AssetManagerAllocatorFacet.maxLeverage.selector) != address(0));
        assertTrue(treasury.facets(InsuranceBufferFacet.bufferTarget.selector) != address(0));
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.successFee.selector) != address(0));
    }
    
    // ============ Real Contract Deployment Tests ============
    
    function test_usx_deployed_and_initialized() public {
        // Check that USX is deployed and initialized correctly
        assertEq(usx.name(), "USX Token");
        assertEq(usx.symbol(), "USX");
        assertEq(usx.decimals(), 18);
        assertEq(usx.usxPrice(), 1e18);
        assertEq(address(usx.treasury()), address(treasury));
    }
    
    function test_susx_deployed_and_initialized() public {
        // Check that sUSX is deployed and initialized correctly
        assertEq(susx.name(), "sUSX Token");
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
        assertEq(address(usdc), SCROLL_USDC);
        
        // Verify treasury is properly connected to real USDC
        assertEq(address(treasury.USDC()), SCROLL_USDC);
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
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.reportProfits.selector) != address(0));
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.reportLosses.selector) != address(0));
        assertTrue(treasury.facets(ProfitAndLossReporterFacet.setSuccessFeeFraction.selector) != address(0));
    }
    
    function test_diamond_fallback_mechanism() public {
        // Test that the diamond fallback properly delegates to facets
        
        // Test a function that should work
        bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.maxLeverage.selector);
        (bool success, bytes memory result) = address(treasury).call(data);
        
        assertTrue(success, "Diamond fallback should delegate maxLeverage call");
        
        // Test a function that doesn't exist (should revert)
        bytes memory invalidData = abi.encodeWithSelector(bytes4(0x12345678));
        (bool invalidSuccess, ) = address(treasury).call(invalidData);
        assertFalse(invalidSuccess, "Invalid selector should revert");
    }
    
    function test_production_like_initialization() public {
        // Verify the system is initialized exactly as it would be in production
        
        // 1. Treasury has correct addresses
        assertEq(address(treasury.USDC()), SCROLL_USDC);
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
        assertEq(treasury.successFeeFraction(), 50000);      // 5%
        assertEq(treasury.maxLeverageFraction(), 100000);    // 10%
        assertEq(treasury.bufferRenewalFraction(), 100000);  // 10%
        assertEq(treasury.bufferTargetFraction(), 50000);    // 5%
    }
}
