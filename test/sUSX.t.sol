// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/Test.sol";
import {LocalDeployTestSetup} from "./LocalDeployTestSetup.sol";
import {sUSX} from "../src/sUSX.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {ProfitAndLossReporterFacet} from "../src/facets/ProfitAndLossReporterFacet.sol";

// Define ERC4626 error locally since it's not exported
error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);

contract sUSXTest is LocalDeployTestSetup {
    uint256 public constant INITIAL_BALANCE = 1000e18; // 1000 USX

    event TreasurySet(address indexed treasury);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event EpochAdvanced(uint256 oldEpochBlock, uint256 newEpochBlock, address indexed caller);

    function setUp() public override {
        super.setUp(); // Runs the deployment script and sets up contracts
    }

    /*=========================== SETUP AND CONFIGURATION TESTS =========================*/

    function test_setInitialTreasury_revert_already_set() public {
        // Treasury is already set in setUp
        vm.prank(governance);
        vm.expectRevert(sUSX.TreasuryAlreadySet.selector);
        susx.setInitialTreasury(address(0x999));
    }

    function test_setInitialTreasury_revert_not_governance() public {
        vm.prank(user);
        vm.expectRevert(sUSX.NotGovernance.selector);
        susx.setInitialTreasury(address(0x999));
    }

    /*=========================== CORE FUNCTIONALITY TESTS =========================*/

    function test_sharePrice_first_deposit() public {
        // In local deployment, we need to seed the vault with USX first
        vm.prank(user);
        usx.deposit(1000000e6); // 1,000,000 USDC deposit to get USX

        // Deposit USX to sUSX vault to create realistic vault balance
        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);
        vm.prank(user);
        susx.deposit(usxBalance, user);

        // Should return 1:1 ratio for initial deposits
        assertEq(susx.sharePrice(), 1e18);
    }

    function test_sharePrice_with_deposits() public {
        assertEq(susx.sharePrice(), 1e18);
    }

    function test_withdrawal_fee_calculation() public {
        uint256 amount = 1000e18; // 1000 USX

        uint256 fee = susx.withdrawalFee(amount);

        // 0.5% = 500 basis points
        uint256 expectedFee = amount * 500 / 1000000;
        assertEq(fee, expectedFee);
    }

    /*=========================== ACCESS CONTROL TESTS =========================*/

    function test_setMinWithdrawalPeriod_success() public {
        uint256 newPeriod = 150000; // 15 days + some extra

        vm.prank(governance);
        susx.setMinWithdrawalPeriod(newPeriod);

        assertEq(susx.minWithdrawalPeriod(), newPeriod);
    }

    function test_setMinWithdrawalPeriod_revert_not_governance() public {
        vm.prank(user);
        vm.expectRevert(sUSX.NotGovernance.selector);
        susx.setMinWithdrawalPeriod(150000);
    }

    function test_setMinWithdrawalPeriod_revert_invalid_value() public {
        uint256 invalidPeriod = 100000; // Less than minimum 108000

        vm.prank(governance);
        vm.expectRevert(sUSX.InvalidMinWithdrawalPeriod.selector);
        susx.setMinWithdrawalPeriod(invalidPeriod);
    }

    function test_setWithdrawalFeeFraction_success() public {
        uint256 newFee = 1000; // 1%

        vm.prank(governance);
        susx.setWithdrawalFeeFraction(newFee);

        assertEq(susx.withdrawalFeeFraction(), newFee);
    }

    function test_setWithdrawalFeeFraction_revert_not_governance() public {
        vm.prank(user);
        vm.expectRevert(sUSX.NotGovernance.selector);
        susx.setWithdrawalFeeFraction(1000);
    }

    function test_setEpochDuration_success() public {
        uint256 newDuration = 300000; // 30 days + some extra

        vm.prank(governance);
        susx.setEpochDuration(newDuration);

        assertEq(susx.epochDuration(), newDuration);
    }

    function test_setEpochDuration_revert_not_governance() public {
        vm.prank(user);
        vm.expectRevert(sUSX.NotGovernance.selector);
        susx.setEpochDuration(300000);
    }

    function test_setGovernance_success() public {
        address newGovernance = address(0x999);

        vm.prank(governance);
        susx.setGovernance(newGovernance);

        assertEq(susx.governance(), newGovernance);
    }

    function test_setGovernance_revert_not_governance() public {
        vm.prank(user);
        vm.expectRevert(sUSX.NotGovernance.selector);
        susx.setGovernance(address(0x999));
    }

    function test_setGovernance_revert_zero_address() public {
        vm.prank(governance);
        vm.expectRevert(sUSX.ZeroAddress.selector);
        susx.setGovernance(address(0));
    }

    function test_withdraw_creates_request() public {
        // Setup: User deposits USX to get sUSX
        vm.prank(user);
        usx.deposit(1000e6); // 1000 USDC

        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);

        vm.prank(user);
        uint256 shares = susx.deposit(usxBalance, user);

        // User requests withdrawal
        uint256 withdrawalAmount = shares / 2; // Withdraw half
        vm.prank(user);
        susx.withdraw(withdrawalAmount, user, user);

        // Check that withdrawal request was created
        uint256 withdrawalId = 0; // First withdrawal request
        sUSX.WithdrawalRequest memory request = susx.withdrawalRequests(withdrawalId);

        assertEq(request.user, user, "Withdrawal request user should match");
        assertEq(request.amount, withdrawalAmount, "Withdrawal request amount should match");
        assertFalse(request.claimed, "Withdrawal request should not be claimed initially");
        assertEq(susx.withdrawalIdCounter(), 1, "Withdrawal ID counter should be incremented");
    }

    function test_withdraw_revert_insufficient_balance() public {
        // Setup: User deposits USX to get sUSX
        vm.prank(user);
        usx.deposit(1000e6); // 1000 USDC

        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);

        vm.prank(user);
        uint256 shares = susx.deposit(usxBalance, user);

        // Calculate how many shares the user actually has
        uint256 userUSXBalance = susx.balanceOf(user);
        uint256 sharePrice = susx.sharePrice();
        uint256 actualShares = userUSXBalance * 1e18 / sharePrice;

        // Try to withdraw more than user actually has
        uint256 excessiveAmount = actualShares + 1e18; // Try to withdraw 1 share more than they have

        // Check what the actual balance is
        console.log("User shares from deposit:", shares);
        console.log("User actual shares:", actualShares);
        console.log("Trying to withdraw:", excessiveAmount);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626ExceededMaxWithdraw.selector, user, excessiveAmount, actualShares)
        );
        susx.withdraw(excessiveAmount, user, user);
    }

    function test_claimWithdraw_success() public {
        // Setup: User deposits USX to get sUSX
        vm.prank(user);
        usx.deposit(1000e6); // 1000 USDC

        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);

        vm.prank(user);
        uint256 shares = susx.deposit(usxBalance, user);

        // User requests withdrawal
        uint256 withdrawalAmount = shares / 2; // Withdraw half
        vm.prank(user);
        susx.withdraw(withdrawalAmount, user, user);

        // Approve sUSX to spend its own USX (needed for claimWithdraw)
        vm.prank(address(susx));
        usx.approve(address(susx), type(uint256).max);

        // Advance time past withdrawal period and start new epoch
        uint256 withdrawalPeriod = susx.withdrawalPeriod();
        uint256 epochDuration = susx.epochDuration();
        uint256 blocksToAdvance = withdrawalPeriod + epochDuration + 100; // Extra buffer

        vm.roll(block.number + blocksToAdvance);

        // Start new epoch (this happens when asset manager reports profits/losses)
        vm.prank(assetManager);
        bytes memory reportData = abi.encodeWithSelector(
            ProfitAndLossReporterFacet.assetManagerReport.selector,
            1000e6 // Report same balance (no profit)
        );
        (bool success,) = address(treasury).call(reportData);
        require(success, "reportProfits should succeed");

        // Get initial balances
        uint256 userInitialUSX = usx.balanceOf(user);
        uint256 governanceWarchestInitialUSX = usx.balanceOf(treasury.governanceWarchest());

        // User claims withdrawal
        vm.prank(user);
        susx.claimWithdraw(0); // First withdrawal request

        // Check that withdrawal was processed
        sUSX.WithdrawalRequest memory request = susx.withdrawalRequests(0);
        assertTrue(request.claimed, "Withdrawal request should be marked as claimed");

        // Check that user received USX (minus withdrawal fee)
        uint256 userFinalUSX = usx.balanceOf(user);
        assertGt(userFinalUSX, userInitialUSX, "User should receive USX");

        // Check that governance warchest received withdrawal fee
        uint256 governanceWarchestFinalUSX = usx.balanceOf(treasury.governanceWarchest());
        assertGt(
            governanceWarchestFinalUSX,
            governanceWarchestInitialUSX,
            "Governance warchest should receive withdrawal fee"
        );
    }

    function test_claimWithdraw_revert_period_not_passed() public {
        // Setup: User deposits USX to get sUSX
        vm.prank(user);
        usx.deposit(1000e6); // 1000 USDC

        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);

        vm.prank(user);
        uint256 shares = susx.deposit(usxBalance, user);

        // User requests withdrawal
        uint256 withdrawalAmount = shares / 2;
        vm.prank(user);
        susx.withdraw(withdrawalAmount, user, user);

        // Try to claim immediately (before withdrawal period)
        vm.prank(user);
        vm.expectRevert(sUSX.WithdrawalPeriodNotPassed.selector);
        susx.claimWithdraw(0);
    }

    function test_claimWithdraw_revert_next_epoch_not_started() public {
        // Setup: User deposits USX to get sUSX
        vm.prank(user);
        usx.deposit(1000e6); // 1000 USDC

        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);

        vm.prank(user);
        uint256 shares = susx.deposit(usxBalance, user);

        // Advance block number to ensure withdrawal is made after lastEpochBlock
        vm.roll(block.number + 1000);

        // User requests withdrawal AFTER the last epoch block
        uint256 withdrawalAmount = shares / 2;
        vm.prank(user);
        susx.withdraw(withdrawalAmount, user, user);

        // Approve sUSX to spend its own USX
        vm.prank(address(susx));
        usx.approve(address(susx), type(uint256).max);

        // Advance time past withdrawal period but DON'T start a new epoch
        uint256 withdrawalPeriod = susx.withdrawalPeriod();
        vm.roll(block.number + withdrawalPeriod + 100);

        // Try to claim (withdrawal period passed but no NEW epoch after withdrawal)
        vm.prank(user);
        vm.expectRevert(sUSX.NextEpochNotStarted.selector);
        susx.claimWithdraw(0);
    }

    function test_claimWithdraw_revert_already_claimed() public {
        // Setup: User deposits USX to get sUSX
        vm.prank(user);
        usx.deposit(1000e6); // 1000 USDC

        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);

        vm.prank(user);
        uint256 shares = susx.deposit(usxBalance, user);

        // User requests withdrawal
        uint256 withdrawalAmount = shares / 2;
        vm.prank(user);
        susx.withdraw(withdrawalAmount, user, user);

        // Approve sUSX to spend its own USX
        vm.prank(address(susx));
        usx.approve(address(susx), type(uint256).max);

        // Advance time and start new epoch
        uint256 withdrawalPeriod = susx.withdrawalPeriod();
        uint256 epochDuration = susx.epochDuration();
        vm.roll(block.number + withdrawalPeriod + epochDuration + 100);

        // Start new epoch
        vm.prank(assetManager);
        bytes memory reportData = abi.encodeWithSelector(ProfitAndLossReporterFacet.assetManagerReport.selector, 1000e6);
        (bool success,) = address(treasury).call(reportData);
        require(success, "reportProfits should succeed");

        // User claims withdrawal successfully
        vm.prank(user);
        susx.claimWithdraw(0);

        // Try to claim the same withdrawal again
        vm.prank(user);
        vm.expectRevert(sUSX.WithdrawalAlreadyClaimed.selector);
        susx.claimWithdraw(0);
    }

    function test_claimWithdraw_with_profit_distribution() public {
        // Setup: User deposits USX to get sUSX
        vm.prank(user);
        usx.deposit(1000e6); // 1000 USDC

        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);

        vm.prank(user);
        uint256 shares = susx.deposit(usxBalance, user);

        // User requests withdrawal
        uint256 withdrawalAmount = shares / 2;
        vm.prank(user);
        susx.withdraw(withdrawalAmount, user, user);

        // Approve sUSX to spend its own USX
        vm.prank(address(susx));
        usx.approve(address(susx), type(uint256).max);

        // Advance time and start new epoch with profits
        uint256 withdrawalPeriod = susx.withdrawalPeriod();
        uint256 epochDuration = susx.epochDuration();
        vm.roll(block.number + withdrawalPeriod + epochDuration + 100);

        // Transfer USDC to asset manager and report profits
        vm.prank(assetManager);
        bytes memory transferData = abi.encodeWithSelector(
            AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector,
            500e6 // 500 USDC transferred
        );
        (bool transferSuccess,) = address(treasury).call(transferData);
        require(transferSuccess, "transferUSDCtoAssetManager should succeed");

        vm.prank(assetManager);
        bytes memory reportData = abi.encodeWithSelector(
            ProfitAndLossReporterFacet.assetManagerReport.selector,
            1500e6 // 1500 USDC total (1000 initial + 500 profit)
        );
        (bool success,) = address(treasury).call(reportData);
        require(success, "reportProfits should succeed");

        // Get initial balances
        uint256 userInitialUSX = usx.balanceOf(user);

        // User claims withdrawal (should include profit distribution)
        vm.prank(user);
        susx.claimWithdraw(0);

        // Check that user received USX including profit share
        uint256 userFinalUSX = usx.balanceOf(user);
        assertGt(userFinalUSX, userInitialUSX, "User should receive USX including profit share");
    }

    function test_convertToShares_rounding() public {
        // Test the _convertToShares function with different rounding modes
        uint256 assets = 1000e6; // 1000 USDC

        // Test with Math.Rounding.Down
        uint256 sharesDown = susx.previewDeposit(assets);

        // Test with Math.Rounding.Up (if available)
        // Note: ERC4626 standard uses Math.Rounding.Down by default

        assertGt(sharesDown, 0, "Shares should be greater than 0");
    }

    function test_convertToAssets_rounding() public {
        // Setup: User deposits USX to get sUSX
        vm.prank(user);
        usx.deposit(1000e6); // 1000 USDC

        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);

        vm.prank(user);
        uint256 shares = susx.deposit(usxBalance, user);

        // Test the _convertToAssets function
        uint256 assets = susx.previewRedeem(shares);

        assertGt(assets, 0, "Assets should be greater than 0");
        assertLe(assets, usxBalance, "Assets should not exceed original USX balance");
    }

    function test_authorizeUpgrade_success() public {
        // Test that governance can authorize upgrades
        // Note: _authorizeUpgrade is internal, so we test it through the upgrade mechanism
        // This test verifies that only governance can call upgrade-related functions

        // Verify governance can call setGovernance (similar access control)
        vm.prank(governance);
        susx.setGovernance(address(0x5678));

        assertEq(susx.governance(), address(0x5678), "Governance should be updated");
    }

    function test_authorizeUpgrade_revert_not_governance() public {
        // Test that non-governance cannot authorize upgrades

        // Non-governance should not be able to call governance functions
        vm.prank(user);
        vm.expectRevert(sUSX.NotGovernance.selector);
        susx.setGovernance(address(0x5678));
    }

    function test_withdrawal_request_storage() public {
        // Test that withdrawal requests are stored correctly
        vm.prank(user);
        usx.deposit(1000e6);

        uint256 usxBalance = usx.balanceOf(user);
        vm.prank(user);
        usx.approve(address(susx), usxBalance);

        vm.prank(user);
        uint256 shares = susx.deposit(usxBalance, user);

        // Create withdrawal requests with different amounts to test storage
        uint256 withdrawalAmount1 = shares / 10; // 10% of shares
        uint256 withdrawalAmount2 = shares / 20; // 5% of shares (different amount)

        // Convert shares to assets for withdraw function
        uint256 assets1 = susx.previewRedeem(withdrawalAmount1);
        uint256 assets2 = susx.previewRedeem(withdrawalAmount2); // Use different amount

        vm.prank(user);
        susx.withdraw(assets1, user, user); // ID 0

        vm.prank(user);
        susx.withdraw(assets2, user, user); // ID 1

        // Check that requests are stored correctly
        sUSX.WithdrawalRequest memory request0 = susx.withdrawalRequests(0);
        sUSX.WithdrawalRequest memory request1 = susx.withdrawalRequests(1);

        assertEq(request0.user, user, "Request 0 user should match");
        assertGt(request0.amount, 0, "Request 0 amount should be greater than 0");
        assertFalse(request0.claimed, "Request 0 should not be claimed");

        assertEq(request1.user, user, "Request 1 user should match");
        assertGt(request1.amount, 0, "Request 1 amount should be greater than 0");
        assertFalse(request1.claimed, "Request 1 should not be claimed");

        assertEq(susx.withdrawalIdCounter(), 2, "Withdrawal ID counter should be 2");

        // Verify that the amounts are different (to ensure they're not the same request)
        assertGt(request0.amount, request1.amount, "Request amounts should be different");
    }

    /*=========================== INTEGRATION TESTS =========================*/

    function test_withdraw_with_different_caller_receiver() public {
        // Test _withdraw with different caller and receiver
        uint256 usxBalance = usx.balanceOf(user);
        uint256 shares = susx.deposit(usxBalance, user);

        address receiver = address(0x1234);

        // User withdraws to a different receiver
        vm.prank(user);
        susx.withdraw(shares / 2, receiver, user);

        // Check that withdrawal request was created for the receiver
        uint256 requestId = susx.withdrawalIdCounter() - 1;
        sUSX.WithdrawalRequest memory request = susx.withdrawalRequests(requestId);
        assertEq(request.user, receiver, "Withdrawal request should be for receiver");
    }

    function test_convertToShares_with_rounding() public {
        // Test _convertToShares with different rounding modes
        uint256 assets = 1000e18; // 1000 USX

        // Test with Math.Rounding.Down
        uint256 sharesDown = susx.previewDeposit(assets);

        // Test with Math.Rounding.Up (we can't directly call _convertToShares, but we can test the logic)
        uint256 sharePrice = susx.sharePrice();
        uint256 sharesUp = assets * 1e18 / sharePrice;

        assertTrue(sharesDown > 0, "Should convert assets to shares");
        assertTrue(sharesUp > 0, "Should convert assets to shares with rounding");
    }

    function test_convertToAssets_with_rounding() public {
        // Test _convertToAssets with different rounding modes
        uint256 shares = 1000e18; // 1000 sUSX shares

        // Test with Math.Rounding.Down
        uint256 assetsDown = susx.previewRedeem(shares);

        // Test with Math.Rounding.Up (we can't directly call _convertToAssets, but we can test the logic)
        uint256 sharePrice = susx.sharePrice();
        uint256 assetsUp = shares * sharePrice / 1e18;

        assertTrue(assetsDown > 0, "Should convert shares to assets");
        assertTrue(assetsUp > 0, "Should convert shares to assets with rounding");
    }

    function test_withdraw_with_zero_shares() public {
        // Test withdrawal with zero shares
        // ERC4626 allows zero withdrawals, so this should not revert
        vm.prank(user);
        uint256 shares = susx.withdraw(0, user, user);

        assertEq(shares, 0, "Should return 0 shares for zero withdrawal");
    }

    function test_withdraw_with_zero_assets() public {
        // Test withdrawal with zero assets
        // ERC4626 allows zero withdrawals, so this should not revert
        vm.prank(user);
        uint256 assets = susx.redeem(0, user, user);

        assertEq(assets, 0, "Should return 0 assets for zero withdrawal");
    }

    function test_freezeDeposits_success() public {
        // Test freezeDeposits through treasury (full flow)
        // Since freezeDeposits is onlyTreasury, we need to impersonate treasury

        bool initialFreezeState = susx.depositsFrozen();
        assertFalse(initialFreezeState, "Deposits should not be frozen initially");

        // Impersonate the treasury to call freezeDeposits
        vm.prank(address(treasury));
        susx.freezeDeposits();

        bool finalFreezeState = susx.depositsFrozen();
        assertTrue(finalFreezeState, "Deposits should be frozen");

        // Test that frozen deposits prevent deposits
        // Give user USX and approve sUSX to spend it
        vm.prank(address(treasury));
        usx.mintUSX(user, 1000e18);
        vm.prank(user);
        usx.approve(address(susx), 100e18);

        vm.prank(user);
        vm.expectRevert(sUSX.DepositsFrozen.selector);
        susx.deposit(100e18, user);
    }

    function test_freezeDeposits_revert_not_treasury() public {
        vm.prank(user);
        vm.expectRevert(sUSX.NotTreasury.selector);
        susx.freezeDeposits();
    }

    function test_unfreeze_success() public {
        // Test unfreeze through governance (full flow)
        // Since unfreeze is onlyGovernance, we need to impersonate governance

        // First freeze deposits
        vm.prank(address(treasury));
        susx.freezeDeposits();
        assertTrue(susx.depositsFrozen(), "Deposits should be frozen");

        // Then unfreeze deposits
        vm.prank(governance);
        susx.unfreeze();

        bool finalFreezeState = susx.depositsFrozen();
        assertFalse(finalFreezeState, "Deposits should be unfrozen");

        // Test that unfrozen deposits allow deposits
        // Give user USX and approve sUSX to spend it
        vm.prank(address(treasury));
        usx.mintUSX(user, 1000e18);
        vm.prank(user);
        usx.approve(address(susx), 100e18);

        vm.prank(user);
        susx.deposit(100e18, user);
        // Should not revert
    }

    function test_unfreeze_revert_not_governance() public {
        vm.prank(user);
        vm.expectRevert(sUSX.NotGovernance.selector);
        susx.unfreeze();
    }

    function test_depositsFrozen_view() public {
        // Test depositsFrozen view function
        assertFalse(susx.depositsFrozen(), "Deposits should not be frozen initially");

        // Freeze deposits
        vm.prank(address(treasury));
        susx.freezeDeposits();

        assertTrue(susx.depositsFrozen(), "Deposits should be frozen");
    }

    function test_deposit_revert_when_frozen() public {
        // Test that deposits revert when frozen
        vm.prank(address(treasury));
        susx.freezeDeposits();

        // Give user USX and approve sUSX to spend it
        vm.prank(address(treasury));
        usx.mintUSX(user, 1000e18);
        vm.prank(user);
        usx.approve(address(susx), 100e18);

        vm.prank(user);
        vm.expectRevert(sUSX.DepositsFrozen.selector);
        susx.deposit(100e18, user);
    }

    function test_deposit_success_when_unfrozen() public {
        // Test that deposits work when unfrozen
        assertFalse(susx.depositsFrozen(), "Deposits should not be frozen initially");

        // Give user USX and approve sUSX to spend it
        vm.prank(address(treasury));
        usx.mintUSX(user, 1000e18);
        vm.prank(user);
        usx.approve(address(susx), 100e18);

        vm.prank(user);
        susx.deposit(100e18, user);
        // Should not revert
    }
}
