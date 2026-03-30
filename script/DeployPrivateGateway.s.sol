// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {PrivateGatewayScroll} from "../src/cloak/PrivateGatewayScroll.sol";
import {PrivateGatewayCloak} from "../src/cloak/PrivateGatewayCloak.sol";

/// @notice Minimal placeholder implementation for proxy. Used in step 1 so proxy is deployed with empty logic, then upgraded in step 2.
contract EmptyImpl {
    fallback() external payable {}
}

/**
 * @title DeployPrivateGateway
 * @dev Two-step deployment for PrivateGatewayScroll and PrivateGatewayCloak behind TransparentUpgradeableProxy.
 *      Step from env STEP (required: "1" or "2"). Chain determines which gateway is deployed:
 *      - Scroll (chainId 534352): deploy PrivateGatewayScroll only.
 *      - Cloak (chainId 5343523304): deploy PrivateGatewayCloak only.
 *   STEP=1: Deploy TransparentUpgradeableProxy with EmptyImpl as placeholder implementation.
 *   STEP=2: Deploy real implementation and upgrade proxy, then call initialize.
 */
contract DeployPrivateGateway is Script {
    uint256 public constant SCROLL_CHAIN_ID = 534352;
    uint256 public constant CLOAK_CHAIN_ID = 5343523304;

    uint256 public SCROLL_PRIVATE_KEY = vm.envUint("SCROLL_PRIVATE_KEY");
    uint256 public CLOAK_PRIVATE_KEY = vm.envUint("CLOAK_PRIVATE_KEY");

    // ─── Step 1 outputs (set these as env for step 2 if running separately) ───
    address public scrollProxyAdmin;
    address public scrollProxy;
    address public cloakProxyAdmin;
    address public cloakProxy;
    address public emptyImpl;

    // ─── Step 2: implementation addresses after deploy ───
    address public scrollImpl;
    address public cloakImpl;

    function _isScroll() internal view returns (bool) {
        return block.chainid == SCROLL_CHAIN_ID;
    }

    function _isCloak() internal view returns (bool) {
        return block.chainid == CLOAK_CHAIN_ID;
    }

    /// @dev Entry point: read STEP from env ("1" or "2") and run the corresponding step.
    function run() public {
        require(_isScroll() || _isCloak(), "Unsupported chain id");

        string memory step = vm.envString("STEP");
        require(
            keccak256(bytes(step)) == keccak256("1") ||
                keccak256(bytes(step)) == keccak256("2"),
            "STEP must be 1 or 2"
        );

        if (keccak256(bytes(step)) == keccak256("1")) {
            if (_isScroll()) {
                vm.startBroadcast(SCROLL_PRIVATE_KEY);
            } else if (_isCloak()) {
                vm.startBroadcast(CLOAK_PRIVATE_KEY);
            }
            _step1_DeployProxiesWithEmptyImpl();
            vm.stopBroadcast();

            console.log("=== Step 1 done. Set for step 2:");
            if (_isScroll()) {
                console.log("export SCROLL_PROXY_ADMIN=%s", scrollProxyAdmin);
                console.log("export SCROLL_GATEWAY_PROXY=%s", scrollProxy);
            }
            if (_isCloak()) {
                console.log("export CLOAK_PROXY_ADMIN=%s", cloakProxyAdmin);
                console.log("export CLOAK_GATEWAY_PROXY=%s", cloakProxy);
            }
            return;
        }

        if (keccak256(bytes(step)) == keccak256("2")) {
            scrollProxyAdmin = vm.envAddress("SCROLL_PROXY_ADMIN");
            scrollProxy = vm.envAddress("SCROLL_GATEWAY_PROXY");
            cloakProxyAdmin = vm.envAddress("CLOAK_PROXY_ADMIN");
            cloakProxy = vm.envAddress("CLOAK_GATEWAY_PROXY");

            address deployer;
            if (_isScroll()) {
                vm.startBroadcast(SCROLL_PRIVATE_KEY);
                deployer = vm.addr(SCROLL_PRIVATE_KEY);
            } else if (_isCloak()) {
                vm.startBroadcast(CLOAK_PRIVATE_KEY);
                deployer = vm.addr(CLOAK_PRIVATE_KEY);
            }
            _step2_DeployImplAndUpgrade(deployer);
            vm.stopBroadcast();
            _logSummary();
        }
    }

    function _step1_DeployProxiesWithEmptyImpl() internal {
        console.log(
            "=== Step 1: Deploy EmptyImpl and TransparentUpgradeableProxy (chainId %s) ===",
            block.chainid
        );

        emptyImpl = address(new EmptyImpl());
        console.log("EmptyImpl:", emptyImpl);

        bytes memory emptyData = "";

        if (_isScroll()) {
            scrollProxyAdmin = address(new ProxyAdmin());
            TransparentUpgradeableProxy scrollTUP = new TransparentUpgradeableProxy(
                    emptyImpl,
                    scrollProxyAdmin,
                    emptyData
                );
            scrollProxy = address(scrollTUP);
            console.log("PrivateGatewayScroll proxy admin:", scrollProxyAdmin);
            console.log("PrivateGatewayScroll proxy:", scrollProxy);
        }
        if (_isCloak()) {
            cloakProxyAdmin = address(new ProxyAdmin());
            TransparentUpgradeableProxy cloakTUP = new TransparentUpgradeableProxy(
                    emptyImpl,
                    cloakProxyAdmin,
                    emptyData
                );
            cloakProxy = address(cloakTUP);
            console.log("PrivateGatewayCloak proxy:", cloakProxy);
            console.log("PrivateGatewayCloak proxy admin:", cloakProxyAdmin);
        }
    }

    function _step2_DeployImplAndUpgrade(address deployer) internal {
        console.log(
            "=== Step 2: Deploy implementation and upgrade proxy (chainId %s) ===",
            block.chainid
        );

        if (_isScroll()) {
            PrivateGatewayScroll scrollImplContract = new PrivateGatewayScroll(
                0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4, // USDC in Scroll
                0x3b005fefC63Ca7c8d25eE21FbA3787229ba4CF03, // USX in Scroll
                0xE22Ae02876539EdBa297EC4ec141BE806AB9F7f1, // L1 ERC20 Gateway in Scroll
                address(cloakProxy) // PrivateGatewayCloak in Cloak
            );
            scrollImpl = address(scrollImplContract);
            console.log("PrivateGatewayScroll impl:", scrollImpl);

            bytes memory scrollInitData = abi.encodeCall(
                PrivateGatewayScroll.initialize,
                (deployer, 0, 0, 0)
            );
            ProxyAdmin(scrollProxyAdmin).upgradeAndCall(
                ITransparentUpgradeableProxy(payable(scrollProxy)),
                scrollImpl,
                scrollInitData
            );
            console.log("PrivateGatewayScroll upgraded and initialized");
        }

        if (_isCloak()) {
            PrivateGatewayCloak cloakImplContract = new PrivateGatewayCloak(
                0x8bD8424405d9518f9cDE6839F9b8d057d98Ced4E, // USDC in Cloak
                0x73D7c3dffB020f34d4c213161Cb98Ad25e8D9c18, // USX in Cloak
                0x5752C6E8478dE1eCc1f7C77f00811B3f9031c0d3, // L2 ERC20 Gateway in Cloak
                address(scrollProxy) // PrivateGatewayScroll in Scroll
            );
            cloakImpl = address(cloakImplContract);
            console.log("PrivateGatewayCloak impl:", cloakImpl);

            bytes memory cloakInitData = abi.encodeCall(
                PrivateGatewayCloak.initialize,
                (deployer)
            );
            ProxyAdmin(cloakProxyAdmin).upgradeAndCall(
                ITransparentUpgradeableProxy(payable(cloakProxy)),
                cloakImpl,
                cloakInitData
            );
            console.log("PrivateGatewayCloak upgraded and initialized");
        }
    }

    function _logSummary() internal view {
        console.log("=== Deployment summary (chainId %s) ===", block.chainid);
        if (_isScroll()) {
            console.log("PrivateGatewayScroll proxy:", scrollProxy);
            console.log("PrivateGatewayScroll impl:", scrollImpl);
        }
        if (_isCloak()) {
            console.log("PrivateGatewayCloak proxy:", cloakProxy);
            console.log("PrivateGatewayCloak impl:", cloakImpl);
        }
    }
}
