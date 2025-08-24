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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BaseFacetTest is Test {
    // Real contracts deployed in test
    TreasuryDiamond public treasury;
    TreasuryDiamond public treasuryImplementation;
    
    AssetManagerAllocatorFacet public assetManagerFacet;
    InsuranceBufferFacet public insuranceBufferFacet;
    ProfitAndLossReporterFacet public profitAndLossFacet;
    
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

    function setUp() public virtual {
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
    
    // Helper function to call facet functions through the diamond
    function callFacetFunction(bytes4 selector, bytes memory data) internal returns (bool success, bytes memory result) {
        return address(treasury).call(abi.encodeWithSelector(selector, data));
    }
    
    // Helper function to call facet functions through the diamond with no parameters
    function callFacetFunction(bytes4 selector) internal returns (bool success, bytes memory result) {
        return address(treasury).call(abi.encodeWithSelector(selector));
    }
}
