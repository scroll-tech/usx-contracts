// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssetManagerAllocatorFacet} from "../../src/facets/AssetManagerAllocatorFacet.sol";
import {TreasuryStorage} from "../../src/TreasuryStorage.sol";

import {LocalDeployTestSetup} from "../LocalDeployTestSetup.sol";

contract MaliciousAssetManagerNoWithdraw {
    IERC20 public immutable USDC;
    constructor(address _usdc) { USDC = IERC20(_usdc); }
    function deposit(uint256 /*_usdcAmount*/) external { /* do nothing, simulate not pulling funds */ }
    function withdraw(uint256 /*_usdcAmount*/) external { /* do nothing, simulate not returning funds */ }
}

contract MaliciousAssetManagerPartialWithdraw {
    IERC20 public immutable USDC;
    constructor(address _usdc) { USDC = IERC20(_usdc); }
    function deposit(uint256 _usdcAmount) external {
        if (_usdcAmount == 0) return;
        // Pull funds like a normal AM to build balance
        require(USDC.transferFrom(msg.sender, address(this), _usdcAmount), "pull fail");
    }
    function withdraw(uint256 _usdcAmount) external {
        if (_usdcAmount == 0) return;
        // Return less than requested to trigger USDCWithdrawalFailed in facet
        uint256 toSend = _usdcAmount > 0 ? _usdcAmount - 1 : 0;
        if (toSend > 0) {
            require(USDC.transfer(msg.sender, toSend), "send fail");
        }
        // keep the 1 wei to simulate shortfall
    }
}

contract AssetManagerAllocatorFacetTest is LocalDeployTestSetup {
    AssetManagerAllocatorFacet private alloc;

    function setUp() public override {
        super.setUp();
        alloc = AssetManagerAllocatorFacet(address(treasury));

        // Ensure treasury has some USDC via user deposit
        vm.startPrank(user);
        usx.deposit(1_000_000e6); // 1,000,000 USDC -> to treasury
        vm.stopPrank();

        // Set allocator to admin for tests
        vm.prank(governance);
        alloc.setAllocator(admin);
    }

    function test_netDeposits_reflectsTreasuryPlusAssetManagerUSDC() public {
        uint256 initial = alloc.netDeposits();
        // Allocate 100 USDC to AM
        vm.prank(admin);
        alloc.transferUSDCtoAssetManager(100e6);
        uint256 afterAlloc = alloc.netDeposits();
        // netDeposits should remain same: treasury USDC decreased, assetManagerUSDC increased equally
        assertEq(afterAlloc, initial, "net deposits should be invariant on allocation");

        // Deallocate 40 USDC back
        vm.prank(admin);
        alloc.transferUSDCFromAssetManager(40e6);
        uint256 afterDealloc = alloc.netDeposits();
        assertEq(afterDealloc, initial, "net deposits should be invariant on deallocation");
    }

    function test_setAllocator_onlyGovernance_andZeroAddressReverts() public {
        // non-governance
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        alloc.setAllocator(address(1));

        // zero address
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        alloc.setAllocator(address(0));

        // success
        vm.prank(governance);
        alloc.setAllocator(address(0xABC));
    }

    function test_transferUSDCtoAssetManager_onlyAllocator_andEvents() public {
        // not allocator
        vm.expectRevert(TreasuryStorage.NotAllocator.selector);
        alloc.transferUSDCtoAssetManager(1);

        uint256 beforeTreasuryBal = usdc.balanceOf(address(treasury));
        uint256 beforeAMBal = usdc.balanceOf(assetManager);
        uint256 beforeAlloc = treasury.assetManagerUSDC();

        // success allocate 250 USDC
        vm.prank(admin);
        alloc.transferUSDCtoAssetManager(250e6);

        uint256 afterTreasuryBal = usdc.balanceOf(address(treasury));
        uint256 afterAMBal = usdc.balanceOf(assetManager);
        uint256 afterAlloc = treasury.assetManagerUSDC();

        assertEq(afterTreasuryBal + 250e6, beforeTreasuryBal, "treasury should decrease by 250");
        assertEq(afterAMBal, beforeAMBal + 250e6, "AM should increase by 250");
        assertEq(afterAlloc, beforeAlloc + 250e6, "allocated tracker should increase");

        // zero amount: no change, but should not revert
        vm.prank(admin);
        alloc.transferUSDCtoAssetManager(0);
        assertEq(treasury.assetManagerUSDC(), afterAlloc, "allocation should be unchanged for zero amount");
    }

    function test_transferUSDCFromAssetManager_onlyAllocator_andUnderflowReverts() public {
        // not allocator
        vm.expectRevert(TreasuryStorage.NotAllocator.selector);
        alloc.transferUSDCFromAssetManager(1);

        // underflow when no allocation yet
        vm.prank(admin);
        vm.expectRevert(); // arithmetic underflow
        alloc.transferUSDCFromAssetManager(1);
    }

    function test_transferUSDCFromAssetManager_success_andWithdrawalFailure() public {
        // First allocate 1000
        vm.prank(admin);
        alloc.transferUSDCtoAssetManager(1000e6);

        uint256 trBefore = usdc.balanceOf(address(treasury));
        uint256 amBefore = usdc.balanceOf(assetManager);
        uint256 allocBefore = treasury.assetManagerUSDC();

        // Deallocate 600
        vm.prank(admin);
        alloc.transferUSDCFromAssetManager(600e6);

        assertEq(usdc.balanceOf(address(treasury)), trBefore + 600e6, "treasury increased by 600");
        assertEq(usdc.balanceOf(assetManager), amBefore - 600e6, "AM decreased by 600");
        assertEq(treasury.assetManagerUSDC(), allocBefore - 600e6, "alloc tracker decreased by 600");

        // Switch to malicious AM that returns less than requested to trigger failure
        MaliciousAssetManagerPartialWithdraw bad = new MaliciousAssetManagerPartialWithdraw(address(usdc));

        // Move some USDC to bad AM via setAssetManager flow: first set bad as current AM
        vm.prank(governance);
        alloc.setAssetManager(address(bad));

        // Set allocator again to admin (governance-only call already ok); now allocate funds to bad AM
        vm.prank(admin);
        alloc.transferUSDCtoAssetManager(100e6);

        uint256 treasuryBalBefore = usdc.balanceOf(address(treasury));
        // Expect USDCWithdrawalFailed due to shortfall on withdraw
        vm.prank(admin);
        vm.expectRevert(TreasuryStorage.USDCWithdrawalFailed.selector);
        alloc.transferUSDCFromAssetManager(50e6);
        // Make sure no accidental transfer happened
        assertEq(usdc.balanceOf(address(treasury)), treasuryBalBefore, "treasury should be unchanged on failed withdraw");
    }

    function test_setAssetManager_onlyGovernance_zeroAddressReverts_andMigration() public {
        // non-governance
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        alloc.setAssetManager(address(123));

        // zero address
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        alloc.setAssetManager(address(0));

        // Allocate some to current AM to exercise withdraw+deposit path during migration
        vm.prank(admin);
        alloc.transferUSDCtoAssetManager(200e6);

        // Migrate to new AM
        MaliciousAssetManagerNoWithdraw newAM = new MaliciousAssetManagerNoWithdraw(address(usdc));

        // Expect migration to revert due to old AM not returning funds? Here old AM is the original MockAssetManager, which returns funds correctly.
        // So first, set a malicious AM that won't return funds, allocate, then try migrating away from it to trigger USDCWithdrawalFailed.
        vm.prank(governance);
        alloc.setAssetManager(address(newAM));

        // Now asset manager set to newAM. Allocate funds tracked to it without actually moving USDC (deposit no-op)
        vm.prank(admin);
        alloc.transferUSDCtoAssetManager(10e6);

        // Migrate away from malicious AM should revert because withdraw doesn't return USDC
        MaliciousAssetManagerPartialWithdraw nextAM = new MaliciousAssetManagerPartialWithdraw(address(usdc));
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.USDCWithdrawalFailed.selector);
        alloc.setAssetManager(address(nextAM));
    }

    function test_transferUSDCForWithdrawal_onlyAllocator_andTransfersMissing() public {
        // not allocator
        vm.expectRevert(TreasuryStorage.NotAllocator.selector);
        alloc.transferUSDCForWithdrawal();

        // Case 1: missing == 0 -> no transfer
        uint256 trBefore = usdc.balanceOf(address(treasury));
        uint256 usxBefore = usdc.balanceOf(address(usx));
        vm.prank(admin);
        alloc.transferUSDCForWithdrawal();
        assertEq(usdc.balanceOf(address(treasury)), trBefore, "no change when no missing");
        assertEq(usdc.balanceOf(address(usx)), usxBefore, "USX unchanged when no missing");

        // Case 2: create outstanding withdrawal, ensure transfer occurs
        // Give user USX and request redemption
        vm.startPrank(user);
        // User already has USX from earlier deposit
        uint256 userUSX = usx.balanceOf(user);
        // Redeem 1000 USDC worth
        uint256 redeemUSX = 1_000e6 * 1e12; // 1000 USDC in 18 decimals
        if (redeemUSX > userUSX) {
            // Mint some more by depositing
            usx.deposit(2_000e6);
            userUSX = usx.balanceOf(user);
        }
        usx.requestUSDC(redeemUSX);
        vm.stopPrank();

        uint256 trBefore2 = usdc.balanceOf(address(treasury));
        uint256 usxBefore2 = usdc.balanceOf(address(usx));

        vm.prank(admin);
        alloc.transferUSDCForWithdrawal();

        // missing equals outstanding - matched (matched is 0 here), so 1000 USDC moved
        assertEq(usdc.balanceOf(address(treasury)), trBefore2 - 1_000e6, "treasury down by missing");
        assertEq(usdc.balanceOf(address(usx)), usxBefore2 + 1_000e6, "USX up by missing");
    }
}
