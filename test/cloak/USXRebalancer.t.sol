// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {USXRebalancer} from "../../src/cloak/USXRebalancer.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockScrollMessengerValidium, MockL1ERC20GatewayValidium, MockSwapRouterReverting} from "../mocks/MockScrollValidiumInfra.sol";
import {MockUSX, MockUSXSwapRouter} from "../mocks/MockUSXInfra.sol";

contract USXRebalancerTest is Test {
    MockUSDC internal usdc;
    MockUSX internal usx;

    MockScrollMessengerValidium internal messenger;
    MockL1ERC20GatewayValidium internal l1Gateway;

    MockUSXSwapRouter internal swapRouter;
    MockSwapRouterReverting internal revertingRouter;

    USXRebalancer internal rebalancer;

    address internal admin = address(0xA11CE);
    address internal rebalancerOperator = address(0xBEEF);

    uint256 internal constant GAS_LIMIT = 1_000_000;

    function setUp() public {
        usdc = new MockUSDC();
        usx = new MockUSX();

        messenger = new MockScrollMessengerValidium();
        l1Gateway = new MockL1ERC20GatewayValidium(address(messenger));

        USXRebalancer impl = new USXRebalancer(
            address(usdc),
            address(usx),
            address(l1Gateway)
        );
        bytes memory data = abi.encodeCall(USXRebalancer.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        rebalancer = USXRebalancer(payable(address(proxy)));

        bytes32 rebalanceRole = rebalancer.REBALANCE_ROLE();
        vm.prank(admin);
        rebalancer.grantRole(rebalanceRole, rebalancerOperator);

        swapRouter = new MockUSXSwapRouter();
        revertingRouter = new MockSwapRouterReverting();

        vm.startPrank(admin);
        rebalancer.updateSupportedSwapRouter(
            address(swapRouter),
            address(swapRouter),
            true
        );
        rebalancer.updateSupportedSwapRouter(
            address(revertingRouter),
            address(revertingRouter),
            true
        );
        vm.stopPrank();
    }

    function _encryptedReceiver()
        internal
        pure
        returns (USXRebalancer.EncryptedReceiver memory)
    {
        return USXRebalancer.EncryptedReceiver({receiver: hex"aa", keyId: 1});
    }

    function test_rebalanceByMinting_reverts_when_caller_not_authorized()
        public
    {
        uint256 amountUSDC = 100e6;

        USXRebalancer.EncryptedReceiver memory receiver = _encryptedReceiver();

        vm.expectRevert();
        rebalancer.rebalanceByMinting(amountUSDC, receiver);
    }

    function test_rebalanceByMinting_reverts_when_insufficient_usdc() public {
        uint256 amountUSDC = 100e6;
        USXRebalancer.EncryptedReceiver memory receiver = _encryptedReceiver();

        vm.prank(rebalancerOperator);
        vm.expectRevert(USXRebalancer.ErrorInsufficientUSDCBalance.selector);
        rebalancer.rebalanceByMinting(amountUSDC, receiver);
    }

    function test_rebalanceByMinting_happy_path_mints_and_deposits() public {
        uint256 amountUSDC = 100e6;
        USXRebalancer.EncryptedReceiver memory receiver = _encryptedReceiver();
        vm.prank(admin);
        rebalancer.updateExpectedUSXReceiver(receiver);

        // fund the rebalancer with USDC
        deal(address(usdc), address(rebalancer), amountUSDC);

        uint256 l1UsxBefore = usx.balanceOf(address(l1Gateway));

        vm.prank(rebalancerOperator);
        rebalancer.rebalanceByMinting(amountUSDC, receiver);

        (
            address depToken,
            bytes memory depTo,
            uint256 depAmount,
            uint256 depGasLimit,
            uint256 depKeyId,
            uint256 depValue,
            address depFrom
        ) = l1Gateway.lastDeposit();

        // MockUSX mints 1:1 with USDC amount
        uint256 expectedMinted = amountUSDC * 10 ** 12;

        assertEq(depToken, address(usx));
        assertEq(depTo, receiver.receiver);
        assertEq(depAmount, expectedMinted);
        assertEq(depGasLimit, GAS_LIMIT);
        assertEq(depKeyId, receiver.keyId);
        assertEq(depValue, 0);
        assertEq(depFrom, address(rebalancer));

        assertEq(
            usx.balanceOf(address(l1Gateway)),
            l1UsxBefore + expectedMinted
        );
        // all minted USX should have been bridged out
        assertEq(usx.balanceOf(address(rebalancer)), 0);
    }

    function test_rebalanceBySwapping_reverts_when_insufficient_usdc() public {
        uint256 amountUSDC = 100e6;
        USXRebalancer.EncryptedReceiver memory receiver = _encryptedReceiver();

        bytes memory swapData = abi.encodeWithSelector(
            MockUSXSwapRouter.swapToUSX.selector,
            amountUSDC,
            address(usdc),
            address(usx),
            uint256(1e12)
        );

        vm.expectRevert(USXRebalancer.ErrorInsufficientUSDCBalance.selector);
        rebalancer.rebalanceBySwapping(
            amountUSDC,
            address(swapRouter),
            swapData,
            receiver
        );
    }

    function test_rebalanceBySwapping_reverts_when_swap_fails() public {
        uint256 amountUSDC = 100e6;
        USXRebalancer.EncryptedReceiver memory receiver = _encryptedReceiver();

        // fund the rebalancer with USDC
        deal(address(usdc), address(rebalancer), amountUSDC);

        bytes memory swapData = abi.encodeWithSelector(
            MockSwapRouterReverting.swapToUSDC.selector,
            amountUSDC,
            address(usdc),
            address(usx)
        );

        vm.expectRevert(USXRebalancer.ErrorSwapFailed.selector);
        rebalancer.rebalanceBySwapping(
            amountUSDC,
            address(revertingRouter),
            swapData,
            receiver
        );
    }

    function test_rebalanceBySwapping_reverts_when_insufficient_usx_amount()
        public
    {
        uint256 amountUSDC = 100e6;
        USXRebalancer.EncryptedReceiver memory receiver = _encryptedReceiver();

        // fund the rebalancer with USDC
        deal(address(usdc), address(rebalancer), amountUSDC);
        // fund the router with some USX but with a low rate so that the
        // received USX is less than amountUSDC * 1e12
        uint256 lowRate = 1e11;
        deal(address(usx), address(swapRouter), amountUSDC * lowRate);

        bytes memory swapData = abi.encodeWithSelector(
            MockUSXSwapRouter.swapToUSX.selector,
            amountUSDC,
            address(usdc),
            address(usx),
            lowRate
        );

        vm.expectRevert(USXRebalancer.ErrorInsufficientUSXAmount.selector);
        rebalancer.rebalanceBySwapping(
            amountUSDC,
            address(swapRouter),
            swapData,
            receiver
        );
    }

    function test_rebalanceBySwapping_happy_path_swaps_and_deposits() public {
        uint256 amountUSDC = 200e6;
        USXRebalancer.EncryptedReceiver memory receiver = _encryptedReceiver();
        vm.prank(admin);
        rebalancer.updateExpectedUSXReceiver(receiver);

        // fund the rebalancer with USDC and the router with enough USX
        deal(address(usdc), address(rebalancer), amountUSDC);
        uint256 rate = 1e12;
        uint256 usxOut = amountUSDC * rate;
        deal(address(usx), address(swapRouter), usxOut * 2);

        uint256 l1UsxBefore = usx.balanceOf(address(l1Gateway));

        bytes memory swapData = abi.encodeWithSelector(
            MockUSXSwapRouter.swapToUSX.selector,
            amountUSDC,
            address(usdc),
            address(usx),
            rate
        );

        rebalancer.rebalanceBySwapping(
            amountUSDC,
            address(swapRouter),
            swapData,
            receiver
        );

        (
            address depToken,
            bytes memory depTo,
            uint256 depAmount,
            uint256 depGasLimit,
            uint256 depKeyId,
            uint256 depValue,
            address depFrom
        ) = l1Gateway.lastDeposit();

        assertEq(depToken, address(usx));
        assertEq(depTo, receiver.receiver);
        assertEq(depAmount, usxOut);
        assertEq(depGasLimit, GAS_LIMIT);
        assertEq(depKeyId, receiver.keyId);
        assertEq(depValue, 0);
        assertEq(depFrom, address(rebalancer));

        assertEq(usx.balanceOf(address(rebalancer)), 0);
        assertEq(usx.balanceOf(address(l1Gateway)), l1UsxBefore + usxOut);
    }

    function test_withdrawTokens_erc20_and_eth_paths() public {
        address receiver = address(0xB0B);

        deal(address(usdc), address(rebalancer), 1_000e6);
        vm.prank(admin);
        rebalancer.withdrawTokens(address(usdc), receiver, 200e6);
        assertEq(usdc.balanceOf(receiver), 200e6);

        vm.deal(address(rebalancer), 1 ether);
        uint256 beforeBal = receiver.balance;
        vm.prank(admin);
        rebalancer.withdrawTokens(address(0), receiver, 0.5 ether);
        assertEq(receiver.balance, beforeBal + 0.5 ether);
    }

    function test_withdrawTokens_reverts_when_caller_not_admin() public {
        address receiver = address(0xB0B);

        deal(address(usdc), address(rebalancer), 1_000e6);

        vm.expectRevert();
        rebalancer.withdrawTokens(address(usdc), receiver, 200e6);
    }

    function test_getSupportedSwapRouters_after_updates() public {
        address router2 = address(0x1234);

        vm.startPrank(admin);
        rebalancer.updateSupportedSwapRouter(router2, router2, true);
        rebalancer.updateSupportedSwapRouter(
            address(swapRouter),
            address(0),
            false
        );
        vm.stopPrank();

        address[] memory routers = rebalancer.getSupportedSwapRouters();
        assertEq(routers.length, 2);
    }
}
