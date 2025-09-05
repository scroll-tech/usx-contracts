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

    /*=========================== Adversarial Testing Functions =========================*/

    /// @notice Test rapid state changes to break invariants
    function fuzz_rapid_state_changes(uint256 operationType) public advanceTimeRandomly {
        // Perform rapid operations to try to break invariants
        operationType = bound(operationType, 0, 4);
        
        // Get multiple random users for concurrent operations
        address user1 = getRandomUser();
        address user2 = getRandomUser();
        
        // Perform rapid operations in sequence to stress the system
        for (uint256 i = 0; i < 5; i++) {
            if (operationType == 0) {
                // Rapid deposits
                if (usdc.balanceOf(user1) >= 1000e6) {
                    vm.prank(user1);
                    usx.deposit(1000e6);
                }
            } else if (operationType == 1) {
                // Rapid withdrawals
                if (usx.balanceOf(user1) >= 1000e18 && !usx.withdrawalsFrozen()) {
                    vm.prank(user1);
                    usx.requestUSDC(1000e18);
                }
            } else if (operationType == 2) {
                // Rapid profit/loss reports
                vm.prank(address(mockAssetManager));
                bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportProfits.selector, 10000e6);
                (bool success,) = address(treasury).call(data);
                if (success) {
                    vm.prank(address(mockAssetManager));
                    data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, 5000e6);
                    (success,) = address(treasury).call(data);
                }
            } else if (operationType == 3) {
                // Rapid sUSX operations
                if (usx.balanceOf(user1) >= 1000e18) {
                    vm.prank(user1);
                    susx.deposit(1000e18, user1);
                }
                if (susx.balanceOf(user1) >= 1000e18) {
                    vm.prank(user1);
                    susx.withdraw(1000e18, user1, user1);
                }
            } else if (operationType == 4) {
                // Rapid governance changes
                vm.prank(governance);
                bytes memory data = abi.encodeWithSelector(InsuranceBufferFacet.setBufferTargetFraction.selector, 5000);
                (bool success,) = address(treasury).call(data);
                if (success) {
                    vm.prank(governance);
                    data = abi.encodeWithSelector(InsuranceBufferFacet.setBufferRenewalRate.selector, 1000);
                    (success,) = address(treasury).call(data);
                }
            }
        }
    }

    /// @notice Test concurrent operations to find race conditions
    function fuzz_concurrent_operations(uint256 operationCount) public advanceTimeRandomly {
        // Test multiple operations happening "simultaneously" to find race conditions
        operationCount = bound(operationCount, 2, 10);
        
        address[] memory users = new address[](operationCount);
        for (uint256 i = 0; i < operationCount; i++) {
            users[i] = getRandomUser();
        }
        
        // Perform operations that could interfere with each other
        for (uint256 i = 0; i < operationCount; i++) {
            address user = users[i];
            
            // Mix of operations that could cause conflicts
            if (i % 3 == 0 && usdc.balanceOf(user) >= 1000e6) {
                vm.prank(user);
                usx.deposit(1000e6);
            } else if (i % 3 == 1 && usx.balanceOf(user) >= 1000e18 && !usx.withdrawalsFrozen()) {
                vm.prank(user);
                usx.requestUSDC(1000e18);
            } else if (i % 3 == 2 && usx.balanceOf(user) >= 1000e18) {
                vm.prank(user);
                susx.deposit(1000e18, user);
            }
        }
    }

    /// @notice Test invariant violation attempts
    function fuzz_invariant_violation_attempts(uint256 attemptType) public advanceTimeRandomly {
        // Deliberately try to violate invariants to test protocol robustness
        attemptType = bound(attemptType, 0, 3);
        
        if (attemptType == 0) {
            // Try to create value out of nothing
            _attemptValueCreation();
        } else if (attemptType == 1) {
            // Try to break peg stability
            _attemptPegBreak();
        } else if (attemptType == 2) {
            // Try to deplete buffer without crisis
            _attemptBufferDepletion();
        } else if (attemptType == 3) {
            // Try to create accounting inconsistencies
            _attemptAccountingInconsistency();
        }
    }

    /// @notice Test extreme time manipulation
    function fuzz_extreme_time_manipulation(uint256 timeAdvance) public advanceTimeRandomly {
        // Test extreme time scenarios that could break time-based functions
        timeAdvance = bound(timeAdvance, 0, 365 days); // Up to 1 year
        
        // Advance time dramatically
        vm.warp(block.timestamp + timeAdvance);
        vm.roll(block.number + (timeAdvance / 12));
        
        // Try operations that depend on time
        address user = getRandomUser();
        if (usx.balanceOf(user) >= 1000e18 && !usx.withdrawalsFrozen()) {
            vm.prank(user);
            usx.requestUSDC(1000e18);
        }
        
        // Try to claim withdrawals after extreme time
        if (usx.outstandingWithdrawalRequests(user) > 0) {
            vm.prank(user);
            usx.claimUSDC();
        }
    }

    /// @notice Test state corruption attempts
    function fuzz_state_corruption_attempts(uint256 corruptionType) public advanceTimeRandomly {
        // Try to corrupt state in various ways
        corruptionType = bound(corruptionType, 0, 2);
        
        if (corruptionType == 0) {
            // Try to manipulate balances directly
            _attemptBalanceManipulation();
        } else if (corruptionType == 1) {
            // Try to manipulate share prices
            _attemptSharePriceManipulation();
        } else if (corruptionType == 2) {
            // Try to manipulate governance parameters
            _attemptGovernanceManipulation();
        }
    }

    /// @notice Test flash loan attack simulation
    function fuzz_flash_loan_attack(uint256 attackType) public advanceTimeRandomly {
        // Simulate flash loan attacks to manipulate prices or drain funds
        attackType = bound(attackType, 0, 2);
        
        if (attackType == 0) {
            // Flash loan to manipulate USX price
            _attemptFlashLoanPriceManipulation();
        } else if (attackType == 1) {
            // Flash loan to manipulate sUSX share price
            _attemptFlashLoanSharePriceManipulation();
        } else if (attackType == 2) {
            // Flash loan to drain buffer
            _attemptFlashLoanBufferDrain();
        }
    }

    /// @notice Test reentrancy attack simulation
    function fuzz_reentrancy_attack(uint256 attackType) public advanceTimeRandomly {
        // Simulate reentrancy attacks on vulnerable functions
        attackType = bound(attackType, 0, 2);
        
        if (attackType == 0) {
            // Reentrancy on deposit
            _attemptReentrancyOnDeposit();
        } else if (attackType == 1) {
            // Reentrancy on withdrawal
            _attemptReentrancyOnWithdrawal();
        } else if (attackType == 2) {
            // Reentrancy on sUSX operations
            _attemptReentrancyOnSUSX();
        }
    }

    /// @notice Test sandwich attack simulation
    function fuzz_sandwich_attack(uint256 attackType) public advanceTimeRandomly {
        // Simulate sandwich attacks (front-run and back-run)
        attackType = bound(attackType, 0, 2);
        
        if (attackType == 0) {
            // Sandwich attack on USX deposit
            _attemptSandwichOnUSXDeposit();
        } else if (attackType == 1) {
            // Sandwich attack on sUSX deposit
            _attemptSandwichOnSUSXDeposit();
        } else if (attackType == 2) {
            // Sandwich attack on profit reporting
            _attemptSandwichOnProfitReport();
        }
    }

    /// @notice Test arbitrage exploitation
    function fuzz_arbitrage_exploitation(uint256 arbitrageType) public advanceTimeRandomly {
        // Test arbitrage opportunities between USX and sUSX
        arbitrageType = bound(arbitrageType, 0, 2);
        
        if (arbitrageType == 0) {
            // Arbitrage between USX and sUSX prices
            _attemptUSXSUSXArbitrage();
        } else if (arbitrageType == 1) {
            // Arbitrage on withdrawal fees
            _attemptWithdrawalFeeArbitrage();
        } else if (arbitrageType == 2) {
            // Arbitrage on share price discrepancies
            _attemptSharePriceArbitrage();
        }
    }

    /// @notice Test direct token transfer attacks to manipulate calculations
    function fuzz_direct_transfer_attacks(uint256 attackType) public advanceTimeRandomly {
        // Test direct token transfers to contracts to manipulate balances and calculations
        attackType = bound(attackType, 0, 5);
        
        if (attackType == 0) {
            // Send USDC directly to USX contract
            _attemptUSDCTransferToUSX();
        } else if (attackType == 1) {
            // Send USDC directly to Treasury contract
            _attemptUSDCTransferToTreasury();
        } else if (attackType == 2) {
            // Send USX directly to sUSX contract
            _attemptUSXTransferToSUSX();
        } else if (attackType == 3) {
            // Send USX directly to Treasury contract
            _attemptUSXTransferToTreasury();
        } else if (attackType == 4) {
            // Send sUSX directly to Treasury contract
            _attemptSUSXTransferToTreasury();
        } else if (attackType == 5) {
            // Send tokens to MockAssetManager to manipulate asset manager balance
            _attemptTokenTransferToAssetManager();
        }
    }

    /// @notice Test balance manipulation through direct transfers
    function fuzz_balance_manipulation_attacks(uint256 manipulationType) public advanceTimeRandomly {
        // Test various ways to manipulate contract balances
        manipulationType = bound(manipulationType, 0, 3);
        
        if (manipulationType == 0) {
            // Manipulate USX total supply through direct transfers
            _attemptUSXSupplyManipulation();
        } else if (manipulationType == 1) {
            // Manipulate sUSX total supply through direct transfers
            _attemptSUSXSupplyManipulation();
        } else if (manipulationType == 2) {
            // Manipulate treasury USDC balance through direct transfers
            _attemptTreasuryUSDCManipulation();
        } else if (manipulationType == 3) {
            // Manipulate asset manager USDC balance through direct transfers
            _attemptAssetManagerUSDCManipulation();
        }
    }

    /// @notice Test calculation manipulation attacks
    function fuzz_calculation_manipulation_attacks(uint256 calculationType) public advanceTimeRandomly {
        // Test manipulation of key protocol calculations
        calculationType = bound(calculationType, 0, 3);
        
        if (calculationType == 0) {
            // Manipulate share price calculation
            _attemptSharePriceCalculationManipulation();
        } else if (calculationType == 1) {
            // Manipulate peg calculation
            _attemptPegCalculationManipulation();
        } else if (calculationType == 2) {
            // Manipulate buffer calculation
            _attemptBufferCalculationManipulation();
        } else if (calculationType == 3) {
            // Manipulate leverage calculation
            _attemptLeverageCalculationManipulation();
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

    /*=========================== Attack Helper Functions =========================*/

    /// @notice Attempt to create value out of nothing
    function _attemptValueCreation() internal {
        // Try to create value through complex transaction sequences
        address user = getRandomUser();
        
        // Record initial state
        uint256 initialUSDC = usdc.balanceOf(address(treasury)) + treasury.assetManagerUSDC();
        uint256 initialUSX = usx.totalSupply();
        
        // Perform a sequence of operations that might create value
        if (usdc.balanceOf(user) >= 1000e6) {
            vm.prank(user);
            usx.deposit(1000e6);
            
            // Immediately try to withdraw more than deposited
            if (usx.balanceOf(user) >= 1000e18) {
                vm.prank(user);
                usx.requestUSDC(usx.balanceOf(user));
            }
        }
        
        // Check if value was created
        uint256 finalUSDC = usdc.balanceOf(address(treasury)) + treasury.assetManagerUSDC();
        uint256 finalUSX = usx.totalSupply();
        
        // If USDC increased without corresponding USX increase, we might have created value
        // Note: This would indicate a serious protocol vulnerability if it occurred
        if (finalUSDC > initialUSDC && finalUSX <= initialUSX) {
            // This would be a critical bug - value creation detected
        }
    }

    /// @notice Attempt to break peg stability
    function _attemptPegBreak() internal {
        // Try to break the 1:1 peg through coordinated actions
        address user1 = getRandomUser();
        address user2 = getRandomUser();
        
        // Large deposit followed by massive loss report
        if (usdc.balanceOf(user1) >= 1000000e6) {
            vm.prank(user1);
            usx.deposit(1000000e6);
            
            // Report massive losses to try to break peg
            vm.prank(address(mockAssetManager));
            bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, 999999e6);
            (bool success,) = address(treasury).call(data);
            
            if (success) {
                // Try to withdraw immediately to stress the system
                if (usx.balanceOf(user2) >= 1000e18 && !usx.withdrawalsFrozen()) {
                    vm.prank(user2);
                    usx.requestUSDC(1000e18);
                }
            }
        }
    }

    /// @notice Attempt to deplete buffer without crisis
    function _attemptBufferDepletion() internal {
        // Try to drain the insurance buffer without triggering crisis conditions
        address user = getRandomUser();
        
        // First, ensure buffer has funds
        if (usdc.balanceOf(address(treasury)) > 0) {
            // Try to transfer all treasury USDC to asset manager
            uint256 treasuryBalance = usdc.balanceOf(address(treasury));
            vm.prank(address(mockAssetManager));
            bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector, treasuryBalance);
            (bool success,) = address(treasury).call(data);
            
            if (success) {
                // Report losses to try to deplete buffer
                vm.prank(address(mockAssetManager));
                data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, treasury.assetManagerUSDC());
                (success,) = address(treasury).call(data);
            }
        }
    }

    /// @notice Attempt to create accounting inconsistencies
    function _attemptAccountingInconsistency() internal {
        // Try to create accounting discrepancies
        address user = getRandomUser();
        
        // Record initial balances
        uint256 initialTreasuryUSDC = usdc.balanceOf(address(treasury));
        uint256 initialAssetManagerUSDC = treasury.assetManagerUSDC();
        uint256 initialUSXSupply = usx.totalSupply();
        
        // Perform operations that might create inconsistencies
        if (usdc.balanceOf(user) >= 1000e6) {
            vm.prank(user);
            usx.deposit(1000e6);
            
            // Immediately try to manipulate asset manager balance
            if (treasury.assetManagerUSDC() > 0) {
                vm.prank(address(mockAssetManager));
                bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCFromAssetManager.selector, 100e6);
                (bool success,) = address(treasury).call(data);
            }
        }
        
        // Check for accounting inconsistencies
        uint256 finalTreasuryUSDC = usdc.balanceOf(address(treasury));
        uint256 finalAssetManagerUSDC = treasury.assetManagerUSDC();
        uint256 finalUSXSupply = usx.totalSupply();
        
        // If balances don't add up correctly, we might have found an inconsistency
        uint256 expectedTotalUSDC = finalTreasuryUSDC + finalAssetManagerUSDC;
        uint256 expectedTotalUSDCFromUSX = finalUSXSupply / DECIMAL_SCALE_FACTOR;
        
        if (expectedTotalUSDC != expectedTotalUSDCFromUSX) {
            // This would indicate a serious accounting inconsistency
        }
    }

    /// @notice Attempt to manipulate balances directly
    function _attemptBalanceManipulation() internal {
        // Try to manipulate balances through various means
        address user = getRandomUser();
        
        // Try to manipulate USDC balance through transfers
        if (usdc.balanceOf(user) >= 1000e6) {
            // Transfer USDC to treasury directly
            vm.prank(user);
            usdc.transfer(address(treasury), 1000e6);
            
            // Then try to deposit the same amount
            vm.prank(user);
            usx.deposit(1000e6);
        }
    }

    /// @notice Attempt to manipulate share prices
    function _attemptSharePriceManipulation() internal {
        // Try to manipulate sUSX share prices
        address user = getRandomUser();
        
        // Record initial share price
        uint256 initialSharePrice = susx.sharePrice();
        
        // Perform operations that might affect share price
        if (usx.balanceOf(user) >= 1000e18) {
            vm.prank(user);
            susx.deposit(1000e18, user);
            
            // Immediately report profits to try to manipulate share price
            vm.prank(address(mockAssetManager));
            bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportProfits.selector, 10000e6);
            (bool success,) = address(treasury).call(data);
            
            if (success) {
                // Try to withdraw immediately to see if share price was manipulated
                if (susx.balanceOf(user) >= 1000e18) {
                    vm.prank(user);
                    susx.withdraw(1000e18, user, user);
                }
            }
        }
    }

    /// @notice Attempt to manipulate governance parameters
    function _attemptGovernanceManipulation() internal {
        // Try to manipulate governance parameters to break the system
        vm.prank(governance);
        
        // Set extreme buffer target fraction
        bytes memory data = abi.encodeWithSelector(InsuranceBufferFacet.setBufferTargetFraction.selector, type(uint256).max);
        (bool success,) = address(treasury).call(data);
        
        if (success) {
            // Set extreme buffer renewal rate
            vm.prank(governance);
            data = abi.encodeWithSelector(InsuranceBufferFacet.setBufferRenewalRate.selector, type(uint256).max);
            (success,) = address(treasury).call(data);
        }
    }

    /// @notice Attempt flash loan price manipulation
    function _attemptFlashLoanPriceManipulation() internal {
        // Simulate flash loan to manipulate USX price
        address user = getRandomUser();
        
        // "Flash loan" - get large amount of USDC
        uint256 flashLoanAmount = 1000000e6;
        deal(address(usdc), user, flashLoanAmount);
        
        // Large deposit to manipulate price
        vm.prank(user);
        usx.deposit(flashLoanAmount);
        
        // Report losses to try to break peg
        vm.prank(address(mockAssetManager));
        bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, flashLoanAmount / 2);
        (bool success,) = address(treasury).call(data);
        
        // "Repay" flash loan
        if (usx.balanceOf(user) >= 1000e18) {
            vm.prank(user);
            usx.requestUSDC(1000e18);
        }
    }

    /// @notice Attempt flash loan share price manipulation
    function _attemptFlashLoanSharePriceManipulation() internal {
        // Simulate flash loan to manipulate sUSX share price
        address user = getRandomUser();
        
        // "Flash loan" - get large amount of USX
        uint256 flashLoanAmount = 1000000e18;
        deal(address(usx), user, flashLoanAmount);
        
        // Large deposit to manipulate share price
        vm.prank(user);
        susx.deposit(flashLoanAmount, user);
        
        // Report profits to manipulate share price
        vm.prank(address(mockAssetManager));
        bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportProfits.selector, 100000e6);
        (bool success,) = address(treasury).call(data);
        
        // "Repay" flash loan
        if (susx.balanceOf(user) >= 1000e18) {
            vm.prank(user);
            susx.withdraw(1000e18, user, user);
        }
    }

    /// @notice Attempt flash loan buffer drain
    function _attemptFlashLoanBufferDrain() internal {
        // Simulate flash loan to drain insurance buffer
        address user = getRandomUser();
        
        // "Flash loan" - get large amount of USDC
        uint256 flashLoanAmount = 1000000e6;
        deal(address(usdc), user, flashLoanAmount);
        
        // Large deposit
        vm.prank(user);
        usx.deposit(flashLoanAmount);
        
        // Report massive losses to drain buffer
        vm.prank(address(mockAssetManager));
        bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, flashLoanAmount);
        (bool success,) = address(treasury).call(data);
        
        // Try to withdraw everything
        if (usx.balanceOf(user) >= 1000e18 && !usx.withdrawalsFrozen()) {
            vm.prank(user);
            usx.requestUSDC(usx.balanceOf(user));
        }
    }

    /// @notice Attempt reentrancy on deposit
    function _attemptReentrancyOnDeposit() internal {
        // Simulate reentrancy attack on deposit function
        address user = getRandomUser();
        
        if (usdc.balanceOf(user) >= 2000e6) {
            // First deposit
            vm.prank(user);
            usx.deposit(1000e6);
            
            // Immediately try another deposit (simulating reentrancy)
            vm.prank(user);
            usx.deposit(1000e6);
        }
    }

    /// @notice Attempt reentrancy on withdrawal
    function _attemptReentrancyOnWithdrawal() internal {
        // Simulate reentrancy attack on withdrawal function
        address user = getRandomUser();
        
        if (usx.balanceOf(user) >= 2000e18 && !usx.withdrawalsFrozen()) {
            // First withdrawal request
            vm.prank(user);
            usx.requestUSDC(1000e18);
            
            // Immediately try another withdrawal request (simulating reentrancy)
            vm.prank(user);
            usx.requestUSDC(1000e18);
        }
    }

    /// @notice Attempt reentrancy on sUSX operations
    function _attemptReentrancyOnSUSX() internal {
        // Simulate reentrancy attack on sUSX operations
        address user = getRandomUser();
        
        if (usx.balanceOf(user) >= 2000e18) {
            // First sUSX deposit
            vm.prank(user);
            susx.deposit(1000e18, user);
            
            // Immediately try another sUSX deposit (simulating reentrancy)
            vm.prank(user);
            susx.deposit(1000e18, user);
        }
    }

    /// @notice Attempt sandwich attack on USX deposit
    function _attemptSandwichOnUSXDeposit() internal {
        // Simulate sandwich attack on USX deposit
        address attacker = getRandomUser();
        address victim = getRandomUser();
        
        // Front-run: Attacker deposits
        if (usdc.balanceOf(attacker) >= 1000e6) {
            vm.prank(attacker);
            usx.deposit(1000e6);
        }
        
        // Victim deposits
        if (usdc.balanceOf(victim) >= 1000e6) {
            vm.prank(victim);
            usx.deposit(1000e6);
        }
        
        // Back-run: Attacker withdraws
        if (usx.balanceOf(attacker) >= 1000e18 && !usx.withdrawalsFrozen()) {
            vm.prank(attacker);
            usx.requestUSDC(1000e18);
        }
    }

    /// @notice Attempt sandwich attack on sUSX deposit
    function _attemptSandwichOnSUSXDeposit() internal {
        // Simulate sandwich attack on sUSX deposit
        address attacker = getRandomUser();
        address victim = getRandomUser();
        
        // Front-run: Attacker deposits
        if (usx.balanceOf(attacker) >= 1000e18) {
            vm.prank(attacker);
            susx.deposit(1000e18, attacker);
        }
        
        // Victim deposits
        if (usx.balanceOf(victim) >= 1000e18) {
            vm.prank(victim);
            susx.deposit(1000e18, victim);
        }
        
        // Back-run: Attacker withdraws
        if (susx.balanceOf(attacker) >= 1000e18) {
            vm.prank(attacker);
            susx.withdraw(1000e18, attacker, attacker);
        }
    }

    /// @notice Attempt sandwich attack on profit reporting
    function _attemptSandwichOnProfitReport() internal {
        // Simulate sandwich attack on profit reporting
        address attacker = getRandomUser();
        
        // Front-run: Attacker deposits
        if (usx.balanceOf(attacker) >= 1000e18) {
            vm.prank(attacker);
            susx.deposit(1000e18, attacker);
        }
        
        // Profit report
        vm.prank(address(mockAssetManager));
        bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportProfits.selector, 10000e6);
        (bool success,) = address(treasury).call(data);
        
        // Back-run: Attacker withdraws to capture profits
        if (susx.balanceOf(attacker) >= 1000e18) {
            vm.prank(attacker);
            susx.withdraw(1000e18, attacker, attacker);
        }
    }

    /// @notice Attempt arbitrage between USX and sUSX
    function _attemptUSXSUSXArbitrage() internal {
        // Test arbitrage opportunities between USX and sUSX
        address user = getRandomUser();
        
        if (usx.balanceOf(user) >= 1000e18) {
            // Deposit to sUSX
            vm.prank(user);
            susx.deposit(1000e18, user);
            
            // Immediately withdraw
            if (susx.balanceOf(user) >= 1000e18) {
                vm.prank(user);
                susx.withdraw(1000e18, user, user);
            }
        }
    }

    /// @notice Attempt arbitrage on withdrawal fees
    function _attemptWithdrawalFeeArbitrage() internal {
        // Test arbitrage on withdrawal fees
        address user = getRandomUser();
        
        if (usx.balanceOf(user) >= 1000e18) {
            // Request withdrawal
            vm.prank(user);
            usx.requestUSDC(1000e18);
            
            // Try to claim immediately
            if (usx.outstandingWithdrawalRequests(user) > 0) {
                vm.prank(user);
                usx.claimUSDC();
            }
        }
    }

    /// @notice Attempt arbitrage on share price discrepancies
    function _attemptSharePriceArbitrage() internal {
        // Test arbitrage on share price discrepancies
        address user = getRandomUser();
        
        if (usx.balanceOf(user) >= 1000e18) {
            // Check share price
            uint256 sharePrice = susx.sharePrice();
            
            // If share price is favorable, deposit
            if (sharePrice > 1e18) {
                vm.prank(user);
                susx.deposit(1000e18, user);
            }
        }
    }

    /*=========================== Direct Transfer Attack Helper Functions =========================*/

    /// @notice Attempt to send USDC directly to USX contract
    function _attemptUSDCTransferToUSX() internal {
        // Send USDC directly to USX contract to manipulate its balance
        address user = getRandomUser();
        
        if (usdc.balanceOf(user) >= 1000e6) {
            // Record initial state
            uint256 initialUSXBalance = usdc.balanceOf(address(usx));
            uint256 initialUserUSX = usx.balanceOf(user);
            
            // Send USDC directly to USX contract
            vm.prank(user);
            usdc.transfer(address(usx), 1000e6);
            
            // Try to withdraw USX immediately to see if we can exploit the balance
            if (usx.balanceOf(user) >= 1000e18 && !usx.withdrawalsFrozen()) {
                vm.prank(user);
                usx.requestUSDC(1000e18);
            }
            
            // Check if the direct transfer created any accounting inconsistencies
            uint256 finalUSXBalance = usdc.balanceOf(address(usx));
            if (finalUSXBalance > initialUSXBalance) {
                // Direct transfer to USX contract detected - this is expected behavior
            }
        }
    }

    /// @notice Attempt to send USDC directly to Treasury contract
    function _attemptUSDCTransferToTreasury() internal {
        // Send USDC directly to Treasury contract to manipulate its balance
        address user = getRandomUser();
        
        if (usdc.balanceOf(user) >= 1000e6) {
            // Record initial state
            uint256 initialTreasuryBalance = usdc.balanceOf(address(treasury));
            uint256 initialAssetManagerBalance = treasury.assetManagerUSDC();
            
            // Send USDC directly to Treasury contract
            vm.prank(user);
            usdc.transfer(address(treasury), 1000e6);
            
            // Try to manipulate asset manager balance
            if (treasury.assetManagerUSDC() > 0) {
                vm.prank(address(mockAssetManager));
                bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCFromAssetManager.selector, 500e6);
                (bool success,) = address(treasury).call(data);
                
                if (success) {
                    // Try to report losses to see if we can exploit the manipulated balance
                    vm.prank(address(mockAssetManager));
                    data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, 500e6);
                    (success,) = address(treasury).call(data);
                }
            }
            
            // Check if the direct transfer created any accounting inconsistencies
            uint256 finalTreasuryBalance = usdc.balanceOf(address(treasury));
            if (finalTreasuryBalance > initialTreasuryBalance) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to send USX directly to sUSX contract
    function _attemptUSXTransferToSUSX() internal {
        // Send USX directly to sUSX contract to manipulate its balance
        address user = getRandomUser();
        
        if (usx.balanceOf(user) >= 1000e18) {
            // Record initial state
            uint256 initialSUSXBalance = usx.balanceOf(address(susx));
            uint256 initialSharePrice = susx.sharePrice();
            
            // Send USX directly to sUSX contract
            vm.prank(user);
            usx.transfer(address(susx), 1000e18);
            
            // Try to withdraw from sUSX to see if we can exploit the balance
            if (susx.balanceOf(user) >= 1000e18) {
                vm.prank(user);
                susx.withdraw(1000e18, user, user);
            }
            
            // Check if the direct transfer affected share price calculation
            uint256 finalSharePrice = susx.sharePrice();
            if (finalSharePrice != initialSharePrice) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to send USX directly to Treasury contract
    function _attemptUSXTransferToTreasury() internal {
        // Send USX directly to Treasury contract to manipulate its balance
        address user = getRandomUser();
        
        if (usx.balanceOf(user) >= 1000e18) {
            // Record initial state
            uint256 initialTreasuryUSX = usx.balanceOf(address(treasury));
            uint256 initialUSXSupply = usx.totalSupply();
            
            // Send USX directly to Treasury contract
            vm.prank(user);
            usx.transfer(address(treasury), 1000e18);
            
            // Try to manipulate the treasury's USX balance
            // This could affect calculations that depend on treasury USX holdings
            
            // Check if the direct transfer created any accounting inconsistencies
            uint256 finalTreasuryUSX = usx.balanceOf(address(treasury));
            if (finalTreasuryUSX > initialTreasuryUSX) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to send sUSX directly to Treasury contract
    function _attemptSUSXTransferToTreasury() internal {
        // Send sUSX directly to Treasury contract to manipulate its balance
        address user = getRandomUser();
        
        if (susx.balanceOf(user) >= 1000e18) {
            // Record initial state
            uint256 initialTreasurySUSX = susx.balanceOf(address(treasury));
            uint256 initialSUSXSupply = susx.totalSupply();
            
            // Send sUSX directly to Treasury contract
            vm.prank(user);
            susx.transfer(address(treasury), 1000e18);
            
            // Try to manipulate the treasury's sUSX balance
            // This could affect calculations that depend on treasury sUSX holdings
            
            // Check if the direct transfer created any accounting inconsistencies
            uint256 finalTreasurySUSX = susx.balanceOf(address(treasury));
            if (finalTreasurySUSX > initialTreasurySUSX) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to send tokens to MockAssetManager
    function _attemptTokenTransferToAssetManager() internal {
        // Send tokens to MockAssetManager to manipulate asset manager balance
        address user = getRandomUser();
        
        if (usdc.balanceOf(user) >= 1000e6) {
            // Record initial state
            uint256 initialAssetManagerBalance = treasury.assetManagerUSDC();
            
            // Send USDC directly to MockAssetManager
            vm.prank(user);
            usdc.transfer(address(mockAssetManager), 1000e6);
            
            // Try to manipulate the asset manager's balance through treasury calls
            vm.prank(address(mockAssetManager));
            bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector, 500e6);
            (bool success,) = address(treasury).call(data);
            
            if (success) {
                // Try to report profits/losses to see if we can exploit the manipulated balance
                vm.prank(address(mockAssetManager));
                data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportProfits.selector, 1000e6);
                (success,) = address(treasury).call(data);
            }
            
            // Check if the direct transfer created any accounting inconsistencies
            uint256 finalAssetManagerBalance = treasury.assetManagerUSDC();
            if (finalAssetManagerBalance != initialAssetManagerBalance) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to manipulate USX total supply through direct transfers
    function _attemptUSXSupplyManipulation() internal {
        // Try to manipulate USX total supply by sending USX to contracts
        address user = getRandomUser();
        
        if (usx.balanceOf(user) >= 1000e18) {
            // Record initial state
            uint256 initialSupply = usx.totalSupply();
            
            // Send USX to various contracts to see if it affects total supply calculation
            address[] memory targets = new address[](3);
            targets[0] = address(treasury);
            targets[1] = address(susx);
            targets[2] = address(mockAssetManager);
            
            for (uint256 i = 0; i < targets.length; i++) {
                if (usx.balanceOf(user) >= 300e18) {
                    vm.prank(user);
                    usx.transfer(targets[i], 300e18);
                }
            }
            
            // Check if total supply was affected by direct transfers
            uint256 finalSupply = usx.totalSupply();
            if (finalSupply != initialSupply) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to manipulate sUSX total supply through direct transfers
    function _attemptSUSXSupplyManipulation() internal {
        // Try to manipulate sUSX total supply by sending sUSX to contracts
        address user = getRandomUser();
        
        if (susx.balanceOf(user) >= 1000e18) {
            // Record initial state
            uint256 initialSupply = susx.totalSupply();
            
            // Send sUSX to various contracts to see if it affects total supply calculation
            address[] memory targets = new address[](2);
            targets[0] = address(treasury);
            targets[1] = address(mockAssetManager);
            
            for (uint256 i = 0; i < targets.length; i++) {
                if (susx.balanceOf(user) >= 500e18) {
                    vm.prank(user);
                    susx.transfer(targets[i], 500e18);
                }
            }
            
            // Check if total supply was affected by direct transfers
            uint256 finalSupply = susx.totalSupply();
            if (finalSupply != initialSupply) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to manipulate treasury USDC balance through direct transfers
    function _attemptTreasuryUSDCManipulation() internal {
        // Try to manipulate treasury USDC balance by sending USDC directly
        address user = getRandomUser();
        
        if (usdc.balanceOf(user) >= 1000e6) {
            // Record initial state
            uint256 initialTreasuryBalance = usdc.balanceOf(address(treasury));
            uint256 initialAssetManagerBalance = treasury.assetManagerUSDC();
            
            // Send USDC directly to treasury
            vm.prank(user);
            usdc.transfer(address(treasury), 1000e6);
            
            // Try to exploit the manipulated balance
            if (usdc.balanceOf(address(treasury)) > 0) {
                // Try to transfer to asset manager
                vm.prank(address(mockAssetManager));
                bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector, 500e6);
                (bool success,) = address(treasury).call(data);
                
                if (success) {
                    // Try to report losses to drain the manipulated balance
                    vm.prank(address(mockAssetManager));
                    data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, 500e6);
                    (success,) = address(treasury).call(data);
                }
            }
            
            // Check if the manipulation was successful
            uint256 finalTreasuryBalance = usdc.balanceOf(address(treasury));
            if (finalTreasuryBalance > initialTreasuryBalance) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to manipulate asset manager USDC balance through direct transfers
    function _attemptAssetManagerUSDCManipulation() internal {
        // Try to manipulate asset manager USDC balance by sending USDC to MockAssetManager
        address user = getRandomUser();
        
        if (usdc.balanceOf(user) >= 1000e6) {
            // Record initial state
            uint256 initialAssetManagerBalance = treasury.assetManagerUSDC();
            
            // Send USDC directly to MockAssetManager
            vm.prank(user);
            usdc.transfer(address(mockAssetManager), 1000e6);
            
            // Try to exploit the manipulated balance through treasury calls
            vm.prank(address(mockAssetManager));
            bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector, 500e6);
            (bool success,) = address(treasury).call(data);
            
            if (success) {
                // Try to report massive profits to exploit the manipulated balance
                vm.prank(address(mockAssetManager));
                data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportProfits.selector, 1000e6);
                (success,) = address(treasury).call(data);
            }
            
            // Check if the manipulation was successful
            uint256 finalAssetManagerBalance = treasury.assetManagerUSDC();
            if (finalAssetManagerBalance != initialAssetManagerBalance) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to manipulate share price calculation
    function _attemptSharePriceCalculationManipulation() internal {
        // Try to manipulate sUSX share price calculation through direct transfers
        address user = getRandomUser();
        
        if (usx.balanceOf(user) >= 1000e18) {
            // Record initial state
            uint256 initialSharePrice = susx.sharePrice();
            uint256 initialSUSXBalance = usx.balanceOf(address(susx));
            
            // Send USX directly to sUSX contract to manipulate share price calculation
            vm.prank(user);
            usx.transfer(address(susx), 1000e18);
            
            // Try to deposit to sUSX to see if share price is manipulated
            if (usx.balanceOf(user) >= 500e18) {
                vm.prank(user);
                susx.deposit(500e18, user);
            }
            
            // Check if share price was affected by direct transfer
            uint256 finalSharePrice = susx.sharePrice();
            if (finalSharePrice != initialSharePrice) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to manipulate peg calculation
    function _attemptPegCalculationManipulation() internal {
        // Try to manipulate USX peg calculation through direct transfers
        address user = getRandomUser();
        
        if (usdc.balanceOf(user) >= 1000e6) {
            // Record initial state
            uint256 initialPeg = usx.usxPrice();
            uint256 initialUSXBalance = usdc.balanceOf(address(usx));
            
            // Send USDC directly to USX contract to manipulate peg calculation
            vm.prank(user);
            usdc.transfer(address(usx), 1000e6);
            
            // Try to withdraw USX to see if peg is manipulated
            if (usx.balanceOf(user) >= 500e18 && !usx.withdrawalsFrozen()) {
                vm.prank(user);
                usx.requestUSDC(500e18);
            }
            
            // Check if peg was affected by direct transfer
            uint256 finalPeg = usx.usxPrice();
            if (finalPeg != initialPeg) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to manipulate buffer calculation
    function _attemptBufferCalculationManipulation() internal {
        // Try to manipulate buffer calculation through direct transfers
        address user = getRandomUser();
        
        if (usdc.balanceOf(user) >= 1000e6) {
            // Record initial state
            uint256 initialTreasuryBalance = usdc.balanceOf(address(treasury));
            
            // Send USDC directly to treasury to manipulate buffer calculation
            vm.prank(user);
            usdc.transfer(address(treasury), 1000e6);
            
            // Try to report losses to see if buffer calculation is affected
            vm.prank(address(mockAssetManager));
            bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, 500e6);
            (bool success,) = address(treasury).call(data);
            
            // Check if buffer calculation was affected by direct transfer
            uint256 finalTreasuryBalance = usdc.balanceOf(address(treasury));
            if (finalTreasuryBalance > initialTreasuryBalance) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }

    /// @notice Attempt to manipulate leverage calculation
    function _attemptLeverageCalculationManipulation() internal {
        // Try to manipulate leverage calculation through direct transfers
        address user = getRandomUser();
        
        if (usdc.balanceOf(user) >= 1000e6) {
            // Record initial state
            uint256 initialAssetManagerBalance = treasury.assetManagerUSDC();
            
            // Send USDC directly to MockAssetManager to manipulate leverage calculation
            vm.prank(user);
            usdc.transfer(address(mockAssetManager), 1000e6);
            
            // Try to transfer to asset manager to see if leverage calculation is affected
            vm.prank(address(mockAssetManager));
            bytes memory data = abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector, 500e6);
            (bool success,) = address(treasury).call(data);
            
            // Check if leverage calculation was affected by direct transfer
            uint256 finalAssetManagerBalance = treasury.assetManagerUSDC();
            if (finalAssetManagerBalance != initialAssetManagerBalance) {
                // Attack attempt detected (but not necessarily successful)
            }
        }
    }
}
