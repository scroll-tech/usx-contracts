// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LocalDeployTestSetup} from "./LocalDeployTestSetup.sol";
import {StakedUSX} from "../src/StakedUSX.sol";
import {USX} from "../src/USX.sol";

contract StakedUSXTest is LocalDeployTestSetup {
    address internal user2 = address(0xABC);

    function setUp() public override {
        super.setUp();
        // Give user2 some allowances and whitelist if needed for USX minting
        vm.prank(admin);
        usx.whitelistUser(user2, true);
        deal(address(usdc), user2, 1_000_000e6);
        vm.prank(user2);
        usdc.approve(address(usx), type(uint256).max);
    }

    /* =========================== Helpers =========================== */

    function _mintUSXTo(address to, uint256 usdcAmount) internal {
        vm.prank(to);
        usx.deposit(usdcAmount);
    }

    function _stakeUSX(address from, uint256 usxAmount) internal {
        vm.startPrank(from);
        usx.approve(address(susx), usxAmount);
        susx.deposit(usxAmount, from);
        vm.stopPrank();
    }

    function _requestWithdraw(address owner, address receiver, uint256 shareAmount) internal returns (uint256 withdrawalId, uint256 assets) {
        uint256 beforeId = susx.withdrawalCounter();
        vm.prank(owner);
        assets = susx.redeem(shareAmount, receiver, owner);
        withdrawalId = beforeId;
    }

    /* =========================== Initialization & Views =========================== */

    function test_initial_state() public {
        // Token metadata
        assertEq(susx.name(), "sUSX");
        assertEq(susx.symbol(), "sUSX");

        // Governance and treasury set up
        assertEq(susx.governance(), governance);
        assertEq(address(susx.treasury()), treasuryProxy);

        // Defaults
        assertEq(susx.withdrawalPeriod(), 15 days);
        assertEq(susx.withdrawalFeeFraction(), 500); // as initialized
        assertEq(susx.epochDuration(), 30 days);
        assertEq(susx.depositPaused(), false);

        // Share price equals 1e18 initially
        assertEq(susx.sharePrice(), 1e18);

        // totalAssets is zero
        assertEq(susx.totalAssets(), 0);
    }

    function test_view_withdrawalFee_math() public {
        // sanity check fee calculation
        uint256 amount = 1_000_000e18; // 1,000,000 USX
        uint256 fee = susx.withdrawalFee(amount);
        // expected = amount * fraction / 1_000_000
        assertEq(fee, (amount * susx.withdrawalFeeFraction()) / 1_000_000);
    }

    /* =========================== Access Control =========================== */

    function test_onlyAdmin_pauseDeposits() public {
        // Non-admin reverts
        vm.expectRevert(StakedUSX.NotAdmin.selector);
        susx.pauseDeposit();

        // Admin can pause
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.DepositPausedChanged(true);
        susx.pauseDeposit();
        assertTrue(susx.depositPaused());
    }

    function test_admin_unpauseDeposit() public {
        // Pause first via treasury
        vm.prank(admin);
        susx.pauseDeposit();
        assertTrue(susx.depositPaused());

        // Non-admin cannot unpauseDeposit
        vm.expectRevert(StakedUSX.NotAdmin.selector);
        susx.unpauseDeposit();

        // Admin can unpauseDeposit
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.DepositPausedChanged(false);
        susx.unpauseDeposit();
        assertFalse(susx.depositPaused());
    }

    function test_onlyTreasury_notifyRewards_and_zero_amount_no_event() public {
        // Non-treasury reverts
        vm.expectRevert(StakedUSX.NotTreasury.selector);
        susx.notifyRewards(123);

        // Treasury: zero amount = no event, no revert
        vm.prank(treasuryProxy);
        susx.notifyRewards(0);

        // Treasury: positive amount emits
        vm.prank(treasuryProxy);
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.RewardsReceived(1000);
        susx.notifyRewards(1000);
    }

    function test_admin_setters_happy_paths_and_reverts() public {
        // Only admin can set withdrawal period
        vm.expectRevert(StakedUSX.NotAdmin.selector);
        susx.setWithdrawalPeriod(2 days);
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.WithdrawalPeriodSet(susx.withdrawalPeriod(), 2 days);
        vm.prank(admin);
        susx.setWithdrawalPeriod(2 days);
        assertEq(susx.withdrawalPeriod(), 2 days);

        // Only governance can set fee fraction; must be <= 20000
        vm.expectRevert(StakedUSX.NotGovernance.selector);
        susx.setWithdrawalFeeFraction(1000);
        vm.prank(governance);
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.WithdrawalFeeFractionSet(500, 20000);
        susx.setWithdrawalFeeFraction(20000);
        assertEq(susx.withdrawalFeeFraction(), 20000);
        vm.prank(governance);
        vm.expectRevert(StakedUSX.InvalidWithdrawalFeeFraction.selector);
        susx.setWithdrawalFeeFraction(20001);

        // Only admin can set epoch duration; must be >= 1 day
        vm.expectRevert(StakedUSX.NotAdmin.selector);
        susx.setEpochDuration(2 days);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.EpochDurationSet(30 days, 2 days);
        susx.setEpochDuration(2 days);
        assertEq(susx.epochDuration(), 2 days);
        vm.prank(admin);
        vm.expectRevert(StakedUSX.InvalidEpochDuration.selector);
        susx.setEpochDuration(12 hours);

        // setGovernance onlyGovernance and non-zero
        vm.expectRevert(StakedUSX.NotGovernance.selector);
        susx.setGovernance(address(0xBEEF));
        vm.prank(governance);
        vm.expectRevert(StakedUSX.ZeroAddress.selector);
        susx.setGovernance(address(0));
        vm.prank(governance);
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.GovernanceTransferred(governance, address(0xBEEF));
        susx.setGovernance(address(0xBEEF));
        assertEq(susx.governance(), address(0xBEEF));
    }

    function test_setAdmin_success() public {
        address newAdmin = address(0x999);

        // Set new admin (should succeed)
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.AdminTransferred(admin, newAdmin);
        susx.setAdmin(newAdmin);

        // Verify admin was updated
        assertEq(susx.admin(), newAdmin);
    }

    function test_setAdmin_revert_not_admin() public {
        vm.prank(user);
        vm.expectRevert(StakedUSX.NotAdmin.selector);
        susx.setAdmin(address(0x999));
    }

    function test_setAdmin_revert_zero_address() public {
        // Try to set admin to zero address (should revert with NotAdmin, not ZeroAddress)
        // because the function checks admin access first
        vm.prank(user); // Not admin
        vm.expectRevert(StakedUSX.NotAdmin.selector);
        susx.setAdmin(address(0));
    }

    function test_setAdmin_revert_zero_address_as_admin() public {
        // Try to set admin to zero address as admin (should revert with ZeroAddress)
        vm.prank(admin);
        vm.expectRevert(StakedUSX.ZeroAddress.selector);
        susx.setAdmin(address(0));
    }

    function test_setInitialTreasury_onlyOnce_and_validations() public {
        // setInitialTreasury already called in setup; calling again should revert
        vm.prank(admin);
        vm.expectRevert(StakedUSX.TreasuryAlreadySet.selector);
        susx.initializeTreasury(address(treasury));
    }

    /* =========================== Deposits =========================== */

    function test_deposit_success_and_balances() public {
        // Mint USX to user by depositing USDC first
        _mintUSXTo(user, 1000e6);
        uint256 userUSX = usx.balanceOf(user);
        assertEq(userUSX, 1000e18);

        // Stake (deposit) into sUSX
        _stakeUSX(user, userUSX);

        // Shares minted 1:1 initially
        assertEq(susx.balanceOf(user), 1000e18);
        // Vault holds USX
        assertEq(usx.balanceOf(address(susx)), 1000e18);
        // totalAssets reflects vault USX (no rewards, no pending withdrawals)
        assertEq(susx.totalAssets(), 1000e18);
        // sharePrice remains 1e18
        assertEq(susx.sharePrice(), 1e18);
    }

    function test_deposit_reverts_when_deposits_frozen() public {
        // Pause via admin
        vm.prank(admin);
        susx.pauseDeposit();

        _mintUSXTo(user, 100e6);
        vm.startPrank(user);
        usx.approve(address(susx), type(uint256).max);
        vm.expectRevert(StakedUSX.DepositsPaused.selector);
        susx.deposit(100e18, user);
        vm.stopPrank();
    }

    function test_deposit_reverts_with_zero_amount() public {
        _mintUSXTo(user, 100e6);
        vm.startPrank(user);
        usx.approve(address(susx), type(uint256).max);
        vm.expectRevert(StakedUSX.ZeroAmount.selector);
        susx.deposit(0, user);
        vm.stopPrank();
    }

    /* =========================== Withdrawals & Claims =========================== */

    function test_redeem_creates_withdrawal_request_and_updates_state() public {
        _mintUSXTo(user, 1_000e6);
        _stakeUSX(user, 1_000e18);

        uint256 nextId = susx.withdrawalCounter();
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.WithdrawalRequested(user, 400e18, nextId);
        (uint256 withdrawalId, uint256 assets) = _requestWithdraw(user, user, 400e18);
        assertEq(withdrawalId, nextId);
        assertEq(assets, 400e18);

        // State updates
        StakedUSX.WithdrawalRequest memory req = susx.withdrawalRequests(withdrawalId);
        assertEq(req.user, user);
        assertEq(req.amount, 400e18);
        assertEq(req.claimed, false);
        assertEq(susx.totalAssets(), 1_000e18 - 400e18); // pending withdrawals excluded
        assertEq(susx.totalSupply(), 600e18); // shares burned
        assertEq(susx.balanceOf(address(susx)), 0); // shares are burned, contract holds no shares
        assertEq(usx.balanceOf(address(susx)), 1_000e18); // underlying remains in vault until claim
    }

    function test_withdraw_reverts_with_zero_amount() public {
        _mintUSXTo(user, 1_000e6);
        _stakeUSX(user, 1_000e18);

        vm.expectRevert(StakedUSX.ZeroAmount.selector);
        vm.prank(user);
        susx.redeem(0, user, user);
        vm.stopPrank();
    }

    function test_claimWithdraw_reverts_before_period() public {
        _mintUSXTo(user, 500e6);
        _stakeUSX(user, 500e18);
        (uint256 withdrawalId,) = _requestWithdraw(user, user, 200e18);

        vm.expectRevert(StakedUSX.WithdrawalPeriodNotPassed.selector);
        vm.prank(user);
        susx.claimWithdraw(withdrawalId);
    }

    function test_claimWithdraw_success_after_period_transfers_and_fee_and_marks_claimed() public {
        _mintUSXTo(user, 2_000e6);
        _stakeUSX(user, 2_000e18);
        (uint256 withdrawalId, uint256 assets) = _requestWithdraw(user, user, 1_000e18);

        // Advance time at least withdrawalPeriod (default 1 day)
        vm.warp(block.timestamp + susx.withdrawalPeriod() + 1);

        uint256 fee = susx.withdrawalFee(assets);
        uint256 userPortion = assets - fee;

        uint256 gwBefore = usx.balanceOf(treasury.governanceWarchest());
        uint256 userBefore = usx.balanceOf(user);
        uint256 vaultBefore = usx.balanceOf(address(susx));

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.WithdrawalClaimed(user, withdrawalId, assets);
        susx.claimWithdraw(withdrawalId);

        // Transfers
        assertEq(usx.balanceOf(treasury.governanceWarchest()), gwBefore + fee);
        assertEq(usx.balanceOf(user), userBefore + userPortion);
        assertEq(usx.balanceOf(address(susx)), vaultBefore - assets);

        // State
        assertTrue(susx.withdrawalRequests(withdrawalId).claimed);

        // Second claim reverts
        vm.prank(user);
        vm.expectRevert(StakedUSX.WithdrawalAlreadyClaimed.selector);
        susx.claimWithdraw(withdrawalId);
    }

    function test_redeem_with_spender_uses_allowance_and_receiver_differs() public {
        // user stakes, user2 will redeem on behalf of user to receiver user2
        _mintUSXTo(user, 700e6);
        _stakeUSX(user, 700e18);

        vm.prank(user);
        susx.approve(user2, 300e18);

        uint256 nextId = susx.withdrawalCounter();
        vm.prank(user2);
        vm.expectEmit(true, true, true, true, address(susx));
        emit StakedUSX.WithdrawalRequested(user2, 300e18, nextId);
        uint256 assets = susx.redeem(300e18, user2, user);
        assertEq(assets, 300e18);

        // Check request owner/receiver
        StakedUSX.WithdrawalRequest memory req = susx.withdrawalRequests(nextId);
        assertEq(req.user, user2);
        assertEq(req.amount, 300e18);
    }

    function test_sharePrice_and_totalAssets_behavior_with_pending_withdrawals() public {
        _mintUSXTo(user, 1_000e6);
        _stakeUSX(user, 1_000e18);
        assertEq(susx.sharePrice(), 1e18);

        // Create pending withdrawal of 250e18
        _requestWithdraw(user, user, 250e18);
        // totalAssets decreased by pending amount
        assertEq(susx.totalAssets(), 750e18);
        // supply decreased to 750e18 shares; sharePrice may deviate negligibly but should remain 1e18 here
        assertEq(susx.totalSupply(), 750e18);
        assertEq(susx.sharePrice(), 1e18);
    }

    /* =========================== Rewards & Share Price =========================== */

    function test_rewards_queued_when_no_supply_does_not_change_share_price() public {
        // Ensure no supply
        assertEq(susx.totalSupply(), 0);
        assertEq(usx.balanceOf(address(susx)), 0);
        uint256 amount = 1_000e18;

        // Treasury mints rewards to sUSX and notifies while no supply
        vm.prank(treasuryProxy);
        usx.mintUSX(address(susx), amount);
        vm.prank(treasuryProxy);
        susx.notifyRewards(amount);

        // With no supply, rewards should be queued; rate should be 0 so price remains 1e18
        StakedUSX.RewardData memory rd = susx.rewardData();
        assertEq(uint256(rd.rate), 0);
        assertEq(susx.sharePrice(), 1e18);

        // Once a user stakes, price still 1e18 initially (undistributed is still all queued)
        _mintUSXTo(user, 100e6);
        _stakeUSX(user, 100e18);
        assertEq(susx.totalSupply(), 100e18);
        assertEq(susx.sharePrice(), 1e18);
    }

    function test_rewards_linear_accrual_increases_share_price_over_time() public {
        // User stakes to create supply
        _mintUSXTo(user, 1_000e6); // 1,000 USDC -> 1,000 USX
        _stakeUSX(user, 1_000e18); // 1,000 shares
        uint256 initialAssets = susx.totalAssets();
        assertEq(initialAssets, 1_000e18);

        // Treasury mints rewards to sUSX vault and notifies
        uint256 rewardAmount = 100e18; // 100 USX rewards
        vm.prank(treasuryProxy);
        usx.mintUSX(address(susx), rewardAmount);
        vm.prank(treasuryProxy);
        susx.notifyRewards(rewardAmount);

        // Immediately after notify, undistributed is near full reward; share price ~ 1e18
        uint256 price0 = susx.sharePrice();
        assertApproxEqAbs(price0, 1e18, 1); // allow 1 wei rounding

        // Warp half the epoch; share price should increase linearly by distributed portion
        uint256 half = susx.epochDuration() / 2;
        vm.warp(block.timestamp + half);

        StakedUSX.RewardData memory rd1 = susx.rewardData();
        // distributed ~ rate * elapsed
        uint256 elapsed1 = half; // since lastUpdate was at notify
        uint256 distributed1 = uint256(rd1.rate) * elapsed1;

        uint256 expectedAssets1 = initialAssets + distributed1;
        uint256 expectedPrice1 = (expectedAssets1 * 1e18) / susx.totalSupply();
        assertApproxEqAbs(susx.sharePrice(), expectedPrice1, 5); // small absolute tolerance for rounding

        // Warp to end of epoch; price should reflect full distributed (minus queued remainder)
        vm.warp(block.timestamp + (susx.epochDuration() - half));
        StakedUSX.RewardData memory rd2 = susx.rewardData();
        uint256 distributedFull = uint256(rd2.rate) * susx.epochDuration();
        // Some remainder may be queued due to integer division; distributedFull <= rewardAmount
        uint256 expectedAssets2 = initialAssets + distributedFull;
        uint256 expectedPrice2 = (expectedAssets2 * 1e18) / susx.totalSupply();
        assertApproxEqAbs(susx.sharePrice(), expectedPrice2, 5); // small absolute tolerance for rounding
    }

    function test_convertToShares_and_previewDeposit_follow_linear_price() public {
        // Initial stake by user
        _mintUSXTo(user, 1_000e6);
        _stakeUSX(user, 1_000e18);

        // Add rewards and advance time partially
        uint256 rewardAmount = 90e18;
        vm.prank(treasuryProxy);
        usx.mintUSX(address(susx), rewardAmount);
        vm.prank(treasuryProxy);
        susx.notifyRewards(rewardAmount);
        vm.warp(block.timestamp + susx.epochDuration() / 3);

        // New depositor should mint fewer shares than assets due to price > 1
        uint256 depositAssets = 300e18;
        _mintUSXTo(user2, depositAssets / 1e12);
        uint256 expectedShares = susx.convertToShares(depositAssets);
        assertLt(expectedShares, depositAssets);

        vm.startPrank(user2);
        usx.approve(address(susx), depositAssets);
        uint256 user2BeforeShares = susx.balanceOf(user2);
        susx.deposit(depositAssets, user2);
        vm.stopPrank();

        uint256 mintedShares = susx.balanceOf(user2) - user2BeforeShares;
        assertEq(mintedShares, expectedShares);
        assertEq(mintedShares, susx.previewDeposit(depositAssets));
    }

    function test_convertToAssets_and_redeem_follow_linear_price() public {
        // Stake, add rewards, advance time
        _mintUSXTo(user, 2_000e6);
        _stakeUSX(user, 2_000e18);
        uint256 rewardAmount = 200e18;
        vm.prank(treasuryProxy);
        usx.mintUSX(address(susx), rewardAmount);
        vm.prank(treasuryProxy);
        susx.notifyRewards(rewardAmount);
        vm.warp(block.timestamp + susx.epochDuration() / 4);

        // Redeem some shares; assets should equal convertToAssets
        uint256 sharesToRedeem = 500e18;
        uint256 expectedAssets = susx.convertToAssets(sharesToRedeem);

        uint256 nextId = susx.withdrawalCounter();
        vm.prank(user);
        uint256 assets = susx.redeem(sharesToRedeem, user, user);
        assertEq(assets, expectedAssets);

        // Verify withdrawal request recorded correctly with expected assets
        StakedUSX.WithdrawalRequest memory req = susx.withdrawalRequests(nextId);
        assertEq(req.user, user);
        assertEq(req.amount, expectedAssets);
    }
}
