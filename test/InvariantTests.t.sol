// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {LocalDeployTestSetup} from "./LocalDeployTestSetup.sol";
import {USX} from "../src/USX.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {sUSX} from "../src/sUSX.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {ProfitAndLossReporterFacet} from "../src/facets/ProfitAndLossReporterFacet.sol";
import {InsuranceBufferFacet} from "../src/facets/InsuranceBufferFacet.sol";
import {MockAssetManager} from "../src/mocks/MockAssetManager.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title InvariantTests
/// @notice These are Foundry invariant tests that run with fuzzing, without forking
contract InvariantTests is LocalDeployTestSetup {
    // Track state for invariant testing
    uint256 public previousTotalSupply;
    uint256 public previousPegPrice;
    bool public previousWithdrawalsFrozen;

    // Multiple test users for more realistic testing
    address[] private testUsers;
    uint256 public constant NUM_TEST_USERS = 3;

    // Modifier for random time advancement
    modifier advanceTimeRandomly() {
        // Advance time randomly (including 0 for same-block transactions)
        uint256 timeAdvance = bound(block.timestamp, 0, 10 days);
        if (timeAdvance > 0) {
            vm.warp(block.timestamp + timeAdvance);
            vm.roll(block.number + (timeAdvance / 12)); // Assuming 12-second block time
        }
        _;
    }

    /// @notice Get a random test user
    /// @dev Returns a random user from the test users array
    function getRandomUser() internal view returns (address) {
        require(testUsers.length > 0, "No test users available");
        uint256 userIndex = (block.timestamp % testUsers.length);
        return testUsers[userIndex];
    }

    function setUp() public override {
        // Call parent setup first
        super.setUp();

        // Set up additional test users
        _setupTestUsers();

        // Initialize state tracking
        previousTotalSupply = usx.totalSupply();
        previousPegPrice = usx.usxPrice();
        previousWithdrawalsFrozen = usx.withdrawalsFrozen();
    }

    function _setupTestUsers() internal {
        for (uint256 i = 0; i < NUM_TEST_USERS; i++) {
            address testUser = address(uint160(1000 + i));
            testUsers.push(testUser);

            // Whitelist the user
            vm.prank(admin);
            usx.whitelistUser(testUser, true);

            // Give each user some initial USDC
            deal(address(usdc), testUser, 1000000e6);

            // Set up necessary approvals
            vm.prank(testUser);
            usdc.approve(address(usx), type(uint256).max);
            usx.approve(address(susx), type(uint256).max); // For sUSX deposits
        }
    }

    /*=========================== Invariants =========================*/

    /// @notice Invariant: Value conservation must always hold
    function invariant_value_conservation() public view {
        if (usx.totalSupply() == 0) return; // Skip initial state

        uint256 totalUSXValue = usx.totalSupply() * usx.usxPrice() / 1e18; // USX value in wei (18 decimals)
        uint256 totalUSDCBacking = (
            usdc.balanceOf(address(treasury)) + treasury.assetManagerUSDC() + usdc.balanceOf(address(usx))
        ) * DECIMAL_SCALE_FACTOR; // USDC backing scaled to 18 decimals

        // Allow small tolerance for rounding errors (1 wei)
        uint256 difference =
            totalUSDCBacking > totalUSXValue ? totalUSDCBacking - totalUSXValue : totalUSXValue - totalUSDCBacking;
        assertLe(difference, 1, "Value conservation violated - difference too large");
    }

    /// @notice Invariant: Protocol must never lose value to rounding (PROTOCOL-FAVORED)
    function invariant_protocol_favored_rounding() public view {
        if (usx.totalSupply() == 0) return; // Skip initial state

        uint256 totalUSXValue = usx.totalSupply() * usx.usxPrice() / 1e18 / 1e12; // Convert to USDC scale (6 decimals)
        uint256 totalUSDCBacking =
            usdc.balanceOf(address(treasury)) + treasury.assetManagerUSDC() + usdc.balanceOf(address(usx));

        // Protocol should NEVER lose value to rounding
        // If there's any difference, it should favor the protocol (USDC backing >= USX value)
        assertGe(totalUSDCBacking, totalUSXValue, "Protocol lost value to rounding");
    }

    /// @notice Invariant: sUSX rounding must favor the protocol
    function invariant_susx_protocol_favored_rounding() public view {
        if (susx.totalSupply() == 0) return; // Skip if no shares exist

        uint256 expectedSharePrice = (susx.totalAssets() * 1e18) / susx.totalSupply();
        uint256 actualSharePrice = susx.sharePrice();

        // Share price should never be higher than expected (protocol should not lose)
        assertLe(actualSharePrice, expectedSharePrice, "sUSX share price favors users over protocol");
    }

    /// @notice Invariant: Share prices must be valid and consistent with underlying assets
    function invariant_valid_share_price() public view {
        if (susx.totalSupply() == 0) return; // Skip if no shares exist

        _checkSharePriceBasicValidity();
        _checkSharePriceConsistencyWithAssets();
        _checkSharePriceConsistencyWithUSX();
        _checkSharePriceBounds();
    }

    /// @notice Check basic share price validity
    function _checkSharePriceBasicValidity() internal view {
        uint256 sharePrice = susx.sharePrice();
        assertGt(sharePrice, 0, "Share price must be positive");
    }

    /// @notice Check share price consistency with total assets
    function _checkSharePriceConsistencyWithAssets() internal view {
        uint256 sharePrice = susx.sharePrice();
        uint256 totalAssets = susx.totalAssets();
        uint256 totalSupply = susx.totalSupply();

        // If there are assets, share price should be very close to expected
        if (totalAssets > 0) {
            uint256 expectedPrice = (totalAssets * 1e18) / totalSupply;

            // Allow only minimal tolerance for rounding errors (0.1%)
            uint256 minAllowedPrice = expectedPrice * 999 / 1000; // 99.9%
            uint256 maxAllowedPrice = expectedPrice * 1001 / 1000; // 100.1%

            assertGe(sharePrice, minAllowedPrice, "Share price too low relative to assets");
            assertLe(sharePrice, maxAllowedPrice, "Share price too high relative to assets");
        }
    }

    /// @notice Check share price consistency with USX price
    function _checkSharePriceConsistencyWithUSX() internal view {
        uint256 sharePrice = susx.sharePrice();
        uint256 usxPrice = usx.usxPrice();

        if (usxPrice > 0) {
            // Allow only minimal tolerance for fees/rounding (0.5%)
            uint256 minAllowedPrice = usxPrice * 995 / 1000; // 99.5% (allowing for withdrawal fees)
            uint256 maxAllowedPrice = usxPrice * 1005 / 1000; // 100.5% (allowing for small rewards)

            assertGe(sharePrice, minAllowedPrice, "Share price too low compared to USX price");
            assertLe(sharePrice, maxAllowedPrice, "Share price too high compared to USX price");
        }
    }

    /// @notice Check share price bounds
    function _checkSharePriceBounds() internal view {
        uint256 sharePrice = susx.sharePrice();
        // Share price should not exceed reasonable bounds
        // Maximum reasonable share price: 10 USDC equivalent (much more conservative)
        assertLe(sharePrice, 10e18, "Share price exceeds maximum reasonable value");
    }

    /// @notice Invariant: Accounting must be consistent
    function invariant_accounting_consistency() public view {
        // Check that total supply equals sum of individual balances
        uint256 totalSupply = usx.totalSupply();
        uint256 sumOfBalances = usx.balanceOf(address(treasury)) + usx.balanceOf(address(susx));

        // Add balances of test users
        for (uint256 i = 0; i < NUM_TEST_USERS; i++) {
            sumOfBalances += usx.balanceOf(testUsers[i]);
        }

        assertEq(totalSupply, sumOfBalances, "USX accounting inconsistency");
    }

    /// @notice Invariant: Peg should be stable in normal conditions
    function invariant_peg_price_stability() public view {
        // Only check in normal conditions (not during crisis)
        if (!isInCrisisState()) {
            assertEq(usx.usxPrice(), 1e18, "Peg should be 1:1 in normal conditions");
        }
    }

    /// @notice Invariant: Leverage must always be within limits
    function invariant_leverage_limit() public {
        uint256 maxLeverage = getMaxLeverage();
        uint256 currentAllocation = treasury.assetManagerUSDC();
        assertLe(currentAllocation, maxLeverage, "Asset manager allocation exceeds max leverage");
    }

    /// @notice Invariant: Withdrawal requests must be valid
    function invariant_withdrawal_requests_valid() public view {
        uint256 totalWithdrawalRequests = 0;
        uint256 totalClaimed = 0;

        // Check all withdrawal requests
        for (uint256 i = 0; i < susx.withdrawalIdCounter(); i++) {
            sUSX.WithdrawalRequest memory request = susx.withdrawalRequests(i);
            if (request.user != address(0)) {
                totalWithdrawalRequests += request.amount;
                if (request.claimed) {
                    totalClaimed += request.amount;
                }
            }
        }

        // Total claimed should not exceed total requested
        assertLe(totalClaimed, totalWithdrawalRequests, "More shares claimed than requested");
    }

    /// @notice Invariant: Measure and track rounding errors down to wei precision
    /// @dev This invariant helps identify exact precision loss in every calculation
    function invariant_rounding_error_tracking() public view {
        if (usx.totalSupply() == 0) return; // Skip initial state

        _checkPegRoundingError();
        _checkSharePriceRoundingError();
        _checkFeeRoundingError();
    }

    /// @notice Check peg calculation rounding error
    function _checkPegRoundingError() internal view {
        uint256 totalUSDCoutstanding =
            usdc.balanceOf(address(treasury)) + treasury.assetManagerUSDC() + usdc.balanceOf(address(usx));
        uint256 scaledUSDC = totalUSDCoutstanding * DECIMAL_SCALE_FACTOR;
        uint256 expectedPeg = scaledUSDC / usx.totalSupply();
        uint256 actualPeg = usx.usxPrice();
        uint256 pegRoundingError = actualPeg > expectedPeg ? actualPeg - expectedPeg : expectedPeg - actualPeg;

        // Peg should be very close to expected (max 1 wei error)
        assertLe(pegRoundingError, 1, "Peg calculation error too large");
    }

    /// @notice Check share price calculation rounding error
    function _checkSharePriceRoundingError() internal view {
        if (susx.totalSupply() > 0) {
            uint256 expectedSharePrice = (susx.totalAssets() * 1e18) / susx.totalSupply();
            uint256 actualSharePrice = susx.sharePrice();
            uint256 sharePriceRoundingError = actualSharePrice > expectedSharePrice
                ? actualSharePrice - expectedSharePrice
                : expectedSharePrice - actualSharePrice;

            assertLe(sharePriceRoundingError, 1, "Share price rounding error should be <= 1 wei");
        }
    }

    /// @notice Check fee calculation rounding error
    function _checkFeeRoundingError() internal view {
        uint256 testAmount = 1000e18; // 1000 USX
        uint256 expectedFee = testAmount * susx.withdrawalFeeFraction() / 100000;
        uint256 actualFee = susx.withdrawalFee(testAmount);
        uint256 feeRoundingError = actualFee > expectedFee ? actualFee - expectedFee : expectedFee - actualFee;

        assertEq(feeRoundingError, 0, "Fee calculation should be exact - no rounding allowed");
    }

    /*=========================== Fuzzing Functions =========================*/

    /// @notice Random time advancement for fuzzing
    /// @dev Foundry will call this with random parameters to simulate time progression
    function fuzz_advance_time(uint256 timeAdvance) public {
        // Bound the time advancement to reasonable values (1 hour to 40 days)
        timeAdvance = bound(timeAdvance, 3600, 40 days);

        // Advance both timestamp and block number
        vm.warp(block.timestamp + timeAdvance);
        vm.roll(block.number + (timeAdvance / 12)); // Assuming 12-second block time
    }

    /// @notice Random USX deposit function for fuzzing
    function fuzz_usx_deposit(uint256 amount) public advanceTimeRandomly {
        amount = bound(amount, 1e6, type(uint256).max); // 1 USDC to maximum possible

        // Get a random user
        address randomUser = getRandomUser();

        // Only proceed if user has enough USDC and is whitelisted
        if (usdc.balanceOf(randomUser) >= amount && usx.whitelistedUsers(randomUser)) {
            vm.prank(randomUser);
            usx.deposit(amount);
        }
    }

    /// @notice Random USX withdrawal request function for fuzzing
    function fuzz_usx_request_withdrawal(uint256 amount) public advanceTimeRandomly {
        amount = bound(amount, 1e18, type(uint256).max); // 1 USX to maximum possible

        // Get a random user
        address randomUser = getRandomUser();

        // Only proceed if user has enough USX and withdrawals aren't frozen
        if (usx.balanceOf(randomUser) >= amount && !usx.withdrawalsFrozen()) {
            vm.prank(randomUser);
            usx.requestUSDC(amount);
        }
    }

    /// @notice Random USX withdrawal claim function for fuzzing
    function fuzz_usx_claim_withdrawal() public advanceTimeRandomly {
        // Get a random user
        address randomUser = getRandomUser();

        // Only proceed if user has outstanding withdrawal requests
        if (usx.outstandingWithdrawalRequests(randomUser) > 0) {
            vm.prank(randomUser);
            usx.claimUSDC();
        }
    }

    /// @notice Random sUSX deposit function for fuzzing
    function fuzz_susx_deposit(uint256 amount) public advanceTimeRandomly {
        // Bound the amount to reasonable values
        amount = bound(amount, 1e18, 1000000e18); // 1 USX to 1M USX

        // Get a random user
        address randomUser = getRandomUser();

        // Only proceed if user has enough USX
        if (usx.balanceOf(randomUser) >= amount) {
            vm.prank(randomUser);
            susx.deposit(amount, randomUser);
        }
    }

    /// @notice Random sUSX withdraw function for fuzzing
    function fuzz_susx_withdraw(uint256 shares) public advanceTimeRandomly {
        // Bound the amount to reasonable values
        shares = bound(shares, 1e18, 1000000e18); // 1 share to 1M shares

        // Get a random user
        address randomUser = getRandomUser();

        // Only proceed if user has enough shares
        if (susx.balanceOf(randomUser) >= shares) {
            vm.prank(randomUser);
            susx.withdraw(shares, randomUser, randomUser);
        }
    }

    /// @notice Random sUSX withdrawal claim function for fuzzing
    function fuzz_susx_claim_withdrawal(uint256 withdrawalId) public advanceTimeRandomly {
        // Bound the withdrawal ID to reasonable values
        withdrawalId = bound(withdrawalId, 0, susx.withdrawalIdCounter());

        // Only proceed if withdrawal exists and is unclaimed
        if (withdrawalId < susx.withdrawalIdCounter()) {
            sUSX.WithdrawalRequest memory request = susx.withdrawalRequests(withdrawalId);
            if (!request.claimed) {
                // Check if the withdrawal belongs to any of our test users
                bool isTestUser = false;
                for (uint256 i = 0; i < NUM_TEST_USERS; i++) {
                    if (request.user == testUsers[i]) {
                        isTestUser = true;
                        break;
                    }
                }

                if (isTestUser) {
                    vm.prank(request.user);
                    susx.claimWithdraw(withdrawalId);
                }
            }
        }
    }

    /// @notice Random profit report function for fuzzing
    function fuzz_report_profits(uint256 totalBalance) public advanceTimeRandomly {
        totalBalance = bound(totalBalance, 1000e6, type(uint256).max); // Allow maximum possible profit

        vm.prank(address(mockAssetManager));
        bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportProfits.selector, totalBalance);
        (bool success,) = address(treasury).call(data);
        require(success, "Profit report failed");
    }

    /// @notice Random loss report function for fuzzing
    /// @dev Foundry will call this with random parameters
    function fuzz_report_losses(uint256 totalBalance) public advanceTimeRandomly {
        totalBalance = bound(totalBalance, 0, type(uint256).max); // Allow maximum possible loss

        vm.prank(address(mockAssetManager));
        bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, totalBalance);
        (bool success,) = address(treasury).call(data);
        require(success, "Loss report failed");
    }

    /// @notice Random asset manager transfer to function for fuzzing
    function fuzz_transfer_usdc_to_asset_manager(uint256 amount) public advanceTimeRandomly {
        amount = bound(amount, 1000e6, type(uint256).max); // Allow maximum possible transfer

        // Only proceed if treasury has enough USDC
        if (usdc.balanceOf(address(treasury)) >= amount) {
            vm.prank(address(mockAssetManager));
            bytes memory data =
                abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector, amount);
            (bool success,) = address(treasury).call(data);
            require(success, "Transfer to asset manager failed");
        }
    }

    /// @notice Random asset manager transfer from function for fuzzing
    function fuzz_transfer_usdc_from_asset_manager(uint256 amount) public advanceTimeRandomly {
        amount = bound(amount, 1000e6, type(uint256).max); // Allow maximum possible transfer

        // Only proceed if asset manager has enough USDC
        if (treasury.assetManagerUSDC() >= amount) {
            vm.prank(address(mockAssetManager));
            bytes memory data =
                abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCFromAssetManager.selector, amount);
            (bool success,) = address(treasury).call(data);
            require(success, "Transfer from asset manager failed");
        }
    }

    /// @notice Random governance parameter update for fuzzing
    function fuzz_update_governance_params(uint256 paramType, uint256 newValue) public advanceTimeRandomly {
        paramType = bound(paramType, 0, 1); // 0: buffer renewal rate, 1: buffer target fraction
        newValue = bound(newValue, 0, type(uint256).max); // Allow maximum possible values

        vm.prank(governance);

        if (paramType == 0) {
            // Update buffer renewal rate
            bytes memory data = abi.encodeWithSelector(InsuranceBufferFacet.setBufferRenewalRate.selector, newValue);
            (bool success,) = address(treasury).call(data);
            require(success, "Buffer renewal rate update failed");
        } else if (paramType == 1) {
            // Update buffer target fraction
            bytes memory data = abi.encodeWithSelector(InsuranceBufferFacet.setBufferTargetFraction.selector, newValue);
            (bool success,) = address(treasury).call(data);
            require(success, "Buffer target fraction update failed");
        }
    }

    /// @notice Test extreme loss scenarios that could break the peg
    function fuzz_extreme_loss_scenario(uint256 lossAmount) public advanceTimeRandomly {
        // Test losses that could potentially break the peg or deplete the buffer
        // This is specifically designed to trigger crisis conditions
        lossAmount = bound(lossAmount, 0, type(uint256).max);

        // First, ensure we have some assets to lose
        if (treasury.assetManagerUSDC() > 0) {
            vm.prank(address(mockAssetManager));
            bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, lossAmount);
            (bool success,) = address(treasury).call(data);
            require(success, "Extreme loss report failed");
        }
    }

    /// @notice Test extreme profit scenarios that could cause overflow
    function fuzz_extreme_profit_scenario(uint256 profitAmount) public advanceTimeRandomly {
        // Test profits that could potentially cause overflow or extreme share price changes
        profitAmount = bound(profitAmount, 0, type(uint256).max);

        vm.prank(address(mockAssetManager));
        bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportProfits.selector, profitAmount);
        (bool success,) = address(treasury).call(data);
        require(success, "Extreme profit report failed");
    }

    /// @notice Test massive withdrawals that could trigger crisis conditions
    function fuzz_massive_withdrawal_scenario(uint256 withdrawalAmount) public advanceTimeRandomly {
        // Test withdrawals that could potentially break the peg or freeze withdrawals
        withdrawalAmount = bound(withdrawalAmount, 1e18, type(uint256).max);

        // Get a random user
        address randomUser = getRandomUser();

        // Only proceed if user has enough USX and withdrawals aren't frozen
        if (usx.balanceOf(randomUser) >= withdrawalAmount && !usx.withdrawalsFrozen()) {
            vm.prank(randomUser);
            usx.requestUSDC(withdrawalAmount);
        }
    }

    /// @notice Test extreme leverage scenarios
    function fuzz_extreme_leverage_scenario(uint256 transferAmount) public advanceTimeRandomly {
        // Test transfers that could potentially exceed max leverage or cause overflow
        transferAmount = bound(transferAmount, 1000e6, type(uint256).max);

        // Only proceed if treasury has enough USDC
        if (usdc.balanceOf(address(treasury)) >= transferAmount) {
            vm.prank(address(mockAssetManager));
            bytes memory data =
                abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector, transferAmount);
            (bool success,) = address(treasury).call(data);
            require(success, "Extreme leverage transfer failed");
        }
    }

    /*=========================== Helper Functions =========================*/

    /// @notice Detects if system is in crisis state
    function isInCrisisState() public view returns (bool) {
        return usx.usxPrice() < 1e18 || usx.withdrawalsFrozen();
    }

    /// @notice Gets the current max leverage
    function getMaxLeverage() public returns (uint256) {
        // Call maxLeverage through the diamond proxy
        bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.maxLeverage.selector);
        (bool success, bytes memory result) = address(treasury).call(data);

        if (success) {
            return abi.decode(result, (uint256));
        } else {
            // If maxLeverage function doesn't exist, return a reasonable default
            return 1000000e6; // 1M USDC default max leverage
        }
    }
}
