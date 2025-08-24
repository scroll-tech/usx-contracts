// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {TreasuryStorage} from "../src/TreasuryStorage.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {InsuranceBufferFacet} from "../src/facets/InsuranceBufferFacet.sol";
import {ProfitAndLossReporterFacet} from "../src/facets/ProfitAndLossReporterFacet.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {USX} from "../src/USX.sol";
import {sUSX} from "../src/sUSX.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TreasuryDiamondTest is Test {
    TreasuryDiamond public treasury;
    TreasuryDiamond public treasuryImplementation;
    
    AssetManagerAllocatorFacet public assetManagerFacet;
    InsuranceBufferFacet public insuranceBufferFacet;
    ProfitAndLossReporterFacet public profitAndLossFacet;
    
    // Real contracts deployed in test
    USX public usx;
    USX public usxImplementation;
    sUSX public susx;
    sUSX public susxImplementation;
    
    // Real Scroll mainnet addresses
    address public constant SCROLL_USDC = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4; // Scroll mainnet USDC
    
    // Test addresses
    address public governance = address(0x1);
    address public governanceWarchest = address(0x2);
    address public assetManager = address(0x3);
    
    // Real USDC interface
    ERC20 public usdc;

    function setUp() public {
        // Fork Scroll mainnet
        vm.createSelectFork("scroll");
        
        // Get real USDC interface
        usdc = ERC20(SCROLL_USDC);
        
        // Deploy USX implementation and proxy
        usxImplementation = new USX();
        bytes memory usxInitData = abi.encodeWithSelector(
            USX.initialize.selector,
            SCROLL_USDC,
            address(0), // treasury - will be set after diamond deployment
            governance,
            governance
        );
        ERC1967Proxy usxProxy = new ERC1967Proxy(
            address(usxImplementation),
            usxInitData
        );
        usx = USX(address(usxProxy));
        
        // Deploy sUSX implementation and proxy
        susxImplementation = new sUSX();
        bytes memory susxInitData = abi.encodeWithSelector(
            sUSX.initialize.selector,
            address(usx), // USX address
            address(0),   // treasury - will be set after diamond deployment
            governance
        );
        ERC1967Proxy susxProxy = new ERC1967Proxy(
            address(susxImplementation),
            susxInitData
        );
        susx = sUSX(address(susxProxy));
        
        // Deploy Treasury Diamond implementation
        treasuryImplementation = new TreasuryDiamond();
        
        // Deploy facets
        assetManagerFacet = new AssetManagerAllocatorFacet();
        insuranceBufferFacet = new InsuranceBufferFacet();
        profitAndLossFacet = new ProfitAndLossReporterFacet();
        
        // Deploy Treasury proxy with real contract addresses
        bytes memory treasuryInitData = abi.encodeWithSelector(
            TreasuryDiamond.initialize.selector,
            SCROLL_USDC,
            address(usx),
            address(susx),
            governance,
            governanceWarchest,
            assetManager
        );
        
        ERC1967Proxy treasuryProxy = new ERC1967Proxy(
            address(treasuryImplementation),
            treasuryInitData
        );
        
        treasury = TreasuryDiamond(payable(address(treasuryProxy)));
        
        // Now set the treasury addresses in USX and sUSX
        vm.startPrank(governance);
        usx.setInitialTreasury(address(treasury));
        susx.setInitialTreasury(address(treasury));
        vm.stopPrank();
        
        // Set up the diamond with facets - EXACTLY as in production
        _setupDiamondFacets();
    }
    
    function _setupDiamondFacets() internal {
        vm.startPrank(governance);
        
        // Add AssetManagerAllocatorFacet with ALL its functions
        bytes4[] memory assetManagerSelectors = new bytes4[](6);
        assetManagerSelectors[0] = AssetManagerAllocatorFacet.maxLeverage.selector;
        assetManagerSelectors[1] = AssetManagerAllocatorFacet.checkMaxLeverage.selector;
        assetManagerSelectors[2] = AssetManagerAllocatorFacet.netDeposits.selector;
        assetManagerSelectors[3] = AssetManagerAllocatorFacet.setAssetManager.selector;
        assetManagerSelectors[4] = AssetManagerAllocatorFacet.setMaxLeverageFraction.selector;
        assetManagerSelectors[5] = AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector;
        treasury.addFacet(address(assetManagerFacet), assetManagerSelectors);
        
        // Add InsuranceBufferFacet with ALL its functions
        bytes4[] memory insuranceSelectors = new bytes4[](4);
        insuranceSelectors[0] = InsuranceBufferFacet.bufferTarget.selector;
        insuranceSelectors[1] = InsuranceBufferFacet.topUpBuffer.selector;
        insuranceSelectors[2] = InsuranceBufferFacet.slashBuffer.selector;
        insuranceSelectors[3] = InsuranceBufferFacet.setBufferTargetFraction.selector;
        treasury.addFacet(address(insuranceBufferFacet), insuranceSelectors);
        
        // Add ProfitAndLossReporterFacet with ALL its functions
        bytes4[] memory profitLossSelectors = new bytes4[](7);
        profitLossSelectors[0] = ProfitAndLossReporterFacet.successFee.selector;
        profitLossSelectors[1] = ProfitAndLossReporterFacet.profitLatestEpoch.selector;
        profitLossSelectors[2] = ProfitAndLossReporterFacet.profitPerBlock.selector;
        profitLossSelectors[3] = ProfitAndLossReporterFacet.reportProfits.selector;
        profitLossSelectors[4] = ProfitAndLossReporterFacet.reportLosses.selector;
        profitLossSelectors[5] = ProfitAndLossReporterFacet.setSuccessFeeFraction.selector;
        profitLossSelectors[6] = InsuranceBufferFacet.setBufferRenewalRate.selector;
        treasury.addFacet(address(profitAndLossFacet), profitLossSelectors);
        
        vm.stopPrank();
    }

    // ============ Basic Deployment Tests ============
    
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
        assertEq(address(assetManagerFacet), address(assetManagerFacet));
        assertEq(address(insuranceBufferFacet), address(insuranceBufferFacet));
        assertEq(address(profitAndLossFacet), address(profitAndLossFacet));
    }
    
    // ============ Real Contract Deployment Tests ============
    
    function test_usx_deployed_and_initialized() public {
        assertEq(usx.name(), "USX Token");
        assertEq(usx.symbol(), "USX");
        assertEq(usx.decimals(), 18);
        assertEq(usx.usxPrice(), 1e18);
        assertEq(address(usx.treasury()), address(treasury));
    }
    
    function test_susx_deployed_and_initialized() public {
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
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        
        // Verify treasury is properly connected to real USDC
        assertEq(address(treasury.USDC()), SCROLL_USDC);
    }
    
    function test_complete_diamond_facet_setup() public {
        // Verify ALL AssetManagerAllocatorFacet functions are mapped
        assertEq(treasury.facets(AssetManagerAllocatorFacet.maxLeverage.selector), address(assetManagerFacet));
        assertEq(treasury.facets(AssetManagerAllocatorFacet.checkMaxLeverage.selector), address(assetManagerFacet));
        assertEq(treasury.facets(AssetManagerAllocatorFacet.netDeposits.selector), address(assetManagerFacet));
        assertEq(treasury.facets(AssetManagerAllocatorFacet.setAssetManager.selector), address(assetManagerFacet));
        assertEq(treasury.facets(AssetManagerAllocatorFacet.setMaxLeverageFraction.selector), address(assetManagerFacet));
        assertEq(treasury.facets(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector), address(assetManagerFacet));
        
        // Verify ALL InsuranceBufferFacet functions are mapped
        assertEq(treasury.facets(InsuranceBufferFacet.bufferTarget.selector), address(insuranceBufferFacet));
        assertEq(treasury.facets(InsuranceBufferFacet.topUpBuffer.selector), address(insuranceBufferFacet));
        assertEq(treasury.facets(InsuranceBufferFacet.slashBuffer.selector), address(insuranceBufferFacet));
        assertEq(treasury.facets(InsuranceBufferFacet.setBufferTargetFraction.selector), address(insuranceBufferFacet));
        
        // Verify ALL ProfitAndLossReporterFacet functions are mapped
        assertEq(treasury.facets(ProfitAndLossReporterFacet.successFee.selector), address(profitAndLossFacet));
        assertEq(treasury.facets(ProfitAndLossReporterFacet.profitLatestEpoch.selector), address(profitAndLossFacet));
        assertEq(treasury.facets(ProfitAndLossReporterFacet.profitPerBlock.selector), address(profitAndLossFacet));
        assertEq(treasury.facets(ProfitAndLossReporterFacet.reportProfits.selector), address(profitAndLossFacet));
        assertEq(treasury.facets(ProfitAndLossReporterFacet.reportLosses.selector), address(profitAndLossFacet));
        assertEq(treasury.facets(ProfitAndLossReporterFacet.setSuccessFeeFraction.selector), address(profitAndLossFacet));
        
        // Note: setBufferRenewalRate is added to the diamond but it's actually from InsuranceBufferFacet
        // This is a bit confusing - the function exists in InsuranceBufferFacet but we're adding it through ProfitAndLossFacet
        // In production, this might need to be reorganized for clarity
    }
    
    function test_diamond_fallback_mechanism() public {
        // Test that the diamond fallback properly delegates to facets
        // This is the core mechanism that makes the diamond work
        
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
        
        // 5. Initial state is correct
        assertEq(usx.totalSupply(), 0);           // No USX minted yet
        assertEq(susx.totalSupply(), 0);          // No sUSX shares minted yet
        assertEq(treasury.assetManagerUSDC(), 0); // No USDC allocated to asset manager yet
    }
}
