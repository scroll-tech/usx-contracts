// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PrivateGatewayScroll} from "../../src/cloak/PrivateGatewayScroll.sol";
import {PrivateGatewayCloak} from "../../src/cloak/PrivateGatewayCloak.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockScrollMessengerValidium, MockL1ERC20GatewayValidium, MockSwapRouter, MockSwapRouterReverting} from "../mocks/MockScrollValidiumInfra.sol";

contract PrivateGatewayScrollTest is Test {
    MockUSDC internal usdc;
    IERC20 internal usx;

    MockScrollMessengerValidium internal messenger;
    MockL1ERC20GatewayValidium internal l1Gateway;
    MockSwapRouter internal swapRouter;
    MockSwapRouterReverting internal swapRouterReverting;

    PrivateGatewayScroll internal gateway;

    address internal admin = address(0xA11CE);
    address internal keyManager = address(0xBEEF);
    address internal counterpart = address(0xC10A); // cloak gateway on the other chain

    uint256 internal constant INITIAL_USDC_BALANCE = 1_000_000e6;
    uint256 internal constant MIN_USDC_AMOUNT = 100e6;
    uint256 internal constant FEE_PERCENTAGE = 1e16; // 1%
    uint256 internal constant MAX_FEE_AMOUNT = 1_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        usx = IERC20(address(new MockUSDC())); // simple 18-decimals not required; only address is used

        messenger = new MockScrollMessengerValidium();
        l1Gateway = new MockL1ERC20GatewayValidium(address(messenger));
        swapRouter = new MockSwapRouter();
        swapRouterReverting = new MockSwapRouterReverting();

        PrivateGatewayScroll impl = new PrivateGatewayScroll(
            address(usdc),
            address(usx),
            address(l1Gateway),
            counterpart
        );
        bytes memory data = abi.encodeCall(
            PrivateGatewayScroll.initialize,
            (admin, MIN_USDC_AMOUNT, FEE_PERCENTAGE, MAX_FEE_AMOUNT)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        gateway = PrivateGatewayScroll(payable(address(proxy)));

        bytes32 keyRole = gateway.KEY_MANAGER_ROLE();
        vm.prank(admin);
        gateway.grantRole(keyRole, keyManager);
    }

    function test_registerNewEncryptionKey_and_getters() public {
        bytes memory key = hex"01";
        key = abi.encodePacked(key, new bytes(32)); // length 33

        vm.prank(keyManager);
        uint256 keyId = gateway.registerNewEncryptionKey(key);
        assertEq(keyId, 0);

        (uint256 latestId, bytes memory latestKey) = gateway
            .getLatestEncryptionKey();
        assertEq(latestId, 0);
        assertEq(latestKey, key);

        bytes memory fetched = gateway.getEncryptionKey(0);
        assertEq(fetched, key);
    }

    function test_registerNewEncryptionKey_reverts_on_invalid_length() public {
        bytes memory key = new bytes(32);

        vm.prank(keyManager);
        vm.expectRevert(
            PrivateGatewayScroll.ErrorInvalidEncryptionKeyLength.selector
        );
        gateway.registerNewEncryptionKey(key);
    }

    function test_getLatestEncryptionKey_reverts_when_empty() public {
        vm.expectRevert(
            PrivateGatewayScroll.ErrorUnknownEncryptionKey.selector
        );
        gateway.getLatestEncryptionKey();
    }

    function test_getSupportedTokens_and_swapRouters_after_updates() public {
        address token1 = address(0x1);
        address token2 = address(0x2);
        address router1 = address(0x3);
        address router2 = address(0x4);

        vm.startPrank(admin);
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;
        gateway.updateSupportedTokens(tokens, true);
        gateway.updateSupportedSwapRouter(router1, router1, true);
        gateway.updateSupportedSwapRouter(router2, router2, true);

        // remove one token and one router to hit the removal branches
        address[] memory toRemove = new address[](1);
        toRemove[0] = token2;
        gateway.updateSupportedTokens(toRemove, false);
        gateway.updateSupportedSwapRouter(router2, address(0), false);
        vm.stopPrank();

        address[] memory supportedTokens = gateway.getSupportedTokens();
        address[] memory supportedRouters = gateway.getSupportedSwapRouters();

        assertEq(supportedTokens.length, 1);
        assertEq(supportedTokens[0], token1);

        assertEq(supportedRouters.length, 1);
        assertEq(supportedRouters[0], router1);
    }

    function test_getEncryptionKey_reverts_when_unknown_or_deprecated() public {
        bytes memory key1 = abi.encodePacked(bytes1(0x01), new bytes(32));
        bytes memory key2 = abi.encodePacked(bytes1(0x02), new bytes(32));

        vm.startPrank(keyManager);
        gateway.registerNewEncryptionKey(key1);
        gateway.registerNewEncryptionKey(key2);
        vm.stopPrank();

        // keyId too large
        vm.expectRevert(
            PrivateGatewayScroll.ErrorUnknownEncryptionKey.selector
        );
        gateway.getEncryptionKey(2);

        // deprecated key
        vm.expectRevert(
            PrivateGatewayScroll.ErrorDeprecatedEncryptionKey.selector
        );
        gateway.getEncryptionKey(0);
    }

    function test_updateMinUSDCAmount_emits_event() public {
        uint256 newMin = 200e6;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PrivateGatewayScroll.MinUSDCAmountUpdated(MIN_USDC_AMOUNT, newMin);
        gateway.updateMinUSDCAmount(newMin);

        assertEq(gateway.minUSDCAmount(), newMin);
    }

    function test_updateFeePercentage_bounds_and_event() public {
        uint256 newFee = 5e16; // 5%

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PrivateGatewayScroll.FeePercentageUpdated(FEE_PERCENTAGE, newFee);
        gateway.updateFeePercentage(newFee);
        assertEq(gateway.feePercentage(), newFee);

        uint256 invalid = 1e17 + 1; // > 10%
        vm.prank(admin);
        vm.expectRevert(
            PrivateGatewayScroll.ErrorInvalidFeePercentage.selector
        );
        gateway.updateFeePercentage(invalid);
    }

    function test_updateMaxFeeAmount_emits_event() public {
        uint256 newMax = 2_000e6;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit PrivateGatewayScroll.MaxFeeAmountUpdated(MAX_FEE_AMOUNT, newMax);
        gateway.updateMaxFeeAmount(newMax);
        assertEq(gateway.maxFeeAmount(), newMax);
    }

    function test_only_admin_can_update_parameters_and_withdrawTokens() public {
        uint256 newMin = 200e6;

        // non-admin should revert
        vm.expectRevert();
        gateway.updateMinUSDCAmount(newMin);

        // admin succeeds
        vm.prank(admin);
        gateway.updateMinUSDCAmount(newMin);
        assertEq(gateway.minUSDCAmount(), newMin);

        // withdrawTokens access control
        address receiver = address(0xB0B);
        deal(address(usdc), address(gateway), 1_000e6);

        vm.expectRevert();
        gateway.withdrawTokens(address(usdc), receiver, 100e6);

        vm.prank(admin);
        gateway.withdrawTokens(address(usdc), receiver, 100e6);
        assertEq(usdc.balanceOf(receiver), 100e6);
    }

    function test_withdrawTokens_eth_path() public {
        address receiver = address(0xB0B);

        vm.deal(address(gateway), 1 ether);
        uint256 beforeBal = receiver.balance;

        vm.prank(admin);
        gateway.withdrawTokens(address(0), receiver, 0.5 ether);

        assertEq(receiver.balance, beforeBal + 0.5 ether);
    }

    function test_only_key_manager_can_register_encryption_key() public {
        bytes memory key = abi.encodePacked(bytes1(0x01), new bytes(32));

        vm.expectRevert();
        gateway.registerNewEncryptionKey(key);
    }

    function _registerKey() internal returns (uint256 keyId, bytes memory key) {
        key = abi.encodePacked(bytes1(0x01), new bytes(32));
        vm.prank(keyManager);
        keyId = gateway.registerNewEncryptionKey(key);
    }

    function _prepareUser(uint256 amount) internal returns (address user) {
        user = address(0xD00D);
        deal(address(usdc), user, amount);
        vm.prank(user);
        IERC20(address(usdc)).approve(address(gateway), type(uint256).max);
    }

    function test_transferUSDC_fee_capped_by_maxFeeAmount() public {
        (uint256 keyId, bytes memory usxReceiverBytes) = _registerKey();
        address user = _prepareUser(INITIAL_USDC_BALANCE);

        // choose amount large enough that raw fee > MAX_FEE_AMOUNT
        uint256 amount = 200_000e6;

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: usxReceiverBytes,
                keyId: keyId
            });
        bytes memory usdcReceiverBytes = hex"abcd";
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: usdcReceiverBytes,
                keyId: keyId
            });

        uint256 expectedFee = (amount * gateway.feePercentage()) / 1e18;
        assertTrue(expectedFee > gateway.maxFeeAmount());

        uint256 gatewayUsdcBefore = usdc.balanceOf(address(gateway));
        uint256 l1UsdcBefore = usdc.balanceOf(address(l1Gateway));

        vm.prank(user);
        gateway.transferUSDC(amount, usxReceiver, usdcReceiver);

        (, , uint256 depAmount, , , , ) = l1Gateway.lastDeposit();

        // actual fee must be capped by maxFeeAmount
        uint256 actualFee = usdc.balanceOf(address(gateway)) -
            gatewayUsdcBefore;
        assertEq(actualFee, gateway.maxFeeAmount());
        assertEq(depAmount, amount - gateway.maxFeeAmount());
        assertEq(usdc.balanceOf(address(l1Gateway)), l1UsdcBefore + depAmount);
    }

    function test_transferUSDC_happy_path_deposits_and_sends_message() public {
        (uint256 keyId, bytes memory usxReceiverBytes) = _registerKey();
        address user = _prepareUser(INITIAL_USDC_BALANCE);

        uint256 amount = 1_000e6;

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: usxReceiverBytes,
                keyId: keyId
            });
        bytes memory usdcReceiverBytes = hex"abcd";
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: usdcReceiverBytes,
                keyId: keyId
            });

        uint256 netAmount;

        {
            uint256 fee = (amount * gateway.feePercentage()) / 1e18;
            if (fee > gateway.maxFeeAmount()) {
                fee = gateway.maxFeeAmount();
            }
            netAmount = amount - fee;
            uint256 gatewayUsdcBefore = usdc.balanceOf(address(gateway));
            uint256 l1UsdcBefore = usdc.balanceOf(address(l1Gateway));

            vm.prank(user);
            vm.expectEmit(true, true, true, true, address(gateway));
            emit PrivateGatewayScroll.USDCTransferred(
                1,
                usxReceiverBytes,
                keyId,
                netAmount
            );
            gateway.transferUSDC(amount, usxReceiver, usdcReceiver);
            assertEq(gateway.nonce(), 1);

            // token balances: user -> gateway -> L1 gateway (net amount), fee stays in gateway
            assertEq(usdc.balanceOf(address(gateway)), gatewayUsdcBefore + fee);
            assertEq(
                usdc.balanceOf(address(l1Gateway)),
                l1UsdcBefore + netAmount
            );
        }

        {
            MockL1ERC20GatewayValidium.Deposit memory deposit;
            (
                deposit.token,
                deposit.to,
                deposit.amount,
                deposit.gasLimit,
                deposit.keyId,
                deposit.value,
                deposit.from
            ) = l1Gateway.lastDeposit();
            assertEq(deposit.token, address(usdc));
            assertEq(deposit.to, usdcReceiverBytes);
            assertEq(deposit.amount, netAmount);
            assertEq(deposit.gasLimit, 1_000_000);
            assertEq(deposit.keyId, keyId);
            assertEq(deposit.value, 0);
            assertEq(deposit.from, address(gateway));
        }

        {
            MockScrollMessengerValidium.Message memory message;
            (
                message.target,
                message.value,
                message.message,
                message.gasLimit,
                message.from,
                message.msgValue
            ) = messenger.lastMessage();
            assertEq(message.target, counterpart);
            assertEq(message.value, 0);
            assertEq(message.gasLimit, 1_000_000);
            assertEq(message.from, address(gateway));
            assertEq(message.msgValue, 0);
            bytes memory expectedMsg = abi.encodeCall(
                PrivateGatewayCloak.confirmDeposit,
                (uint256(1), usxReceiverBytes, keyId, netAmount)
            );
            assertEq(message.message, expectedMsg);
        }
    }

    function test_transferUSDC_reverts_when_no_encryption_key_registered()
        public
    {
        address user = _prepareUser(INITIAL_USDC_BALANCE);

        uint256 amount = MIN_USDC_AMOUNT;

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: hex"aa",
                keyId: 0
            });
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: hex"bb",
                keyId: 0
            });

        vm.prank(user);
        vm.expectRevert(
            PrivateGatewayScroll.ErrorUnknownEncryptionKey.selector
        );
        gateway.transferUSDC(amount, usxReceiver, usdcReceiver);
    }

    function test_transferUSDC_reverts_when_amount_below_min() public {
        (uint256 keyId, bytes memory usxReceiverBytes) = _registerKey();
        address user = _prepareUser(INITIAL_USDC_BALANCE);

        uint256 amount = MIN_USDC_AMOUNT - 1;

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: usxReceiverBytes,
                keyId: keyId
            });
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: hex"11",
                keyId: keyId
            });

        vm.prank(user);
        vm.expectRevert(PrivateGatewayScroll.ErrorInvalidAmount.selector);
        gateway.transferUSDC(amount, usxReceiver, usdcReceiver);
    }

    function test_transferUSDC_reverts_when_key_not_latest() public {
        (uint256 keyId, bytes memory keyBytes) = _registerKey();

        // register another key so that keyId becomes deprecated
        bytes memory key2 = abi.encodePacked(bytes1(0x02), new bytes(32));
        vm.prank(keyManager);
        gateway.registerNewEncryptionKey(key2);

        address user = _prepareUser(INITIAL_USDC_BALANCE);

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: keyBytes,
                keyId: keyId
            });
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: hex"11",
                keyId: keyId
            });

        vm.prank(user);
        vm.expectRevert(
            PrivateGatewayScroll.ErrorInvalidEncryptionKey.selector
        );
        gateway.transferUSDC(MIN_USDC_AMOUNT, usxReceiver, usdcReceiver);
    }

    function test_transferToken_reverts_when_token_not_supported() public {
        (uint256 keyId, bytes memory keyBytes) = _registerKey();
        address user = _prepareUser(INITIAL_USDC_BALANCE);

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: keyBytes,
                keyId: keyId
            });
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: hex"22",
                keyId: keyId
            });

        address token = address(0xDEAD);
        address router = address(swapRouter);

        vm.prank(user);
        vm.expectRevert(PrivateGatewayScroll.ErrorTokenNotSupported.selector);
        gateway.transferToken(
            token,
            1e18,
            router,
            "",
            usxReceiver,
            usdcReceiver
        );
    }

    function test_transferToken_reverts_when_router_not_supported() public {
        (uint256 keyId, bytes memory keyBytes) = _registerKey();
        address user = _prepareUser(INITIAL_USDC_BALANCE);

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: keyBytes,
                keyId: keyId
            });
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: hex"22",
                keyId: keyId
            });

        address token = address(0);
        address router = address(0xDEAD);

        vm.prank(admin);
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        gateway.updateSupportedTokens(tokens, true);

        vm.prank(user);
        vm.expectRevert(
            PrivateGatewayScroll.ErrorSwapRouterNotSupported.selector
        );
        gateway.transferToken(
            token,
            1e18,
            router,
            "",
            usxReceiver,
            usdcReceiver
        );
    }

    function test_transferToken_eth_happy_path_swaps_and_bridges() public {
        (uint256 keyId, bytes memory keyBytes) = _registerKey();

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: keyBytes,
                keyId: keyId
            });
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: hex"33",
                keyId: keyId
            });

        address token = address(0);
        address router = address(swapRouter);

        {
            vm.startPrank(admin);
            address[] memory tokens = new address[](1);
            tokens[0] = token;
            gateway.updateSupportedTokens(tokens, true);
            gateway.updateSupportedSwapRouter(router, router, true);
            vm.stopPrank();
        }

        // router pre-funded with USDC so it can pay out swap proceeds
        deal(address(usdc), address(swapRouter), 1_000_000e6);

        uint256 routerUsdcBefore = usdc.balanceOf(address(swapRouter));
        uint256 gatewayUsdcBefore = usdc.balanceOf(address(gateway));
        uint256 l1UsdcBefore = usdc.balanceOf(address(l1Gateway));
        uint256 gatewayEthBefore = address(gateway).balance;

        uint256 swapAmount = 500e6;
        bytes memory swapData = abi.encodeWithSelector(
            MockSwapRouter.swapToUSDC.selector,
            swapAmount,
            address(0),
            address(usdc)
        );

        vm.deal(address(0xF00D), 10 ether);
        vm.prank(address(0xF00D));
        gateway.transferToken{value: swapAmount}(
            token,
            swapAmount,
            router,
            swapData,
            usxReceiver,
            usdcReceiver
        );

        // swapRouter sends exactly swapAmount USDC to gateway, fee is charged before bridging
        (
            address depToken,
            bytes memory depTo,
            uint256 depAmount,
            ,
            ,
            ,

        ) = l1Gateway.lastDeposit();
        uint256 expectedFee = (swapAmount * gateway.feePercentage()) / 1e18;
        if (expectedFee > gateway.maxFeeAmount()) {
            expectedFee = gateway.maxFeeAmount();
        }
        uint256 expectedNet = swapAmount - expectedFee;
        assertEq(depAmount, expectedNet);
        assertEq(depTo, usdcReceiver.receiver);
        assertEq(depToken, address(usdc));

        // balances: router -> gateway (swapAmount) -> L1 gateway (net), fee remains in gateway
        assertEq(
            usdc.balanceOf(address(swapRouter)),
            routerUsdcBefore - swapAmount
        );
        assertEq(
            usdc.balanceOf(address(gateway)),
            gatewayUsdcBefore + expectedFee
        );
        assertEq(
            usdc.balanceOf(address(l1Gateway)),
            l1UsdcBefore + expectedNet
        );
        // ETH should not be left in the gateway (fully forwarded to router)
        assertEq(address(gateway).balance, gatewayEthBefore);
    }

    function test_transferToken_eth_reverts_when_msgValue_mismatch() public {
        (uint256 keyId, bytes memory keyBytes) = _registerKey();

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: keyBytes,
                keyId: keyId
            });
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: hex"55",
                keyId: keyId
            });

        address token = address(0);
        address router = address(swapRouter);

        vm.startPrank(admin);
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        gateway.updateSupportedTokens(tokens, true);
        gateway.updateSupportedSwapRouter(router, router, true);
        vm.stopPrank();

        uint256 swapAmount = 500e6;
        bytes memory swapData = abi.encodeWithSelector(
            MockSwapRouter.swapToUSDC.selector,
            swapAmount,
            address(0),
            address(usdc)
        );

        address user = address(0xF0F0);
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(PrivateGatewayScroll.ErrorInvalidAmount.selector);
        gateway.transferToken{value: swapAmount - 1}(
            token,
            swapAmount,
            router,
            swapData,
            usxReceiver,
            usdcReceiver
        );
    }

    function test_transferToken_noneth_happy_path_swaps_and_bridges() public {
        (uint256 keyId, bytes memory keyBytes) = _registerKey();

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: keyBytes,
                keyId: keyId
            });
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: hex"44",
                keyId: keyId
            });

        // use USX mock token as generic ERC20 to be swapped into USDC
        address tokenIn = address(usx);
        address router = address(swapRouter);

        vm.startPrank(admin);
        address[] memory tokens = new address[](1);
        tokens[0] = tokenIn;
        gateway.updateSupportedTokens(tokens, true);
        gateway.updateSupportedSwapRouter(router, router, true);
        vm.stopPrank();

        // router pre-funded with USDC so it can pay out swap proceeds
        deal(address(usdc), address(swapRouter), 1_000_000e6);

        uint256 routerUsdcBefore = usdc.balanceOf(address(swapRouter));
        uint256 gatewayUsdcBefore = usdc.balanceOf(address(gateway));
        uint256 l1UsdcBefore = usdc.balanceOf(address(l1Gateway));

        uint256 swapAmount = 400e6;
        address user = address(0xCAFE);

        // give user the input token and approve the gateway
        deal(tokenIn, user, swapAmount);
        vm.startPrank(user);
        IERC20(tokenIn).approve(address(gateway), type(uint256).max);
        bytes memory swapData = abi.encodeWithSelector(
            MockSwapRouter.swapToUSDC.selector,
            swapAmount,
            tokenIn,
            address(usdc)
        );
        gateway.transferToken(
            tokenIn,
            swapAmount,
            router,
            swapData,
            usxReceiver,
            usdcReceiver
        );
        vm.stopPrank();

        // check deposit parameters
        (
            address depToken,
            bytes memory depTo,
            uint256 depAmount,
            ,
            ,
            ,

        ) = l1Gateway.lastDeposit();
        uint256 expectedFee = (swapAmount * gateway.feePercentage()) / 1e18;
        if (expectedFee > gateway.maxFeeAmount()) {
            expectedFee = gateway.maxFeeAmount();
        }
        uint256 expectedNet = swapAmount - expectedFee;
        assertEq(depAmount, expectedNet);
        assertEq(depTo, usdcReceiver.receiver);
        assertEq(depToken, address(usdc));

        // balances:
        // - router: loses USDC equal to swapAmount, gains input token
        // - gateway: gains USDC fee, does not hold input token
        // - L1 gateway: gains net bridged USDC
        // - user: loses the input token
        assertEq(
            usdc.balanceOf(address(swapRouter)),
            routerUsdcBefore - swapAmount
        );
        assertEq(
            usdc.balanceOf(address(gateway)),
            gatewayUsdcBefore + expectedFee
        );
        assertEq(
            usdc.balanceOf(address(l1Gateway)),
            l1UsdcBefore + expectedNet
        );
        assertEq(IERC20(tokenIn).balanceOf(user), 0);
        assertEq(IERC20(tokenIn).balanceOf(address(gateway)), 0);
    }

    function test_transferToken_reverts_when_swap_fails() public {
        (uint256 keyId, bytes memory keyBytes) = _registerKey();

        PrivateGatewayScroll.EncryptedReceiver
            memory usxReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: keyBytes,
                keyId: keyId
            });
        PrivateGatewayScroll.EncryptedReceiver
            memory usdcReceiver = PrivateGatewayScroll.EncryptedReceiver({
                receiver: hex"66",
                keyId: keyId
            });

        address tokenIn = address(usx);
        address router = address(swapRouterReverting);

        vm.startPrank(admin);
        address[] memory tokens = new address[](1);
        tokens[0] = tokenIn;
        gateway.updateSupportedTokens(tokens, true);
        gateway.updateSupportedSwapRouter(router, router, true);
        vm.stopPrank();

        uint256 swapAmount = 400e6;
        address user = address(0xBADD);

        deal(tokenIn, user, swapAmount);
        vm.startPrank(user);
        IERC20(tokenIn).approve(address(gateway), type(uint256).max);
        bytes memory swapData = abi.encodeWithSelector(
            MockSwapRouterReverting.swapToUSDC.selector,
            swapAmount,
            tokenIn,
            address(usdc)
        );
        vm.expectRevert(PrivateGatewayScroll.ErrorSwapFailed.selector);
        gateway.transferToken(
            tokenIn,
            swapAmount,
            router,
            swapData,
            usxReceiver,
            usdcReceiver
        );
        vm.stopPrank();
    }
}
