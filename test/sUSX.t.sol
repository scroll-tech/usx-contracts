// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {sUSX} from "../src/sUSX.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract sUSXTest is Test {
    sUSX public susx;
    sUSX public susxImplementation;
    
    address public governance = address(0x1);
    address public treasury = address(0x2);
    address public usx = address(0x3);

    function setUp() public {
        // Deploy implementation
        susxImplementation = new sUSX();
        
        // Deploy proxy with initialization data
        bytes memory initData = abi.encodeWithSelector(
            sUSX.initialize.selector,
            usx,
            treasury,
            governance
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(susxImplementation),
            initData
        );
        
        susx = sUSX(address(proxy));
    }

    // ============ Basic Deployment Tests ============
    
    function test_deploy_susx_success() public {
        assertEq(address(susx.USX()), usx);
        assertEq(address(susx.treasury()), treasury);
        assertEq(susx.governance(), governance);
        assertEq(susx.name(), "sUSX Token");
        assertEq(susx.symbol(), "sUSX");
        assertEq(susx.decimals(), 18);
    }
    
    function test_default_values() public {
        assertEq(susx.withdrawalPeriod(), 108000);
        assertEq(susx.withdrawalFeeFraction(), 500);
        assertEq(susx.minWithdrawalPeriod(), 108000);
        assertEq(susx.epochDuration(), 216000);
    }
    
    function test_initial_state() public {
        assertEq(susx.totalSupply(), 0);
        assertEq(susx.withdrawalIdCounter(), 0);
        assertEq(susx.lastEpochBlock(), 1); // Should be set to deployment block (1)
    }
}
