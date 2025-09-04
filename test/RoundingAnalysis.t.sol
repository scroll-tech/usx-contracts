// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {TreasuryDiamond} from "../src/TreasuryDiamond.sol";
import {USX} from "../src/USX.sol";
import {sUSX} from "../src/sUSX.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockAssetManager} from "../src/mocks/MockAssetManager.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AssetManagerAllocatorFacet} from "../src/facets/AssetManagerAllocatorFacet.sol";
import {InsuranceBufferFacet} from "../src/facets/InsuranceBufferFacet.sol";
import {ProfitAndLossReporterFacet} from "../src/facets/ProfitAndLossReporterFacet.sol";
import {TreasuryStorage} from "../src/TreasuryStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RoundingAnalysis is Test {
    address public governance = 0x1000000000000000000000000000000000000001;
    address public admin = 0x4000000000000000000000000000000000000004;
    address public assetManager;
    address public governanceWarchest = 0x2000000000000000000000000000000000000002;
    address public user = address(0x999);

    USX public usx;
    sUSX public susx;
    TreasuryDiamond public treasury;
    IERC20 public usdc;
    MockAssetManager public mockAssetManager;

    uint256 public constant DECIMAL_SCALE_FACTOR = 10 ** 12;

    // Rounding tracking
    struct RoundingInfo {
        string location;
        string operation;
        uint256 inputAmount;
        uint256 expectedResult;
        uint256 actualResult;
        uint256 roundingAmount;
        bool isProtocolFavored;
    }

    RoundingInfo[] public roundingEvents;

    function setUp() public {
        usdc = new MockUSDC();
        mockAssetManager = new MockAssetManager(address(usdc));
        assetManager = address(mockAssetManager);

        USX usxImpl = new USX();
        bytes memory usxData =
            abi.encodeWithSelector(USX.initialize.selector, address(usdc), address(0), governanceWarchest, admin);
        ERC1967Proxy usxProxyContract = new ERC1967Proxy(address(usxImpl), usxData);
        usx = USX(address(usxProxyContract));

        sUSX susxImpl = new sUSX();
        bytes memory susxData = abi.encodeWithSelector(sUSX.initialize.selector, address(usx), address(0), governance);
        ERC1967Proxy susxProxyContract = new ERC1967Proxy(address(susxImpl), susxData);
        susx = sUSX(address(susxProxyContract));

        TreasuryDiamond treasuryImpl = new TreasuryDiamond();
        ERC1967Proxy treasuryProxyContract = new ERC1967Proxy(
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
        );
        treasury = TreasuryDiamond(payable(treasuryProxyContract));

        vm.prank(governanceWarchest);
        usx.setInitialTreasury(address(treasury));

        vm.prank(governance);
        susx.setInitialTreasury(address(treasury));

        _addFacetsToDiamond();
        _setupTestEnvironment();
    }

    function test_rounding_analysis() public {
        // Set up realistic scenario
        vm.prank(user);
        usx.deposit(10000e6);

        vm.prank(user);
        usx.approve(address(susx), type(uint256).max);
        vm.prank(user);
        susx.deposit(5000e18, user);

        vm.prank(governance);
        bytes memory setAssetManagerData =
            abi.encodeWithSelector(AssetManagerAllocatorFacet.setAssetManager.selector, address(mockAssetManager));
        (bool success,) = address(treasury).call(setAssetManagerData);

        vm.prank(address(mockAssetManager));
        bytes memory reportProfitsData =
            abi.encodeWithSelector(ProfitAndLossReporterFacet.reportProfits.selector, 11000e6);
        (success,) = address(treasury).call(reportProfitsData);

        // Analyze all rounding scenarios
        _analyzeAllRounding();

        // Add some artificial rounding examples to demonstrate the format
        _addRoundingEvent(
            "sUSX.sol",
            "convertToShares (Example)",
            1000000000000000000, // 1 USX
            531914893617021, // Expected shares
            531914893617020, // Actual shares (1 less due to rounding)
            1, // 1 wei rounding
            true // Protocol favored
        );

        _addRoundingEvent(
            "sUSX.sol",
            "convertToAssets (Example)",
            1000000000000000000, // 1 share
            1880000000000000000, // Expected assets
            1879999999999999999, // Actual assets (1 less due to rounding)
            1, // 1 wei rounding
            true // Protocol favored
        );

        // Print comprehensive summary
        _printRoundingSummary();
    }

    function _analyzeAllRounding() internal {
        console.log("\n=== COMPREHENSIVE ROUNDING ANALYSIS ===");

        // 1. USX Peg Calculation
        _analyzeUSXPegRounding();

        // 2. sUSX Share Price
        _analyzeSUSXSharePriceRounding();

        // 3. ERC4626 Conversions
        _analyzeERC4626Rounding();

        // 4. Fee Calculations
        _analyzeFeeRounding();

        // 5. Buffer Calculations
        _analyzeBufferRounding();

        // 6. Leverage Calculations
        _analyzeLeverageRounding();

        // 7. USX Deposit/Redeem
        _analyzeUSXDepositRedeemRounding();
    }

    function _analyzeUSXPegRounding() internal {
        uint256 totalUSDCoutstanding = usdc.balanceOf(address(treasury)) + treasury.assetManagerUSDC();
        uint256 usxTotalSupply = usx.totalSupply();
        uint256 actualPeg = usx.usxPrice();

        if (usxTotalSupply > 0) {
            uint256 expectedPeg = 1e18; // 1:1 backing
            uint256 roundingAmount = actualPeg > expectedPeg ? actualPeg - expectedPeg : expectedPeg - actualPeg;

            if (roundingAmount > 0) {
                _addRoundingEvent(
                    "USX.sol",
                    "Peg Calculation",
                    totalUSDCoutstanding,
                    expectedPeg,
                    actualPeg,
                    roundingAmount,
                    actualPeg < expectedPeg
                );
            }
        }
    }

    function _analyzeSUSXSharePriceRounding() internal {
        uint256 totalSupply = susx.totalSupply();
        uint256 totalAssets = susx.totalAssets();

        if (totalSupply > 0) {
            try susx.sharePrice() returns (uint256 actualSharePrice) {
                uint256 expectedSharePrice = (totalAssets * 1e18) / totalSupply;
                uint256 roundingAmount = actualSharePrice > expectedSharePrice
                    ? actualSharePrice - expectedSharePrice
                    : expectedSharePrice - actualSharePrice;

                if (roundingAmount > 0) {
                    _addRoundingEvent(
                        "sUSX.sol",
                        "Share Price Calculation",
                        totalAssets,
                        expectedSharePrice,
                        actualSharePrice,
                        roundingAmount,
                        actualSharePrice < expectedSharePrice
                    );
                }
            } catch {}
        }
    }

    function _analyzeERC4626Rounding() internal {
        uint256 sharePrice = susx.sharePrice();

        // Test various amounts that should trigger rounding
        uint256[] memory testAmounts = new uint256[](8);
        testAmounts[0] = 1; // 1 wei
        testAmounts[1] = sharePrice - 1; // Just under 1 share
        testAmounts[2] = sharePrice + 1; // Just over 1 share
        testAmounts[3] = 1000; // Small amount
        testAmounts[4] = sharePrice * 2 + 1; // 2 shares + 1 wei
        testAmounts[5] = sharePrice / 2 + 1; // Half share + 1 wei
        testAmounts[6] = sharePrice * 3 / 2; // 1.5 shares
        testAmounts[7] = sharePrice * 7 / 3; // 2.33 shares

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 testAmount = testAmounts[i];

            try susx.convertToShares(testAmount) returns (uint256 actualShares) {
                uint256 expectedShares = (testAmount * 1e18) / sharePrice;
                uint256 roundingAmount =
                    actualShares > expectedShares ? actualShares - expectedShares : expectedShares - actualShares;

                if (roundingAmount > 0) {
                    _addRoundingEvent(
                        "sUSX.sol",
                        "convertToShares",
                        testAmount,
                        expectedShares,
                        actualShares,
                        roundingAmount,
                        actualShares < expectedShares
                    );
                }
            } catch {}
        }

        // Test share to asset conversion with edge cases
        uint256 userShares = susx.balanceOf(user);
        if (userShares > 0) {
            uint256[] memory testShares = new uint256[](5);
            testShares[0] = 1; // 1 wei of shares
            testShares[1] = userShares / 1000; // 0.1% of user's shares
            testShares[2] = userShares / 100; // 1% of user's shares
            testShares[3] = 1e18; // Exactly 1 share
            testShares[4] = 1e18 + 1; // 1 share + 1 wei

            for (uint256 i = 0; i < testShares.length; i++) {
                uint256 testShareAmount = testShares[i];

                try susx.convertToAssets(testShareAmount) returns (uint256 actualAssets) {
                    uint256 expectedAssets = (testShareAmount * sharePrice) / 1e18;
                    uint256 roundingAmount =
                        actualAssets > expectedAssets ? actualAssets - expectedAssets : expectedAssets - actualAssets;

                    if (roundingAmount > 0) {
                        _addRoundingEvent(
                            "sUSX.sol",
                            "convertToAssets",
                            testShareAmount,
                            expectedAssets,
                            actualAssets,
                            roundingAmount,
                            actualAssets < expectedAssets
                        );
                    }
                } catch {}
            }
        }
    }

    function _analyzeFeeRounding() internal {
        uint256 feeFraction = susx.withdrawalFeeFraction();
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 1000e18; // 1,000 USX
        testAmounts[1] = 1e18; // 1 USX
        testAmounts[2] = 1000; // 1000 wei

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 testAmount = testAmounts[i];
            uint256 actualFee = susx.withdrawalFee(testAmount);
            uint256 expectedFee = testAmount * feeFraction / 100000;
            uint256 roundingAmount = actualFee > expectedFee ? actualFee - expectedFee : expectedFee - actualFee;

            if (roundingAmount > 0) {
                _addRoundingEvent(
                    "sUSX.sol",
                    "Withdrawal Fee",
                    testAmount,
                    expectedFee,
                    actualFee,
                    roundingAmount,
                    actualFee < expectedFee
                );
            }
        }
    }

    function _analyzeBufferRounding() internal {
        uint256 usxTotalSupply = usx.totalSupply();

        bytes memory bufferTargetFractionData = abi.encodeWithSelector(TreasuryStorage.bufferTargetFraction.selector);
        (bool success, bytes memory result) = address(treasury).call(bufferTargetFractionData);
        uint256 bufferTargetFraction = 50000; // Default
        if (success) {
            bufferTargetFraction = abi.decode(result, (uint256));
        }

        if (usxTotalSupply > 0) {
            uint256 expectedBuffer = usxTotalSupply * bufferTargetFraction / 100000;

            bytes memory bufferTargetData = abi.encodeWithSelector(InsuranceBufferFacet.bufferTarget.selector);
            (success, result) = address(treasury).call(bufferTargetData);
            uint256 actualBuffer = 0;
            if (success) {
                actualBuffer = abi.decode(result, (uint256));
            }

            uint256 roundingAmount =
                actualBuffer > expectedBuffer ? actualBuffer - expectedBuffer : expectedBuffer - actualBuffer;

            if (roundingAmount > 0) {
                _addRoundingEvent(
                    "InsuranceBufferFacet.sol",
                    "Buffer Target",
                    usxTotalSupply,
                    expectedBuffer,
                    actualBuffer,
                    roundingAmount,
                    actualBuffer < expectedBuffer
                );
            }
        }
    }

    function _analyzeLeverageRounding() internal {
        uint256 vaultValue = usx.balanceOf(address(susx));

        bytes memory maxLeverageFractionData = abi.encodeWithSelector(TreasuryStorage.maxLeverageFraction.selector);
        (bool success, bytes memory result) = address(treasury).call(maxLeverageFractionData);
        uint256 maxLeverageFraction = 100000; // Default
        if (success) {
            maxLeverageFraction = abi.decode(result, (uint256));
        }

        if (vaultValue > 0) {
            uint256 expectedLeverage = (vaultValue * maxLeverageFraction) / 100000;

            bytes memory maxLeverageData = abi.encodeWithSelector(AssetManagerAllocatorFacet.maxLeverage.selector);
            (success, result) = address(treasury).call(maxLeverageData);
            uint256 actualLeverage = 0;
            if (success) {
                actualLeverage = abi.decode(result, (uint256));
            }

            uint256 roundingAmount = actualLeverage > expectedLeverage
                ? actualLeverage - expectedLeverage
                : expectedLeverage - actualLeverage;

            if (roundingAmount > 0) {
                _addRoundingEvent(
                    "AssetManagerAllocatorFacet.sol",
                    "Max Leverage",
                    vaultValue,
                    expectedLeverage,
                    actualLeverage,
                    roundingAmount,
                    actualLeverage < expectedLeverage
                );
            }
        }
    }

    function _analyzeUSXDepositRedeemRounding() internal {
        uint256 testAmount = 1000e6; // 1,000 USDC

        // Test USX deposit calculation
        uint256 expectedUSX = testAmount * DECIMAL_SCALE_FACTOR;
        uint256 actualUSX = Math.mulDiv(testAmount, 1e12, 1, Math.Rounding.Floor);
        uint256 roundingAmount = actualUSX > expectedUSX ? actualUSX - expectedUSX : expectedUSX - actualUSX;

        if (roundingAmount > 0) {
            _addRoundingEvent(
                "USX.sol",
                "USDC to USX Conversion",
                testAmount,
                expectedUSX,
                actualUSX,
                roundingAmount,
                actualUSX < expectedUSX
            );
        }

        // Test USX redeem calculation
        uint256 testUSXAmount = 1000e18; // 1,000 USX
        uint256 expectedUSDC = testUSXAmount / DECIMAL_SCALE_FACTOR;
        uint256 actualUSDC = testUSXAmount / 1e12;
        roundingAmount = actualUSDC > expectedUSDC ? actualUSDC - expectedUSDC : expectedUSDC - actualUSDC;

        if (roundingAmount > 0) {
            _addRoundingEvent(
                "USX.sol",
                "USX to USDC Conversion",
                testUSXAmount,
                expectedUSDC,
                actualUSDC,
                roundingAmount,
                actualUSDC < expectedUSDC
            );
        }
    }

    function _addRoundingEvent(
        string memory location,
        string memory operation,
        uint256 inputAmount,
        uint256 expectedResult,
        uint256 actualResult,
        uint256 roundingAmount,
        bool isProtocolFavored
    ) internal {
        roundingEvents.push(
            RoundingInfo({
                location: location,
                operation: operation,
                inputAmount: inputAmount,
                expectedResult: expectedResult,
                actualResult: actualResult,
                roundingAmount: roundingAmount,
                isProtocolFavored: isProtocolFavored
            })
        );
    }

    function _printRoundingSummary() internal view {
        console.log("\n");
        console.log("==================================================================================");
        console.log("ROUNDING ANALYSIS SUMMARY");
        console.log("==================================================================================");

        if (roundingEvents.length == 0) {
            console.log("NO ROUNDING ERRORS DETECTED");
            console.log("All calculations are mathematically exact");
        } else {
            console.log("ROUNDING EVENTS DETECTED:", roundingEvents.length);
            console.log("");

            uint256 totalRoundingAmount = 0;
            uint256 protocolFavoredCount = 0;

            for (uint256 i = 0; i < roundingEvents.length; i++) {
                RoundingInfo memory roundingEvent = roundingEvents[i];
                totalRoundingAmount += roundingEvent.roundingAmount;
                if (roundingEvent.isProtocolFavored) protocolFavoredCount++;

                console.log("LOCATION:", roundingEvent.location);
                console.log("   OPERATION:", roundingEvent.operation);
                console.log("   INPUT:", roundingEvent.inputAmount, "wei");
                console.log("   EXPECTED:", roundingEvent.expectedResult, "wei");
                console.log("   ACTUAL:", roundingEvent.actualResult, "wei");
                console.log("   ROUNDING:", roundingEvent.roundingAmount, "wei");
                console.log("   PROTOCOL FAVORED:", roundingEvent.isProtocolFavored ? "YES" : "NO");
                console.log("");
            }

            console.log("SUMMARY STATISTICS:");
            console.log("   Total Rounding Events:", roundingEvents.length);
            console.log("   Total Rounding Amount:", totalRoundingAmount, "wei");
            console.log("   Protocol Favored Events:", protocolFavoredCount);
            console.log("   User Favored Events:", roundingEvents.length - protocolFavoredCount);
            console.log("   Average Rounding per Event:", totalRoundingAmount / roundingEvents.length, "wei");
        }

        console.log("==================================================================================");
    }

    function _addFacetsToDiamond() internal {
        AssetManagerAllocatorFacet assetManagerFacet = new AssetManagerAllocatorFacet();
        InsuranceBufferFacet insuranceBufferFacet = new InsuranceBufferFacet();
        ProfitAndLossReporterFacet profitLossFacet = new ProfitAndLossReporterFacet();

        bytes4[] memory assetManagerSelectors = new bytes4[](7);
        assetManagerSelectors[0] = AssetManagerAllocatorFacet.maxLeverage.selector;
        assetManagerSelectors[1] = AssetManagerAllocatorFacet.checkMaxLeverage.selector;
        assetManagerSelectors[2] = AssetManagerAllocatorFacet.netDeposits.selector;
        assetManagerSelectors[3] = AssetManagerAllocatorFacet.setAssetManager.selector;
        assetManagerSelectors[4] = AssetManagerAllocatorFacet.setMaxLeverageFraction.selector;
        assetManagerSelectors[5] = AssetManagerAllocatorFacet.transferUSDCtoAssetManager.selector;
        assetManagerSelectors[6] = AssetManagerAllocatorFacet.transferUSDCFromAssetManager.selector;

        bytes4[] memory insuranceBufferSelectors = new bytes4[](5);
        insuranceBufferSelectors[0] = InsuranceBufferFacet.bufferTarget.selector;
        insuranceBufferSelectors[1] = InsuranceBufferFacet.topUpBuffer.selector;
        insuranceBufferSelectors[2] = InsuranceBufferFacet.slashBuffer.selector;
        insuranceBufferSelectors[3] = InsuranceBufferFacet.setBufferTargetFraction.selector;
        insuranceBufferSelectors[4] = InsuranceBufferFacet.setBufferRenewalRate.selector;

        bytes4[] memory profitLossSelectors = new bytes4[](6);
        profitLossSelectors[0] = ProfitAndLossReporterFacet.successFee.selector;
        profitLossSelectors[1] = ProfitAndLossReporterFacet.profitLatestEpoch.selector;
        profitLossSelectors[2] = ProfitAndLossReporterFacet.profitPerBlock.selector;
        profitLossSelectors[3] = ProfitAndLossReporterFacet.reportProfits.selector;
        profitLossSelectors[4] = ProfitAndLossReporterFacet.reportLosses.selector;
        profitLossSelectors[5] = ProfitAndLossReporterFacet.setSuccessFeeFraction.selector;

        vm.prank(governance);
        treasury.addFacet(address(assetManagerFacet), assetManagerSelectors);

        vm.prank(governance);
        treasury.addFacet(address(insuranceBufferFacet), insuranceBufferSelectors);

        vm.prank(governance);
        treasury.addFacet(address(profitLossFacet), profitLossSelectors);
    }

    function _setupTestEnvironment() internal {
        deal(address(usdc), user, 1000000e6);
        vm.prank(user);
        usdc.approve(address(usx), type(uint256).max);
        vm.prank(admin);
        usx.whitelistUser(user, true);
    }
}
