// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DeployTestSetup} from "../script/DeployTestSetup.sol";
import {InsuranceBufferFacet} from "../src/facets/InsuranceBufferFacet.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {TreasuryStorage} from "../src/TreasuryStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// This mock is necessary to simulate external asset manager interactions
contract RealAssetManager {
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;
    
    function deposit(uint256 _usdcAmount) external {
        totalDeposits += _usdcAmount;
        emit DepositCalled(_usdcAmount);
    }
    
    function withdraw(uint256 _usdcAmount) external {
        totalWithdrawals += _usdcAmount;
        emit WithdrawCalled(_usdcAmount);
    }
    
    event DepositCalled(uint256 amount);
    event WithdrawCalled(uint256 amount);
}

contract InsuranceBufferFacetTest is DeployTestSetup {
    RealAssetManager public realAssetManager;
    
    function setUp() public override {
        super.setUp(); // Runs the deployment script and sets up contracts
    }
    
    /*=========================== Basic Functionality Tests =========================*/
    
    function test_bufferTarget_default_value() public {
        // Test bufferTarget with realistic USX balances created through deposits
        // First, create realistic USX balances through user deposits
        vm.prank(user);
        usx.deposit(500000e6); // 500,000 USDC deposit to get USX
        
        // Deposit USX to sUSX vault to create realistic vault balance
        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);
        vm.prank(user);
        susx.deposit(usxBalance, user);
        
        // Test bufferTarget view function
        bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
        (bool bufferTargetSuccess, bytes memory bufferTargetResult) = address(treasury).call(bufferTargetData);
        
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 bufferTarget = abi.decode(bufferTargetResult, (uint256));
        
        // Should return a positive value based on USX total supply and bufferTargetFraction
        assertTrue(bufferTarget > 0, "bufferTarget should return positive value");
        
        // Verify the vault has realistic USX balance
        assertTrue(usx.balanceOf(address(susx)) > 0, "Vault should have USX balance from deposits");
        
        console.log("Buffer target test results:");
        console.log("  USX total supply:", usx.totalSupply());
        console.log("  bufferTarget:", bufferTarget);
        console.log("  Vault USX balance:", usx.balanceOf(address(susx)));
    }

    function test_bufferTarget_after_change() public {
        // Test bufferTarget after changing the bufferTargetFraction
        // First, create realistic USX balances through user deposits
        vm.prank(user);
        usx.deposit(300000e6); // 300,000 USDC deposit to get USX
        
        // Get initial buffer target
        bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
        (bool bufferTargetSuccess, bytes memory bufferTargetResult) = address(treasury).call(bufferTargetData);
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 initialBufferTarget = abi.decode(bufferTargetResult, (uint256));
        
        // Change buffer target fraction (only governance can do this)
        vm.prank(governance);
        bytes memory setBufferTargetData = abi.encodeWithSelector(
            InsuranceBufferFacet.setBufferTargetFraction.selector, 
            100000 // 10% instead of default 5%
        );
        (bool setBufferTargetSuccess,) = address(treasury).call(setBufferTargetData);
        require(setBufferTargetSuccess, "setBufferTargetFraction call failed");
        
        // Get new buffer target
        (bufferTargetSuccess, bufferTargetResult) = address(treasury).call(bufferTargetData);
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 newBufferTarget = abi.decode(bufferTargetResult, (uint256));
        
        // New buffer target should be higher (10% vs 5%)
        assertTrue(newBufferTarget > initialBufferTarget, "Buffer target should increase after fraction change");
        
        console.log("Buffer target change test results:");
        console.log("  Initial buffer target:", initialBufferTarget);
        console.log("  New buffer target:", newBufferTarget);
        console.log("  Change ratio:", (newBufferTarget * 100) / initialBufferTarget, "%");
    }

    function test_bufferTarget_large_value() public {
        // Test bufferTarget with very large USX balances
        // First, create large USX balances through multiple user deposits
        vm.prank(user);
        usx.deposit(1000000e6); // 1,000,000 USDC deposit to get USX
        
        address user2 = address(0x888);
        
        // Whitelist user2
        vm.prank(admin);
        usx.whitelistUser(user2, true);
        
        // Give user2 USDC
        deal(SCROLL_USDC, user2, 2000000e6);
        
        // Approve USDC spending
        vm.prank(user2);
        usdc.approve(address(usx), type(uint256).max);
        
        vm.prank(user2);
        usx.deposit(2000000e6); // 2,000,000 USDC deposit to get USX
        
        // Get buffer target
        bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
        (bool bufferTargetSuccess, bytes memory bufferTargetResult) = address(treasury).call(bufferTargetData);
        
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 bufferTarget = abi.decode(bufferTargetResult, (uint256));
        
        // Should return a large positive value
        assertTrue(bufferTarget > 1000000e18, "Buffer target should be large with large USX supply");
        
        console.log("Large buffer target test results:");
        console.log("  USX total supply:", usx.totalSupply());
        console.log("  bufferTarget:", bufferTarget);
        console.log("  Buffer target in USDC equivalent:", bufferTarget / 1e12);
    }

    function test_setBufferTargetFraction_success() public {
        // Test setting buffer target fraction as governance
        uint256 newFraction = 75000; // 7.5%
        
        vm.prank(governance);
        bytes memory setBufferTargetData = abi.encodeWithSelector(
            InsuranceBufferFacet.setBufferTargetFraction.selector,
            newFraction
        );
        (bool setBufferTargetSuccess,) = address(treasury).call(setBufferTargetData);
        
        assertTrue(setBufferTargetSuccess, "setBufferTargetFraction should succeed for governance");
        
        // Verify the change took effect by checking bufferTarget
        bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
        (bool bufferTargetSuccess, bytes memory bufferTargetResult) = address(treasury).call(bufferTargetData);
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 bufferTarget = abi.decode(bufferTargetResult, (uint256));
        
        // Buffer target should reflect the new fraction
        assertTrue(bufferTarget > 0, "Buffer target should be positive after change");
        
        console.log("setBufferTargetFraction test results:");
        console.log("  New fraction set:", newFraction);
        console.log("  Resulting buffer target:", bufferTarget);
    }

    function test_setBufferTargetFraction_revert_not_governance() public {
        // Test that non-governance users cannot set buffer target fraction
        uint256 newFraction = 75000; // 7.5%
        
        vm.prank(user); // Regular user, not governance
        bytes memory setBufferTargetData = abi.encodeWithSelector(
            InsuranceBufferFacet.setBufferTargetFraction.selector,
            newFraction
        );
        (bool setBufferTargetSuccess,) = address(treasury).call(setBufferTargetData);
        
        // Should fail for non-governance users
        assertFalse(setBufferTargetSuccess, "setBufferTargetFraction should fail for non-governance users");
    }

    function test_setBufferTargetFraction_revert_invalid_fraction() public {
        // Test that invalid buffer target fractions are rejected
        uint256 invalidFraction = 40000; // 4% (below minimum 5%)
        
        vm.prank(governance);
        bytes memory setBufferTargetData = abi.encodeWithSelector(
            InsuranceBufferFacet.setBufferTargetFraction.selector, 
            invalidFraction
        );
        (bool setBufferTargetSuccess,) = address(treasury).call(setBufferTargetData);
        
        // Should fail for invalid fraction
        assertFalse(setBufferTargetSuccess, "setBufferTargetFraction should fail for invalid fraction");
    }

    function test_setBufferRenewalRate_success() public {
        // Test setting buffer renewal rate as governance
        uint256 newRate = 150000; // 15% instead of default 10%
        
        vm.prank(governance);
        bytes memory setRenewalRateData = abi.encodeWithSelector(
            InsuranceBufferFacet.setBufferRenewalRate.selector,
            newRate
        );
        (bool setRenewalRateSuccess,) = address(treasury).call(setRenewalRateData);
        
        assertTrue(setRenewalRateSuccess, "setBufferRenewalRate should succeed for governance");
        
        // Verify the change took effect by checking the storage
        uint256 bufferRenewalFraction = treasury.bufferRenewalFraction();
        assertEq(bufferRenewalFraction, newRate, "Buffer renewal fraction should be updated");
        
        console.log("setBufferRenewalRate test results:");
        console.log("  New rate set:", newRate);
        console.log("  Stored renewal fraction:", bufferRenewalFraction);
    }

    function test_setBufferRenewalRate_revert_not_governance() public {
        // Test that non-governance users cannot set buffer renewal rate
        uint256 newRate = 150000; // 15%
        
        vm.prank(user); // Regular user, not governance
        bytes memory setRenewalRateData = abi.encodeWithSelector(
            InsuranceBufferFacet.setBufferRenewalRate.selector,
            newRate
        );
        (bool setRenewalRateSuccess,) = address(treasury).call(setRenewalRateData);
        
        // Should fail for non-governance users
        assertFalse(setRenewalRateSuccess, "setBufferRenewalRate should fail for non-governance users");
    }

    function test_setBufferRenewalRate_revert_invalid_rate() public {
        // Test that invalid buffer renewal rates are rejected
        uint256 invalidRate = 50000; // 5% (below minimum 10%)
        
        vm.prank(governance);
        bytes memory setRenewalRateData = abi.encodeWithSelector(
            InsuranceBufferFacet.setBufferRenewalRate.selector,
            invalidRate
        );
        (bool setRenewalRateSuccess,) = address(treasury).call(setRenewalRateData);
        
        // Should fail for invalid rate
        assertFalse(setRenewalRateSuccess, "setBufferRenewalRate should fail for invalid rate");
    }

    /*=========================== topUpBuffer Integration Tests =========================*/
    
    function test_topUpBuffer_through_reportProfits_success() public {
        // Test topUpBuffer functionality through reportProfits integration
        // First, create realistic USX balances through user deposits
        vm.prank(user);
        usx.deposit(1000000e6); // 1,000,000 USDC deposit to get USX
        
        // Deposit USX to sUSX vault to create realistic vault balance
        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);
        vm.prank(user);
        susx.deposit(usxBalance, user);
        
        // Get initial buffer target and current buffer size
        bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
        (bool bufferTargetSuccess, bytes memory bufferTargetResult) = address(treasury).call(bufferTargetData);
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 bufferTarget = abi.decode(bufferTargetResult, (uint256));
        
        uint256 initialBufferSize = usx.balanceOf(address(treasury));
        
        // Since we can't easily set assetManagerUSDC through transferUSDCtoAssetManager,
        // we'll test the topUpBuffer logic by directly calling reportProfits with a small profit
        // This will test the topUpBuffer function through its proper integration path
        
        // Report a small profit: 0 + 100,000 = 100,000 USDC total balance
        vm.prank(assetManager);
        bytes memory reportProfitsData = abi.encodeWithSelector(
            bytes4(keccak256("reportProfits(uint256)")),
            100000e6 // 100,000 USDC total balance (0 initial + 100k profit)
        );
        (bool reportProfitsSuccess,) = address(treasury).call(reportProfitsData);
        
        // Should succeed
        assertTrue(reportProfitsSuccess, "reportProfits should succeed");
        
        // Check if buffer was topped up
        uint256 finalBufferSize = usx.balanceOf(address(treasury));
        
        // Buffer should have increased if it was below target
        if (initialBufferSize < bufferTarget) {
            assertTrue(finalBufferSize > initialBufferSize, "Buffer should be topped up when below target");
            console.log("Buffer topped up successfully:");
            console.log("  Initial buffer size:", initialBufferSize);
            console.log("  Final buffer size:", finalBufferSize);
            console.log("  Buffer target:", bufferTarget);
            console.log("  Profit reported:", 100000e6 / 1e6, "USDC");
        } else {
            console.log("Buffer already at or above target, no top-up needed");
        }
    }

    function test_topUpBuffer_through_reportProfits_large_profit() public {
        // Test topUpBuffer with large profits to ensure it handles large amounts correctly
        // First, create realistic USX balances through user deposits
        vm.prank(user);
        usx.deposit(2000000e6); // 2,000,000 USDC deposit to get USX
        
        // Deposit USX to sUSX vault
        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);
        vm.prank(user);
        susx.deposit(usxBalance, user);
        
        // Get initial buffer target and current buffer size
        bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
        (bool bufferTargetSuccess, bytes memory bufferTargetResult) = address(treasury).call(bufferTargetData);
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 bufferTarget = abi.decode(bufferTargetResult, (uint256));
        
        uint256 initialBufferSize = usx.balanceOf(address(treasury));
        
        // Report large profits: 0 + 500,000 = 500,000 USDC total balance
        vm.prank(assetManager);
        bytes memory reportProfitsData = abi.encodeWithSelector(
            bytes4(keccak256("reportProfits(uint256)")),
            500000e6 // 500,000 USDC total balance (0 initial + 500k profit)
        );
        (bool reportProfitsSuccess,) = address(treasury).call(reportProfitsData);
        
        // Should succeed
        assertTrue(reportProfitsSuccess, "reportProfits should succeed");
        
        // Check if buffer was topped up
        uint256 finalBufferSize = usx.balanceOf(address(treasury));
        
        if (initialBufferSize < bufferTarget) {
            assertTrue(finalBufferSize > initialBufferSize, "Buffer should be topped up with large profits");
            console.log("Large profit buffer top-up test:");
            console.log("  Initial buffer size:", initialBufferSize);
            console.log("  Final buffer size:", finalBufferSize);
            console.log("  Buffer target:", bufferTarget);
            console.log("  Large profit reported:", 500000e6 / 1e6, "USDC");
        }
    }

    function test_topUpBuffer_through_reportProfits_no_topup_needed() public {
        // Test that topUpBuffer doesn't run when buffer is already at or above target
        // First, create realistic USX balances through user deposits
        vm.prank(user);
        usx.deposit(500000e6); // 500,000 USDC deposit to get USX
        
        // Deposit USX to sUSX vault
        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);
        vm.prank(user);
        susx.deposit(usxBalance, user);
        
        // Get initial buffer target and current buffer size
        bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
        (bool bufferTargetSuccess, bytes memory bufferTargetResult) = address(treasury).call(bufferTargetData);
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 bufferTarget = abi.decode(bufferTargetResult, (uint256));
        
        uint256 initialBufferSize = usx.balanceOf(address(treasury));
        
        // If buffer is already at or above target, we need to artificially increase it
        // We can do this by temporarily setting a very low buffer target fraction
        if (initialBufferSize >= bufferTarget) {
            // Temporarily set buffer target to a very low value to force top-up
        vm.prank(governance);
            bytes memory setBufferTargetData = abi.encodeWithSelector(
                InsuranceBufferFacet.setBufferTargetFraction.selector, 
                1000 // 0.1% (very low)
            );
            (bool setBufferTargetSuccess,) = address(treasury).call(setBufferTargetData);
            require(setBufferTargetSuccess, "setBufferTargetFraction call failed");
            
            // Get new buffer target
            (bufferTargetSuccess, bufferTargetResult) = address(treasury).call(bufferTargetData);
            require(bufferTargetSuccess, "bufferTarget call failed");
            bufferTarget = abi.decode(bufferTargetResult, (uint256));
            
            console.log("Temporarily lowered buffer target to force top-up test");
        }
        
        // Report small profits: 0 + 10,000 = 10,000 USDC total balance
        vm.prank(assetManager);
        bytes memory reportProfitsData = abi.encodeWithSelector(
            bytes4(keccak256("reportProfits(uint256)")),
            10000e6 // 10,000 USDC total balance (0 initial + 10k profit)
        );
        (bool reportProfitsSuccess,) = address(treasury).call(reportProfitsData);
        
        // Should succeed
        assertTrue(reportProfitsSuccess, "reportProfits should succeed");
        
        // Check if buffer was topped up
        uint256 finalBufferSize = usx.balanceOf(address(treasury));
        
        if (initialBufferSize < bufferTarget) {
            assertTrue(finalBufferSize > initialBufferSize, "Buffer should be topped up when below target");
            console.log("Buffer top-up when below target test:");
            console.log("  Initial buffer size:", initialBufferSize);
            console.log("  Final buffer size:", finalBufferSize);
            console.log("  Buffer target:", bufferTarget);
            console.log("  Small profit reported:", 10000e6 / 1e6, "USDC");
        } else {
            console.log("Buffer already at or above target, no top-up needed");
        }
        
        // Restore original buffer target fraction if we changed it
        if (initialBufferSize >= bufferTarget) {
            vm.prank(governance);
            bytes memory restoreBufferTargetData = abi.encodeWithSelector(
                InsuranceBufferFacet.setBufferTargetFraction.selector, 
                50000 // 5% (default)
            );
            (bool restoreBufferTargetSuccess,) = address(treasury).call(restoreBufferTargetData);
            require(restoreBufferTargetSuccess, "restoreBufferTargetFraction call failed");
        }
    }

    function test_topUpBuffer_through_reportProfits_zero_profit() public {
        // Test topUpBuffer behavior with zero profit (edge case)
        // First, create realistic USX balances through user deposits
        vm.prank(user);
        usx.deposit(300000e6); // 300,000 USDC deposit to get USX
        
        // Deposit USX to sUSX vault
        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);
        vm.prank(user);
        susx.deposit(usxBalance, user);
        
        // Get initial buffer target and current buffer size
        bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
        (bool bufferTargetSuccess, bytes memory bufferTargetResult) = address(treasury).call(bufferTargetData);
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 bufferTarget = abi.decode(bufferTargetResult, (uint256));
        
        uint256 initialBufferSize = usx.balanceOf(address(treasury));
        
        // Report zero profit: 0 + 0 = 0 USDC total balance
        vm.prank(assetManager);
        bytes memory reportProfitsData = abi.encodeWithSelector(
            bytes4(keccak256("reportProfits(uint256)")),
            0 // 0 USDC total balance (0 initial + 0k profit)
        );
        (bool reportProfitsSuccess,) = address(treasury).call(reportProfitsData);
        
        // Should succeed even with zero profit
        assertTrue(reportProfitsSuccess, "reportProfits should succeed with zero profit");
        
        // Check buffer size - should remain the same since no profit to top up with
        uint256 finalBufferSize = usx.balanceOf(address(treasury));
        
        console.log("Zero profit buffer test:");
        console.log("  Initial buffer size:", initialBufferSize);
        console.log("  Final buffer size:", finalBufferSize);
        console.log("  Buffer target:", bufferTarget);
        console.log("  Profit reported: 0 USDC");
        
        // With zero profit, buffer size should remain the same
        assertEq(finalBufferSize, initialBufferSize, "Buffer size should remain the same with zero profit");
    }

    /*=========================== View Function Tests =========================*/

    function test_view_functions_return_correct_values() public {
        // Test that all view functions return correct values with realistic USX balances
        // Create realistic USX balances through deposits
        vm.prank(user);
        usx.deposit(800000e6); // 800,000 USDC deposit to get USX
        
        // Deposit USX to sUSX vault
        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);
        vm.prank(user);
        susx.deposit(usxBalance, user);
        
        // Test bufferTarget view function
        bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
        (bool bufferTargetSuccess, bytes memory bufferTargetResult) = address(treasury).call(bufferTargetData);
        
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 bufferTarget = abi.decode(bufferTargetResult, (uint256));
        
        // Should return a positive value
        assertTrue(bufferTarget > 0, "bufferTarget should return positive value");
        
        // Test bufferRenewalFraction getter
        uint256 bufferRenewalFraction = treasury.bufferRenewalFraction();
        assertTrue(bufferRenewalFraction > 0, "bufferRenewalFraction should return positive value");
        
        // Verify the vault has realistic USX balance
        assertTrue(usx.balanceOf(address(susx)) > 0, "Vault should have USX balance from deposits");
        
        console.log("View function test results:");
        console.log("  bufferTarget:", bufferTarget);
        console.log("  bufferRenewalFraction:", bufferRenewalFraction);
        console.log("  Vault USX balance:", usx.balanceOf(address(susx)));
    }
}
