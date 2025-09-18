// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RewardDistributorFacet} from "../../src/facets/RewardDistributorFacet.sol";
import {TreasuryDiamond} from "../../src/TreasuryDiamond.sol";
import {TreasuryStorage} from "../../src/TreasuryStorage.sol";
import {USX} from "../../src/USX.sol";
import {StakedUSX} from "../../src/StakedUSX.sol";

import {LocalDeployTestSetup} from "../LocalDeployTestSetup.sol";

contract RewardDistributorFacetTest is LocalDeployTestSetup {
    RewardDistributorFacet private facet;

    function setUp() public override {
        super.setUp();
        facet = RewardDistributorFacet(address(treasury));
    }

    function test_successFee_defaultFivePercent() public {
        // default successFeeFraction is 5% (50000 / 1e6)
        uint256 fee = facet.successFee(1_000_000);
        assertEq(fee, 50_000);
    }

    function test_insuranceFund_defaultFivePercent() public {
        uint256 fund = facet.insuranceFund(2_000_000);
        assertEq(fund, 100_000);
    }

    function test_setSuccessFeeFraction_byGovernance() public {
        vm.prank(governance);
        facet.setSuccessFeeFraction(42_000);
        assertEq(TreasuryDiamond(payable(address(facet))).successFeeFraction(), 42_000);
    }

    function test_setSuccessFeeFraction_revertWhenAboveMax() public {
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.InvalidSuccessFeeFraction.selector);
        facet.setSuccessFeeFraction(100_001);
    }

    function test_setSuccessFeeFraction_revertWhenNotGovernance() public {
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        facet.setSuccessFeeFraction(10_000);
    }

    function test_setInsuranceFundFraction_byGovernance() public {
        vm.prank(governance);
        facet.setInsuranceFundFraction(55_000);
        assertEq(TreasuryDiamond(payable(address(facet))).insuranceFundFraction(), 55_000);
    }

    function test_setInsuranceFundFraction_revertWhenAboveMax() public {
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.InvalidInsuranceFundFraction.selector);
        facet.setInsuranceFundFraction(100_001);
    }

    function test_setInsuranceFundFraction_revertWhenNotGovernance() public {
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        facet.setInsuranceFundFraction(10_000);
    }

    function test_setReporter_setsReporter() public {
        vm.prank(governance);
        facet.setReporter(address(0xABC));
        // call reportRewards as reporter should succeed (no revert)
        vm.prank(address(0xABC));
        facet.reportRewards(0);
    }

    function test_setReporter_revertNotGovernance() public {
        vm.expectRevert(TreasuryStorage.NotGovernance.selector);
        facet.setReporter(address(0xABC));
    }

    function test_setReporter_revertZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(TreasuryStorage.ZeroAddress.selector);
        facet.setReporter(address(0));
    }

    function test_assetManagerReport_revertWhenNotReporter() public {
        // reporter not set yet → zero address, so any call should revert NotReporter
        vm.expectRevert(TreasuryStorage.NotReporter.selector);
        facet.reportRewards(1);
    }

    function test_assetManagerReport_profitPath_distributesCorrectly_andEmits() public {
        // set reporter
        vm.prank(governance);
        facet.setReporter(address(0xBEEF));

        // capture initial balances
        USX _usx = usx;
        StakedUSX _susx = susx;
        address insurance = insuranceVault;
        address warchest = governanceWarchest;

        uint256 profitUSDC = 1_000_000; // 1,000,000 USDC units (6 decimals)
        uint256 expectedInsurance = facet.insuranceFund(profitUSDC); // 5% = 50,000
        uint256 expectedSuccessFee = facet.successFee(profitUSDC); // 5% = 50,000
        uint256 expectedStakers = profitUSDC - expectedInsurance - expectedSuccessFee; // 900,000

        uint256 usxBalInsuranceBefore = _usx.balanceOf(insurance);
        uint256 usxBalWarchestBefore = _usx.balanceOf(warchest);
        uint256 usxBalSusxBefore = _usx.balanceOf(address(_susx));
        uint256 netEpochBefore = TreasuryDiamond(payable(address(facet))).netEpochProfits();

        vm.expectEmit(true, true, true, true, address(treasury));
        emit TreasuryStorage.ReportSubmitted(profitUSDC, true);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit TreasuryStorage.RewardsDistributed(profitUSDC, expectedStakers, expectedInsurance, expectedSuccessFee);

        vm.prank(address(0xBEEF));
        facet.reportRewards(profitUSDC);

        // minted amounts are scaled by DECIMAL_SCALE_FACTOR (1e12)
        uint256 scaled = 1e12;
        assertEq(_usx.balanceOf(insurance) - usxBalInsuranceBefore, expectedInsurance * scaled);
        assertEq(_usx.balanceOf(warchest) - usxBalWarchestBefore, expectedSuccessFee * scaled);
        assertEq(_usx.balanceOf(address(_susx)) - usxBalSusxBefore, expectedStakers * scaled);

        // netEpochProfits increases by staker profits (in USDC units)
        assertEq(TreasuryDiamond(payable(address(facet))).netEpochProfits(), netEpochBefore + expectedStakers);
    }
}
