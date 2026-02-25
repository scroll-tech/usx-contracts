// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PrivateGatewayCloak} from "../../src/cloak/PrivateGatewayCloak.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockScrollMessengerValidium, MockL2ERC20GatewayValidium} from "../mocks/MockScrollValidiumInfra.sol";

contract PrivateGatewayCloakTest is Test {
    MockUSDC internal usdc;
    IERC20 internal usx;
    MockScrollMessengerValidium internal messenger;
    MockL2ERC20GatewayValidium internal l2Gateway;

    PrivateGatewayCloak internal gateway;

    address internal admin = address(0xA11CE);
    address internal withdrawer = address(0xBEEF);
    address internal counterpart = address(0xC10A); // scroll gateway on the other chain

    function setUp() public {
        usdc = new MockUSDC();
        usx = IERC20(address(new MockUSDC())); // 18 decimals not required in logic, only address

        messenger = new MockScrollMessengerValidium();
        l2Gateway = new MockL2ERC20GatewayValidium(address(messenger));

        PrivateGatewayCloak impl = new PrivateGatewayCloak(
            address(usdc),
            address(usx),
            address(l2Gateway),
            counterpart
        );
        bytes memory data = abi.encodeCall(
            PrivateGatewayCloak.initialize,
            (admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        gateway = PrivateGatewayCloak(address(proxy));

        bytes32 withdrawRole = gateway.WITHDRAW_USX_ROLE();
        vm.prank(admin);
        gateway.grantRole(withdrawRole, withdrawer);
    }

    function _depositHash(
        uint256 nonce,
        bytes memory encryptedReceiver,
        uint256 keyId,
        uint256 amountUSDC
    ) internal pure returns (bytes32) {
        return
            keccak256(abi.encode(nonce, encryptedReceiver, keyId, amountUSDC));
    }

    function test_confirmDeposit_reverts_when_caller_not_messenger() public {
        vm.expectRevert(PrivateGatewayCloak.ErrorCallerIsNotMessenger.selector);
        gateway.confirmDeposit(1, hex"aa", 0, 100e6);
    }

    function test_confirmDeposit_reverts_when_xdomain_sender_not_counterpart()
        public
    {
        uint256 nonce = 1;
        bytes memory encryptedReceiver = hex"aa";
        uint256 keyId = 0;
        uint256 amountUSDC = 100e6;

        messenger.setXDomainMessageSender(address(0xDEAD));

        vm.prank(address(messenger));
        vm.expectRevert(
            PrivateGatewayCloak.ErrorCallerIsNotCounterpartGateway.selector
        );
        gateway.confirmDeposit(nonce, encryptedReceiver, keyId, amountUSDC);
    }

    function test_confirmDeposit_happy_path_sets_flag_and_emits_event() public {
        uint256 nonce = 1;
        bytes memory encryptedReceiver = hex"aa";
        uint256 keyId = 0;
        uint256 amountUSDC = 100e6;

        messenger.setXDomainMessageSender(counterpart);

        bytes32 hash = _depositHash(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC
        );
        assertFalse(gateway.confirmedDeposits(hash));

        vm.prank(address(messenger));
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PrivateGatewayCloak.DepositConfirmed(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC
        );
        gateway.confirmDeposit(nonce, encryptedReceiver, keyId, amountUSDC);

        assertTrue(gateway.confirmedDeposits(hash));

        vm.prank(address(messenger));
        vm.expectRevert(
            PrivateGatewayCloak.ErrorDepositAlreadyConfirmed.selector
        );
        gateway.confirmDeposit(nonce, encryptedReceiver, keyId, amountUSDC);
    }

    function _prepareConfirmedDeposit(
        uint256 nonce,
        bytes memory encryptedReceiver,
        uint256 keyId,
        uint256 amountUSDC
    ) internal returns (bytes32 hash) {
        messenger.setXDomainMessageSender(counterpart);
        hash = _depositHash(nonce, encryptedReceiver, keyId, amountUSDC);
        vm.prank(address(messenger));
        gateway.confirmDeposit(nonce, encryptedReceiver, keyId, amountUSDC);
    }

    function test_withdrawUSX_reverts_when_deposit_not_confirmed() public {
        uint256 nonce = 1;
        bytes memory encryptedReceiver = hex"aa";
        uint256 keyId = 0;
        uint256 amountUSDC = 100e6;
        address actualReceiver = address(0x1234);

        vm.prank(withdrawer);
        vm.expectRevert(PrivateGatewayCloak.ErrorDepositNotConfirmed.selector);
        gateway.withdrawUSX(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC,
            actualReceiver
        );
    }

    function test_withdrawUSX_reverts_when_caller_not_withdrawer() public {
        uint256 nonce = 1;
        bytes memory encryptedReceiver = hex"aa";
        uint256 keyId = 0;
        uint256 amountUSDC = 100e6;
        address actualReceiver = address(0x1234);

        messenger.setXDomainMessageSender(counterpart);
        vm.prank(address(messenger));
        gateway.confirmDeposit(nonce, encryptedReceiver, keyId, amountUSDC);

        // caller without WITHDRAW_USX_ROLE should revert (AccessControl)
        vm.expectRevert();
        gateway.withdrawUSX(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC,
            actualReceiver
        );
    }

    function test_withdrawUSX_happy_path_calls_l2_gateway_and_emits_event()
        public
    {
        uint256 nonce = 1;
        bytes memory encryptedReceiver = hex"aa";
        uint256 keyId = 0;
        uint256 amountUSDC = 100e6;
        address actualReceiver = address(0x1234);

        bytes32 hash = _prepareConfirmedDeposit(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC
        );
        assertTrue(gateway.confirmedDeposits(hash));
        assertFalse(gateway.withdrawnDeposits(hash));

        uint256 amountUSX = amountUSDC * 1e12;
        deal(address(usx), address(gateway), amountUSX);

        uint256 gatewayUsxBefore = usx.balanceOf(address(gateway));
        uint256 l2UsxBefore = usx.balanceOf(address(l2Gateway));

        vm.prank(withdrawer);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PrivateGatewayCloak.WithdrawUSX(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC,
            actualReceiver,
            amountUSX
        );
        gateway.withdrawUSX(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC,
            actualReceiver
        );

        assertTrue(gateway.withdrawnDeposits(hash));

        (
            address wToken,
            address wTo,
            uint256 wAmount,
            uint256 wGasLimit,
            uint256 wValue,
            address wFrom
        ) = l2Gateway.lastWithdrawal();
        assertEq(wToken, address(usx));
        assertEq(wTo, actualReceiver);
        assertEq(wAmount, amountUSX);
        assertEq(wGasLimit, 0);
        assertEq(wValue, 0);
        assertEq(wFrom, address(gateway));

        // token balances: cloak gateway loses USX, L2 gateway holds locked USX
        assertEq(usx.balanceOf(address(gateway)), gatewayUsxBefore - amountUSX);
        assertEq(usx.balanceOf(address(l2Gateway)), l2UsxBefore + amountUSX);
    }

    function test_withdrawUSX_reverts_when_already_withdrawn() public {
        uint256 nonce = 1;
        bytes memory encryptedReceiver = hex"aa";
        uint256 keyId = 0;
        uint256 amountUSDC = 100e6;
        address actualReceiver = address(0x1234);

        bytes32 hash = _prepareConfirmedDeposit(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC
        );
        deal(address(usx), address(gateway), amountUSDC * 1e12);

        vm.prank(withdrawer);
        gateway.withdrawUSX(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC,
            actualReceiver
        );
        assertTrue(gateway.withdrawnDeposits(hash));

        vm.prank(withdrawer);
        vm.expectRevert(
            PrivateGatewayCloak.ErrorDepositAlreadyWithdrawn.selector
        );
        gateway.withdrawUSX(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC,
            actualReceiver
        );
    }

    function test_withdrawTokens_erc20_and_eth_paths() public {
        address receiver = address(0xB0B);

        deal(address(usx), address(gateway), 1_000e18);
        vm.prank(admin);
        gateway.withdrawTokens(address(usx), receiver, 200e18);
        assertEq(usx.balanceOf(receiver), 200e18);

        vm.deal(address(gateway), 1 ether);
        uint256 beforeBal = receiver.balance;
        vm.prank(admin);
        gateway.withdrawTokens(address(0), receiver, 0.5 ether);
        assertEq(receiver.balance, beforeBal + 0.5 ether);
    }

    function test_withdrawTokens_reverts_when_caller_not_admin() public {
        address receiver = address(0xB0B);

        deal(address(usx), address(gateway), 1_000e18);

        vm.expectRevert();
        gateway.withdrawTokens(address(usx), receiver, 200e18);
    }
}
