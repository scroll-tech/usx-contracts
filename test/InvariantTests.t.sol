// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
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
contract InvariantTests is Test {
    uint256 public constant DECIMAL_SCALE_FACTOR = 10 ** 12;

    // Test addresses
    address public governance = 0x1000000000000000000000000000000000000001;
    address public governanceWarchest = 0x2000000000000000000000000000000000000002;
    address public admin = 0x4000000000000000000000000000000000000004;

    // Deployed contracts
    USX public usx;
    sUSX public susx;
    TreasuryDiamond public treasury;
    MockAssetManager public mockAssetManager;
    MockUSDC public usdc;

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

    function setUp() public {
        // Deploy contracts directly without forking
        _deployContracts();
        _setupTestUsers();

        // Initialize state tracking
        previousTotalSupply = usx.totalSupply();
        previousPegPrice = usx.usxPrice();
        previousWithdrawalsFrozen = usx.withdrawalsFrozen();
    }

    function _deployContracts() internal {
        console.log("Deploying contracts...");

        // Deploy mock USDC first
        usdc = new MockUSDC();
        console.log("Mock USDC deployed at:", address(usdc));

        // Deploy MockAssetManager
        mockAssetManager = new MockAssetManager(address(usdc));
        console.log("MockAssetManager deployed at:", address(mockAssetManager));

        // Deploy USX implementation and proxy
        USX usxImpl = new USX();
        console.log("USX implementation deployed at:", address(usxImpl));

        bytes memory usxData =
            abi.encodeWithSelector(USX.initialize.selector, address(usdc), address(0), governanceWarchest, admin);
        ERC1967Proxy usxProxy = new ERC1967Proxy(address(usxImpl), usxData);
        usx = USX(address(usxProxy));
        console.log("USX proxy deployed at:", address(usx));

        // Deploy sUSX implementation and proxy
        sUSX susxImpl = new sUSX();
        console.log("sUSX implementation deployed at:", address(susxImpl));

        bytes memory susxData = abi.encodeWithSelector(sUSX.initialize.selector, address(usx), address(0), governance);
        ERC1967Proxy susxProxy = new ERC1967Proxy(address(susxImpl), susxData);
        susx = sUSX(address(susxProxy));
        console.log("sUSX proxy deployed at:", address(susx));

        // Deploy Treasury Diamond
        TreasuryDiamond treasuryImpl = new TreasuryDiamond();
        console.log("Treasury implementation deployed at:", address(treasuryImpl));

        try new ERC1967Proxy(
            address(treasuryImpl),
            abi.encodeWithSelector(
                TreasuryDiamond.initialize.selector,
                address(usdc),
                address(usx),
                address(susx),
                governance,
                governanceWarchest,
                address(mockAssetManager)
            )
        ) returns (ERC1967Proxy treasuryProxy) {
            treasury = TreasuryDiamond(payable(treasuryProxy));
            console.log("Treasury proxy deployed at:", address(treasury));
        } catch Error(string memory reason) {
            console.log("Treasury deployment failed with reason:", reason);
            revert();
        } catch (bytes memory lowLevelData) {
            console.log("Treasury deployment failed with low level error");
            revert();
        }

        // Link contracts properly
        console.log("Attempting to link USX to Treasury...");
        console.log("Governance Warchest:", governanceWarchest);
        console.log("Treasury:", address(treasury));

        // Check if treasury is already set
        vm.prank(governanceWarchest);
        try usx.setInitialTreasury(address(treasury)) {
            console.log("USX treasury set successfully");
        } catch {
            console.log("USX treasury already set or failed");
        }

        console.log("Attempting to link sUSX to Treasury...");
        console.log("Governance:", governance);

        // Check if treasury is already set
        vm.prank(governance);
        try susx.setInitialTreasury(address(treasury)) {
            console.log("sUSX treasury set successfully");
        } catch {
            console.log("sUSX treasury already set or failed");
        }

        console.log("Contracts linked successfully");
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

        uint256 totalUSXValue = usx.totalSupply() * usx.usxPrice() / 1e18 / 1e12; // Convert to USDC scale (6 decimals)
        uint256 totalUSDCBacking =
            usdc.balanceOf(address(treasury)) + treasury.assetManagerUSDC() + usdc.balanceOf(address(usx));

        // STRICT: No tolerance for value conservation - must be exact
        assertEq(totalUSXValue, totalUSDCBacking, "Value conservation violated - must be exact");
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

        uint256 sharePrice = susx.sharePrice();
        uint256 totalAssets = susx.totalAssets();
        uint256 totalSupply = susx.totalSupply();

        // Basic validity checks
        assertGt(sharePrice, 0, "Share price must be positive");

        // Share price should be consistent with total assets and supply
        // If there are assets, share price should be very close to expected
        if (totalAssets > 0) {
            uint256 expectedPrice = (totalAssets * 1e18) / totalSupply;

            // Allow only minimal tolerance for rounding errors (0.1%)
            uint256 minAllowedPrice = expectedPrice * 999 / 1000; // 99.9%
            uint256 maxAllowedPrice = expectedPrice * 1001 / 1000; // 100.1%

            assertGe(sharePrice, minAllowedPrice, "Share price too low relative to assets");
            assertLe(sharePrice, maxAllowedPrice, "Share price too high relative to assets");
        }

        // Share price should be consistent with USX price
        // sUSX shares represent USX, so their price should be very close
        uint256 usxPrice = usx.usxPrice();
        if (usxPrice > 0) {
            // Allow only minimal tolerance for fees/rounding (0.5%)
            uint256 minAllowedPrice = usxPrice * 995 / 1000; // 99.5% (allowing for withdrawal fees)
            uint256 maxAllowedPrice = usxPrice * 1005 / 1000; // 100.5% (allowing for small rewards)

            assertGe(sharePrice, minAllowedPrice, "Share price too low compared to USX price");
            assertLe(sharePrice, maxAllowedPrice, "Share price too high compared to USX price");
        }

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
        // Bound the amount to reasonable values
        amount = bound(amount, 1e6, 1000000e6); // 1 USDC to 1M USDC

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
        // Bound the amount to reasonable values
        amount = bound(amount, 1e18, 1000000e18); // 1 USX to 1M USX

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
        // Bound the amount to reasonable values
        totalBalance = bound(totalBalance, 1000e6, 10000000e6); // 1K to 10M USDC

        // Only proceed if asset manager has enough balance
        if (usdc.balanceOf(address(treasury)) + treasury.assetManagerUSDC() >= totalBalance) {
            vm.prank(address(mockAssetManager));
            bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportProfits.selector, totalBalance);
            address(treasury).call(data);
        }
    }

    /// @notice Random loss report function for fuzzing
    /// @dev Foundry will call this with random parameters
    function fuzz_report_losses(uint256 totalBalance) public advanceTimeRandomly {
        // Bound the amount to reasonable values
        totalBalance = bound(totalBalance, 1000e6, 10000000e6); // 1K to 10M USDC

        // Only proceed if asset manager has enough balance
        if (usdc.balanceOf(address(treasury)) + treasury.assetManagerUSDC() >= totalBalance) {
            vm.prank(address(mockAssetManager));
            bytes memory data = abi.encodeWithSelector(ProfitAndLossReporterFacet.reportLosses.selector, totalBalance);
            address(treasury).call(data);
        }
    }

    /// @notice Random asset manager transfer to function for fuzzing
    function fuzz_transfer_usdc_to_asset_manager(uint256 amount) public advanceTimeRandomly {
        // Bound the amount to reasonable values
        amount = bound(amount, 1000e6, 10000000e6); // 1K to 10M USDC

        // Only proceed if treasury has enough USDC
        if (usdc.balanceOf(address(treasury)) >= amount) {
            vm.prank(address(mockAssetManager));
            bytes memory data =
                abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector, amount);
            address(treasury).call(data);
        }
    }

    /// @notice Random asset manager transfer from function for fuzzing
    function fuzz_transfer_usdc_from_asset_manager(uint256 amount) public advanceTimeRandomly {
        // Bound the amount to reasonable values
        amount = bound(amount, 1000e6, 10000000e6); // 1K to 10M USDC

        // Only proceed if asset manager has enough USDC
        if (treasury.assetManagerUSDC() >= amount) {
            vm.prank(address(mockAssetManager));
            bytes memory data =
                abi.encodeWithSelector(AssetManagerAllocatorFacet.transferUSDCFromAssetManager.selector, amount);
            address(treasury).call(data);
        }
    }

    /// @notice Random governance parameter update for fuzzing
    function fuzz_update_governance_params(uint256 paramType, uint256 newValue) public advanceTimeRandomly {
        // Bound the parameter type and value
        paramType = bound(paramType, 0, 1); // 0: buffer renewal rate, 1: buffer target fraction
        newValue = bound(newValue, 100, 20000); // Reasonable ranges for each parameter

        vm.prank(governance);

        if (paramType == 0) {
            // Update buffer renewal rate
            bytes memory data = abi.encodeWithSelector(InsuranceBufferFacet.setBufferRenewalRate.selector, newValue);
            address(treasury).call(data);
        } else if (paramType == 1) {
            // Update buffer target fraction
            bytes memory data = abi.encodeWithSelector(InsuranceBufferFacet.setBufferTargetFraction.selector, newValue);
            address(treasury).call(data);
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
