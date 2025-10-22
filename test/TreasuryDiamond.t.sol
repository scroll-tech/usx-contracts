// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {TreasuryStorage} from "../src/TreasuryStorage.sol";

import {LocalDeployTestSetup} from "./LocalDeployTestSetup.sol";

// Minimal facet to probe fallback routing
contract DummyFacet {
    event Ping(uint256 value);
    function ping(uint256 v) external { emit Ping(v); }
}

contract TreasuryDiamondTest is LocalDeployTestSetup {
    function setUp() public override {
        LocalDeployTestSetup.setUp();
    }

    /*=========================== Initialization =========================*/

    function test_initialize_setsCoreStateAndDefaults() public view {
        assertEq(address(treasury.USDC()), address(usdc));
        assertEq(address(treasury.USX()), address(usx));
        assertEq(address(treasury.sUSX()), address(susx));
        assertEq(treasury.admin(), admin);
        assertEq(treasury.governance(), governance);
        assertEq(treasury.governanceWarchest(), governanceWarchest);
        assertEq(treasury.successFeeFraction(), 50000);
        assertEq(treasury.insuranceFundFraction(), 50000);
    }

    function test_initialize_revertsOnZeroAddresses() public {
        TreasuryDiamond impl = new TreasuryDiamond();
        bytes memory data = abi.encodeCall(
            TreasuryDiamond.initialize,
            (address(0), address(usx), address(susx), admin, governance, governanceWarchest, assetManager, insuranceVault)
        );
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    /*=========================== Governance Setters =========================*/

    function test_setGovernance_success() public {
        vm.prank(governance);
        treasury.setGovernance(address(0xABCD));
        assertEq(treasury.governance(), address(0xABCD));
    }

    function test_setGovernance_revertsIfNotGovernance() public {
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        treasury.setGovernance(address(1));
    }

    function test_setGovernance_revertsOnZero() public {
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        treasury.setGovernance(address(0));
    }

    function test_setGovernanceWarchest_success() public {
        vm.prank(governance);
        treasury.setGovernanceWarchest(address(0xBEEF));
        assertEq(treasury.governanceWarchest(), address(0xBEEF));
    }

    function test_setGovernanceWarchest_revertsIfNotGovernance() public {
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        treasury.setGovernanceWarchest(address(1));
    }

    function test_setGovernanceWarchest_revertsOnZero() public {
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        treasury.setGovernanceWarchest(address(0));
    }

    function test_setInsuranceVault_success() public {
        vm.prank(governance);
        treasury.setInsuranceVault(address(0xCAFE));
    }

    function test_setInsuranceVault_revertsIfNotGovernance() public {
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        treasury.setInsuranceVault(address(1));
    }

    function test_setInsuranceVault_revertsOnZero() public {
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        treasury.setInsuranceVault(address(0));
    }

    function test_setAdmin_success() public {
        address newAdmin = address(0x999);

        // Set new admin (should succeed)
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit TreasuryStorage.AdminTransferred(admin, newAdmin);
        treasury.setAdmin(newAdmin);

        // Verify admin was updated
        assertEq(treasury.admin(), newAdmin);
    }

    function test_setAdmin_revert_not_admin() public {
        vm.prank(user);
        vm.expectRevert(TreasuryStorage.NotAdmin.selector);
        treasury.setAdmin(address(0x999));
    }

    function test_setAdmin_revert_zero_address() public {
        // Try to set admin to zero address (should revert with NotAdmin, not ZeroAddress)
        // because the function checks admin access first
        vm.prank(user); // Not admin
        vm.expectRevert(TreasuryStorage.NotAdmin.selector);
        treasury.setAdmin(address(0));
    }

    function test_setAdmin_revert_zero_address_as_admin() public {
        // Try to set admin to zero address as admin (should revert with ZeroAddress)
        vm.prank(admin);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        treasury.setAdmin(address(0));
    }

    /*=========================== Facet Management =========================*/

    function test_addFacet_success_and_routesCalls() public {
        DummyFacet df = new DummyFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = DummyFacet.ping.selector;

        vm.prank(governance);
        treasury.addFacet(address(df), selectors);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit DummyFacet.Ping(42);
        (bool ok,) = address(treasury).call(abi.encodeWithSelector(DummyFacet.ping.selector, 42));
        assertTrue(ok);
    }

    function test_addFacet_revertsOnZeroFacet() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("ping(uint256)"));
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        treasury.addFacet(address(0), selectors);
    }

    function test_addFacet_revertsIfSelectorExists() public {
        DummyFacet d1 = new DummyFacet();
        DummyFacet d2 = new DummyFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = DummyFacet.ping.selector;
        vm.startPrank(governance);
        treasury.addFacet(address(d1), selectors);
        vm.expectRevert(TreasuryStorage.FacetAlreadyExists.selector);
        treasury.addFacet(address(d2), selectors);
        vm.stopPrank();
    }

    function test_removeFacet_success() public {
        DummyFacet df = new DummyFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = DummyFacet.ping.selector;
        vm.startPrank(governance);
        treasury.addFacet(address(df), selectors);
        treasury.removeFacet(address(df));
        vm.stopPrank();

        vm.expectRevert(TreasuryStorage.SelectorNotFound.selector);
        (bool ok,) = address(treasury).call(abi.encodeWithSelector(DummyFacet.ping.selector, 1));
        ok;
    }

    function test_replaceFacet_success() public {
        DummyFacet d1 = new DummyFacet();
        DummyFacet d2 = new DummyFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = DummyFacet.ping.selector;
        vm.startPrank(governance);
        treasury.addFacet(address(d1), selectors);
        treasury.replaceFacet(address(d1), address(d2));
        vm.stopPrank();

        vm.expectEmit(true, false, false, true, address(treasury));
        emit DummyFacet.Ping(7);
        (bool ok,) = address(treasury).call(abi.encodeWithSelector(DummyFacet.ping.selector, 7));
        assertTrue(ok);
    }

    function test_replaceFacet_revertsOnZeroNewFacet() public {
        DummyFacet d1 = new DummyFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = DummyFacet.ping.selector;
        vm.startPrank(governance);
        treasury.addFacet(address(d1), selectors);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        treasury.replaceFacet(address(d1), address(0));
        vm.stopPrank();
    }

    function test_replaceFacet_revertsOnIdenticalFacet() public {
        DummyFacet d1 = new DummyFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = DummyFacet.ping.selector;
        vm.startPrank(governance);
        treasury.addFacet(address(d1), selectors);
        vm.expectRevert(TreasuryStorage.InvalidFacet.selector);
        treasury.replaceFacet(address(d1), address(d1));
        vm.stopPrank();
    }

    function test_fallback_revertsOnUnknownSelector() public {
        vm.expectRevert(TreasuryStorage.SelectorNotFound.selector);
        (bool ok,) = address(treasury).call(abi.encodeWithSelector(bytes4(0xDEADBEEF)));
        ok;
    }

    /*=========================== UUPS =========================*/

    function test_getImplementation_returnsAddress() public view {
        address impl = treasury.getImplementation();
        impl;
    }
}
