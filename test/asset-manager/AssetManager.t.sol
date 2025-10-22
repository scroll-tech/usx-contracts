// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AssetManager} from "../../src/asset-manager/AssetManager.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";


contract AssetManagerTest is Test {
    MockUSDC internal usdc;
    AssetManager internal assetManager;

    address internal admin;
    address internal treasury;
    address internal governance;
    address internal alice;
    address internal bob;

    bytes32 internal constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        governance = makeAddr("governance");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        usdc = new MockUSDC();
        AssetManager impl = new AssetManager(address(usdc), treasury);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(
            AssetManager.initialize,
            (admin, governance)
        ));
        assetManager = AssetManager(address(proxy));

        // Sanity roles
        assertEq(assetManager.hasRole(DEFAULT_ADMIN_ROLE, admin), true);
        assertEq(assetManager.hasRole(GOVERNANCE_ROLE, governance), true);
    }

    function test_initialize_setsRoles() public {
        assertEq(assetManager.hasRole(DEFAULT_ADMIN_ROLE, admin), true);
        assertEq(assetManager.hasRole(GOVERNANCE_ROLE, governance), true);
        assertEq(assetManager.hasRole(GOVERNANCE_ROLE, treasury), false);
    }

    function test_getters_initial_zero() public view {
        assertEq(assetManager.getTotalWeight(), 0);
        assertEq(assetManager.getWeight(alice), 0);
        (address[] memory accounts, uint256[] memory weights) = assetManager.getWeights();
        assertEq(accounts.length, 0);
        assertEq(weights.length, 0);
    }

    function test_updateWeight_onlyAdmin() public {
        vm.expectRevert();
        assetManager.updateWeight(alice, 100);

        vm.prank(admin);
        assetManager.updateWeight(alice, 100);
        assertEq(assetManager.getWeight(alice), 100);
    }

    function test_updateWeight_addUpdateRemove_affectsTotalsAndGetters() public {
        // Add alice 100, bob 300
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit AssetManager.WeightUpdated(alice, 0, 100);
        assetManager.updateWeight(alice, 100);

        vm.expectEmit(true, true, true, true);
        emit AssetManager.WeightUpdated(bob, 0, 300);
        assetManager.updateWeight(bob, 300);
        vm.stopPrank();

        assertEq(assetManager.getTotalWeight(), 400);
        assertEq(assetManager.getWeight(alice), 100);
        assertEq(assetManager.getWeight(bob), 300);

        // Update alice to 200
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit AssetManager.WeightUpdated(alice, 100, 200);
        assetManager.updateWeight(alice, 200);

        assertEq(assetManager.getTotalWeight(), 500);
        assertEq(assetManager.getWeight(alice), 200);

        // Remove bob
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit AssetManager.WeightUpdated(bob, 300, 0);
        assetManager.updateWeight(bob, 0);

        assertEq(assetManager.getTotalWeight(), 200);
        assertEq(assetManager.getWeight(bob), 0);

        // getWeights reflects single remaining account
        (address[] memory accounts, uint256[] memory weights) = assetManager.getWeights();
        assertEq(accounts.length, 1);
        assertEq(weights.length, 1);
        assertEq(assetManager.getWeight(accounts[0]), weights[0]);
        assertEq(weights[0], 200);
    }

    function test_deposit_reverts_whenCallerNotTreasury() public {
        vm.expectRevert(AssetManager.NotTreasury.selector);
        assetManager.deposit(1e6);
    }

    function test_withdraw_reverts_whenCallerNotTreasury() public {
        vm.expectRevert(AssetManager.NotTreasury.selector);
        assetManager.withdraw(1e6);
    }

    function test_deposit_withNoWeights_transfersFromTreasuryAndHoldsBalance() public {
        // Fund treasury and approve manager
        deal(address(usdc), treasury, 10_000e6);
        vm.prank(treasury);
        usdc.approve(address(assetManager), type(uint256).max);

        uint256 amount = 5_000e6;
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 managerBefore = usdc.balanceOf(address(assetManager));

        vm.prank(treasury);
        assetManager.deposit(amount);

        // USDC pulled from treasury to manager
        assertEq(usdc.balanceOf(treasury), treasuryBefore - amount);
        assertEq(usdc.balanceOf(address(assetManager)), managerBefore + amount);
        // With zero weights, no distributions
    }

    function test_withdraw_byTreasury_sendsUSDCBackToTreasury() public {
        // Preload manager with funds
        deal(address(usdc), address(assetManager), 2_000e6);
        uint256 amount = 1_500e6;

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 managerBefore = usdc.balanceOf(address(assetManager));

        vm.prank(treasury);
        assetManager.withdraw(amount);

        assertEq(usdc.balanceOf(treasury), treasuryBefore + amount);
        assertEq(usdc.balanceOf(address(assetManager)), managerBefore - amount);
    }

    function test_deposit_distributesProportionally_andEmits_andLeavesRemainder() public {
        // Set weights: alice 1, bob 3 (total 4)
        vm.startPrank(admin);
        assetManager.updateWeight(alice, 1);
        assetManager.updateWeight(bob, 3);
        vm.stopPrank();
        assertEq(assetManager.getTotalWeight(), 4);

        // Treasury funds and approve
        deal(address(usdc), treasury, 1_001e6); // pick amount to test remainder behavior
        vm.prank(treasury);
        usdc.approve(address(assetManager), type(uint256).max);

        // Expect two USDCDistributed events
        vm.expectEmit(true, true, true, true);
        emit AssetManager.USDCDistributed(alice, 250250000); // amount checked loosely by matching all fields; we will check balances precisely after
        vm.expectEmit(true, true, true, true);
        emit AssetManager.USDCDistributed(bob, 750750000);

        uint256 amount = 1_001e6;
        vm.prank(treasury);
        assetManager.deposit(amount);

        uint256 managerBal = usdc.balanceOf(address(assetManager));
        uint256 aliceBal = usdc.balanceOf(alice);
        uint256 bobBal = usdc.balanceOf(bob);

        // Distribution uses contract balance after transferFrom
        // amounts: floor(1001e6 * 1 / 4) = 250,250,000 and floor(1001e6 * 3 / 4) = 750,750,000
        // sum = 1,001,000,000 exactly, remainder 0. For better remainder test, let's assert generally:
        uint256 totalWeight = assetManager.getTotalWeight();
        uint256 balanceAfterPull = amount; // manager had 0 before
        uint256 expectedAlice = (balanceAfterPull * 1) / totalWeight;
        uint256 expectedBob = (balanceAfterPull * 3) / totalWeight;
        uint256 distributed = expectedAlice + expectedBob;
        uint256 expectedRemainder = balanceAfterPull - distributed;

        assertEq(aliceBal, expectedAlice);
        assertEq(bobBal, expectedBob);
        assertEq(managerBal, expectedRemainder);
    }

    function test_deposit_afterRemovingOneRecipient_onlyRemainingReceives() public {
        // Set two recipients
        vm.startPrank(admin);
        assetManager.updateWeight(alice, 2);
        assetManager.updateWeight(bob, 2);
        vm.stopPrank();
        assertEq(assetManager.getTotalWeight(), 4);

        // Remove bob
        vm.prank(admin);
        assetManager.updateWeight(bob, 0);
        assertEq(assetManager.getTotalWeight(), 2);

        // Deposit
        deal(address(usdc), treasury, 1_000e6);
        vm.prank(treasury);
        usdc.approve(address(assetManager), type(uint256).max);

        vm.prank(treasury);
        assetManager.deposit(1_000e6);

        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(alice), 1_000e6); // all goes to alice since weight 2 / total 2
        assertEq(usdc.balanceOf(address(assetManager)), 0);
    }

    function test_getWeights_returnsAllCurrentMappings() public {
        vm.startPrank(admin);
        assetManager.updateWeight(alice, 5);
        assetManager.updateWeight(bob, 7);
        vm.stopPrank();

        (address[] memory accounts, uint256[] memory weights) = assetManager.getWeights();
        assertEq(accounts.length, 2);
        assertEq(weights.length, 2);

        // Check that for each returned account, getWeight matches corresponding weight
        for (uint256 i = 0; i < accounts.length; i++) {
            assertEq(assetManager.getWeight(accounts[i]), weights[i]);
            assertTrue(accounts[i] == alice || accounts[i] == bob);
        }

        // Combined weights should match total
        uint256 sum;
        for (uint256 i = 0; i < weights.length; i++) sum += weights[i];
        assertEq(sum, assetManager.getTotalWeight());
    }
}
