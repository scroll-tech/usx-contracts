// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {USX} from "../src/USX.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract USXTest is Test {
    USX public usx;
    USX public usxImplementation;
    
    address public governance = address(0x1);
    address public treasury = address(0x2);
    address public usdc = address(0x3);

    function setUp() public {
        // Deploy implementation
        usxImplementation = new USX();
        
        // Deploy proxy with initialization data
        bytes memory initData = abi.encodeWithSelector(
            USX.initialize.selector,
            usdc,
            treasury,
            governance,
            governance
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(usxImplementation),
            initData
        );
        
        usx = USX(address(proxy));
    }

    // ============ Basic Deployment Tests ============
    
    function test_deploy_usx_success() public {
        assertEq(address(usx.USDC()), usdc);
        assertEq(address(usx.treasury()), treasury);
        assertEq(usx.governanceWarchest(), governance);
        assertEq(usx.admin(), governance);
        assertEq(usx.name(), "USX Token");
        assertEq(usx.symbol(), "USX");
        assertEq(usx.decimals(), 18);
    }
    
    function test_initial_state() public {
        assertEq(usx.totalSupply(), 0);
        assertFalse(usx.withdrawalsFrozen());
        assertEq(usx.usxPrice(), 1e18);
    }
}
