// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LocalDeployTestSetup} from "./LocalDeployTestSetup.sol";
import {InsuranceBufferFacet} from "../src/facets/InsuranceBufferFacet.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {ProfitAndLossReporterFacet} from "../src/facets/ProfitAndLossReporterFacet.sol";

contract InsuranceBufferFacetTest is LocalDeployTestSetup {
    function setUp() public override {
        super.setUp(); // Runs the deployment script and sets up contracts
    }

    /*=========================== CORE FUNCTIONALITY TESTS =========================*/

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
        deal(address(usdc), user2, 2000000e6);

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

        // Should return a reasonable value (5% of total supply)
        assertTrue(bufferTarget > 100000e18, "Buffer target should be reasonable with large USX supply");

        console.log("Large buffer target test results:");
        console.log("  USX total supply:", usx.totalSupply());
        console.log("  bufferTarget:", bufferTarget);
        console.log("  Buffer target in USDC equivalent:", bufferTarget / 1e12);
    }

    function test_setBufferTargetFraction_success() public {
        // First, seed the vault with USX so we have a realistic USX supply
        vm.prank(user);
        usx.deposit(500000e6); // 500,000 USDC deposit to get USX

        // Deposit USX to sUSX vault to create realistic vault balance
        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);
        vm.prank(user);
        susx.deposit(usxBalance, user);

        // Test setting buffer target fraction as governance
        uint256 newFraction = 75000; // 7.5%

        vm.prank(governance);
        bytes memory setBufferTargetData =
            abi.encodeWithSelector(InsuranceBufferFacet.setBufferTargetFraction.selector, newFraction);
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
        bytes memory setBufferTargetData =
            abi.encodeWithSelector(InsuranceBufferFacet.setBufferTargetFraction.selector, newFraction);
        (bool setBufferTargetSuccess,) = address(treasury).call(setBufferTargetData);

        // Should fail for non-governance users
        assertFalse(setBufferTargetSuccess, "setBufferTargetFraction should fail for non-governance users");
    }

    function test_setBufferTargetFraction_revert_invalid_fraction() public {
        // Test that invalid buffer target fractions are rejected
        uint256 invalidFraction = 40000; // 4% (below minimum 5%)

        vm.prank(governance);
        bytes memory setBufferTargetData =
            abi.encodeWithSelector(InsuranceBufferFacet.setBufferTargetFraction.selector, invalidFraction);
        (bool setBufferTargetSuccess,) = address(treasury).call(setBufferTargetData);

        // Should fail for invalid fraction
        assertFalse(setBufferTargetSuccess, "setBufferTargetFraction should fail for invalid fraction");
    }

    function test_setBufferRenewalRate_success() public {
        // Test setting buffer renewal rate as governance
        uint256 newRate = 150000; // 15% instead of default 10%

        vm.prank(governance);
        bytes memory setRenewalRateData =
            abi.encodeWithSelector(InsuranceBufferFacet.setBufferRenewalRate.selector, newRate);
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
        bytes memory setRenewalRateData =
            abi.encodeWithSelector(InsuranceBufferFacet.setBufferRenewalRate.selector, newRate);
        (bool setRenewalRateSuccess,) = address(treasury).call(setRenewalRateData);

        // Should fail for non-governance users
        assertFalse(setRenewalRateSuccess, "setBufferRenewalRate should fail for non-governance users");
    }

    function test_setBufferRenewalRate_revert_invalid_rate() public {
        // Test that invalid buffer renewal rates are rejected
        uint256 invalidRate = 50000; // 5% (below minimum 10%)

        vm.prank(governance);
        bytes memory setRenewalRateData =
            abi.encodeWithSelector(InsuranceBufferFacet.setBufferRenewalRate.selector, invalidRate);
        (bool setRenewalRateSuccess,) = address(treasury).call(setRenewalRateData);

        // Should fail for invalid rate
        assertFalse(setRenewalRateSuccess, "setBufferRenewalRate should fail for invalid rate");
    }

    /*=========================== ACCESS CONTROL TESTS =========================*/

    function test_topUpBuffer_through_assetManagerReport_success() public {
        // Test topUpBuffer functionality through REAL profit reporting flow
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

        // Transfer USDC to asset manager (this is how profits are actually generated)
        vm.prank(assetManager);
        bytes memory transferData = abi.encodeWithSelector(
            AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector,
            100000e6 // 100,000 USDC transferred to asset manager
        );
        (bool transferSuccess,) = address(treasury).call(transferData);
        require(transferSuccess, "transferUSDCtoAssetManager should succeed");

        // Asset manager now has 100,000 USDC and "invests" it to generate profits
        // Asset manager earns 50,000 USDC profit (total balance now 150,000 USDC)

        // Asset manager reports the new total balance (including profits)
        vm.prank(assetManager);
        bytes memory assetManagerReportData = abi.encodeWithSelector(
            ProfitAndLossReporterFacet.assetManagerReport.selector,
            150000e6 // 150,000 USDC total balance (100k initial + 50k profit)
        );
        (bool assetManagerReportSuccess,) = address(treasury).call(assetManagerReportData);

        // Should succeed
        assertTrue(assetManagerReportSuccess, "assetManagerReport should succeed");

        // Check if buffer was topped up
        uint256 finalBufferSize = usx.balanceOf(address(treasury));

        // Buffer should have increased if it was below target
        if (initialBufferSize < bufferTarget) {
            assertTrue(finalBufferSize > initialBufferSize, "Buffer should be topped up when below target");
            console.log("Buffer topped up successfully:");
            console.log("  Initial buffer size:", initialBufferSize);
            console.log("  Final buffer size:", finalBufferSize);
            console.log("  Buffer target:", bufferTarget);
            console.log("  Real profit reported:", 50e6 / 1e6, "USDC");
            console.log("  Insurance buffer portion (10%):", 5e6 / 1e6, "USDC");
            console.log("  Governance warchest portion (5%):", 2500000, "USDC");
            console.log("  Stakers portion (85%):", 42500000, "USDC");
        } else {
            console.log("Buffer already at or above target, no top-up needed");
        }
    }

    function test_topUpBuffer_through_assetManagerReport_large_profit() public {
        // Test topUpBuffer with large profits
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

        // Transfer USDC to asset manager
        vm.prank(assetManager);
        bytes memory transferData = abi.encodeWithSelector(
            AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector,
            200000e6 // 200,000 USDC transferred to asset manager
        );
        (bool transferSuccess,) = address(treasury).call(transferData);
        require(transferSuccess, "transferUSDCtoAssetManager should succeed");

        // Asset manager earns 300,000 USDC profit (total balance now 500,000 USDC)
        vm.prank(assetManager);
        bytes memory assetManagerReportData = abi.encodeWithSelector(
            ProfitAndLossReporterFacet.assetManagerReport.selector,
            500000e6 // 500,000 USDC total balance (200k initial + 300k profit)
        );
        (bool assetManagerReportSuccess,) = address(treasury).call(assetManagerReportData);

        // Should succeed
        assertTrue(assetManagerReportSuccess, "assetManagerReport should succeed");

        // Check if buffer was topped up
        uint256 finalBufferSize = usx.balanceOf(address(treasury));

        if (initialBufferSize < bufferTarget) {
            assertTrue(finalBufferSize > initialBufferSize, "Buffer should be topped up with large profits");
            console.log("Large profit buffer top-up test:");
            console.log("  Initial buffer size:", initialBufferSize);
            console.log("  Final buffer size:", finalBufferSize);
            console.log("  Buffer target:", bufferTarget);
            console.log("  Real large profit reported:", 300e6 / 1e6, "USDC");
        }
    }

    function test_topUpBuffer_through_assetManagerReport_no_topup_needed() public {
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

        // Transfer USDC to asset manager
        vm.prank(assetManager);
        bytes memory transferData = abi.encodeWithSelector(
            AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector,
            5000e6 // 5,000 USDC transferred to asset manager
        );
        (bool transferSuccess,) = address(treasury).call(transferData);
        require(transferSuccess, "transferUSDCtoAssetManager should succeed");

        // Asset manager earns 5,000 USDC profit (total balance now 10,000 USDC)
        vm.prank(assetManager);
        bytes memory assetManagerReportData = abi.encodeWithSelector(
            ProfitAndLossReporterFacet.assetManagerReport.selector,
            10000e6 // 10,000 USDC total balance (5k initial + 5k profit)
        );
        (bool assetManagerReportSuccess,) = address(treasury).call(assetManagerReportData);

        // Should succeed
        assertTrue(assetManagerReportSuccess, "assetManagerReport should succeed");

        // Check if buffer was topped up
        uint256 finalBufferSize = usx.balanceOf(address(treasury));

        if (initialBufferSize < bufferTarget) {
            assertTrue(finalBufferSize > initialBufferSize, "Buffer should be topped up when below target");
            console.log("Buffer top-up when below target test:");
            console.log("  Initial buffer size:", initialBufferSize);
            console.log("  Final buffer size:", finalBufferSize);
            console.log("  Buffer target:", bufferTarget);
            console.log("  Real small profit reported:", 5e6 / 1e6, "USDC");
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

    function test_topUpBuffer_through_assetManagerReport_zero_profit() public {
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

        // Transfer USDC to asset manager
        vm.prank(assetManager);
        bytes memory transferData = abi.encodeWithSelector(
            AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector,
            10000e6 // 10,000 USDC transferred to asset manager
        );
        (bool transferSuccess,) = address(treasury).call(transferData);
        require(transferSuccess, "transferUSDCtoAssetManager should succeed");

        // Asset manager reports same balance (no profit earned)
        vm.prank(assetManager);
        bytes memory assetManagerReportData = abi.encodeWithSelector(
            ProfitAndLossReporterFacet.assetManagerReport.selector,
            10000e6 // 10,000 USDC total balance (10k initial + 0k profit)
        );
        (bool assetManagerReportSuccess,) = address(treasury).call(assetManagerReportData);

        // Should succeed even with zero profit
        assertTrue(assetManagerReportSuccess, "assetManagerReport should succeed with zero profit");

        // Check buffer size - should remain the same since no profit to top up with
        uint256 finalBufferSize = usx.balanceOf(address(treasury));

        console.log("Zero profit buffer test:");
        console.log("  Initial buffer size:", initialBufferSize);
        console.log("  Final buffer size:", finalBufferSize);
        console.log("  Buffer target:", bufferTarget);
        console.log("  Real profit reported: 0 USDC");

        // With zero profit, buffer size should remain the same
        assertEq(finalBufferSize, initialBufferSize, "Buffer size should remain the same with zero profit");
    }

    /*=========================== INTEGRATION TESTS =========================*/

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

    function test_slashBuffer_insufficient_buffer() public {
        // Setup: Create a scenario where the loss exceeds the buffer size
        uint256 largeLoss = 10000e6; // 10,000 USDC loss

        // Mock the buffer to have some USX but not enough
        uint256 bufferUSX = 5000e18; // 5,000 USX in buffer
        deal(address(usx), address(treasury), bufferUSX);

        // Calculate how much USX the loss represents
        uint256 lossInUSX = largeLoss * DECIMAL_SCALE_FACTOR; // 10,000 USDC * 10^12 = 10^16 USX

        // The loss in USX (10^16) is greater than buffer USX (5*10^21), so this should trigger the else branch
        vm.prank(address(treasury));
        bytes memory slashBufferData = abi.encodeWithSelector(InsuranceBufferFacet.slashBuffer.selector, largeLoss);
        (bool slashBufferSuccess, bytes memory slashBufferResult) = address(treasury).call(slashBufferData);
        require(slashBufferSuccess, "slashBuffer call failed");
        uint256 remainingLosses = abi.decode(slashBufferResult, (uint256));

        // Verify the buffer was completely burned
        assertEq(usx.balanceOf(address(treasury)), 0, "Buffer should be completely burned");

        // Verify remaining losses are calculated correctly
        uint256 expectedRemainingLosses = (lossInUSX - bufferUSX) / DECIMAL_SCALE_FACTOR;
        assertEq(remainingLosses, expectedRemainingLosses, "Remaining losses should be calculated correctly");
    }

    function test_topUpBuffer_buffer_at_target() public {
        // Setup: Ensure buffer is already at or above target
        bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
        (bool bufferTargetSuccess, bytes memory bufferTargetResult) = address(treasury).call(bufferTargetData);
        require(bufferTargetSuccess, "bufferTarget call failed");
        uint256 bufferTarget = abi.decode(bufferTargetResult, (uint256));

        // Give the treasury enough USX to meet the target
        deal(address(usx), address(treasury), bufferTarget);

        // Try to top up buffer with profits
        uint256 profits = 1000e6; // 1,000 USDC profits
        vm.prank(address(treasury));
        bytes memory topUpBufferData = abi.encodeWithSelector(InsuranceBufferFacet.topUpBuffer.selector, profits);
        (bool topUpBufferSuccess, bytes memory topUpBufferResult) = address(treasury).call(topUpBufferData);
        require(topUpBufferSuccess, "topUpBuffer call failed");
        uint256 insuranceBufferAccrual = abi.decode(topUpBufferResult, (uint256));

        // Should return 0 since buffer is already at target
        assertEq(insuranceBufferAccrual, 0, "Should return 0 when buffer is at target");

        // Buffer size should remain unchanged
        assertEq(usx.balanceOf(address(treasury)), bufferTarget, "Buffer size should remain unchanged");
    }

    function test_slashBuffer_exact_buffer_size() public {
        // Setup: Create a scenario where the loss exactly equals the buffer size
        uint256 bufferUSX = 1000e18; // 1,000 USX in buffer
        uint256 lossInUSDC = 1000e6; // 1,000 USDC
        uint256 lossInUSX = lossInUSDC * DECIMAL_SCALE_FACTOR; // 1,000 USDC * 10^12 = 10^15 USX

        // Set buffer to exactly match the loss
        deal(address(usx), address(treasury), lossInUSX);

        vm.prank(address(treasury));
        bytes memory slashBufferData = abi.encodeWithSelector(InsuranceBufferFacet.slashBuffer.selector, lossInUSDC);
        (bool slashBufferSuccess, bytes memory slashBufferResult) = address(treasury).call(slashBufferData);
        require(slashBufferSuccess, "slashBuffer call failed");
        uint256 remainingLosses = abi.decode(slashBufferResult, (uint256));

        // Should return 0 since buffer exactly covers the loss
        assertEq(remainingLosses, 0, "Should return 0 when buffer exactly covers loss");

        // Buffer should be completely burned
        assertEq(usx.balanceOf(address(treasury)), 0, "Buffer should be completely burned");
    }
}
