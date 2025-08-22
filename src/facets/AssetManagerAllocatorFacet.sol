// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TreasuryStorage} from "../TreasuryStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// standaradized interface for Asset Manager's contract
interface IAssetManager {
    function deposit(uint256 _usdcAmount) external;
    function withdraw(uint256 _usdcAmount) external;
}

contract AssetManagerAllocatorFacet is TreasuryStorage {
    
    /*=========================== Public Functions =========================*/
    
    // Checks if a deposit on the sUSX contract would exceed the max protocol leverage.
    // e.g. maxLeverage of 10 means treasury will allocate to Asset Manager no more USDC than x10 USX held by vault
    // Returns true if deposit would be allowed, false if it would exceed the max leverage.
    function checkMaxLeverage(uint256 depositAmount) public view returns (bool) {
        uint256 maxAllocation = maxLeverage * USX.balanceOf(address(sUSX));
        uint256 currentAllocationOfAssetManager = assetManagerUSDC;
        if (currentAllocationOfAssetManager + depositAmount > maxAllocation) {
            return false;
        }
        return true;
    }

    function netDeposits() public view returns (uint256) {
        return USDC.balanceOf(address(this)) + assetManagerUSDC;
    }

    /*=========================== Governance Functions =========================*/
    
    // sets the current Asset Manager for the protocol
    function setAssetManager(address _assetManager) external onlyGovernance {
        if (_assetManager == address(0)) revert ZeroAddress();
        assetManager = _assetManager;
    }

    // sets the max leverage for the protocol
    function setMaxLeverage(uint256 _maxLeverage) external onlyGovernance {
        if (_maxLeverage > 100000) revert InvalidMaxLeverage();
        maxLeverage = _maxLeverage;
    }
    
    /*=========================== Asset Manager Functions =========================*/
    
    function transferUSDCtoAssetManager(uint256 _amount) external {
        if (msg.sender != assetManager) revert NotAssetManager();

        // Check if the transfer would exceed the max leverage
        if (!checkMaxLeverage(_amount)) revert MaxLeverageExceeded();

        assetManagerUSDC += _amount;
        IAssetManager(assetManager).deposit(_amount);
    }

    function transferUSDCFromAssetManager(uint256 _amount) external {
        if (msg.sender != assetManager) revert NotAssetManager();
        assetManagerUSDC -= _amount;
        IAssetManager(assetManager).withdraw(_amount);
    }
}
