// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IAssetManager} from "../interfaces/IAssetManager.sol";

contract AssetManager is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    IAssetManager
{
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    /*=========================== Events =========================*/

    /// @notice Emitted when the weight of an account is updated
    /// @param account The account whose weight was updated
    /// @param oldWeight The old weight of the account
    /// @param newWeight The new weight of the account
    event WeightUpdated(
        address indexed account,
        uint256 oldWeight,
        uint256 newWeight
    );

    /// @notice Emitted when USDC is distributed to an account
    /// @param account The account to which USDC was distributed
    /// @param amount The amount of USDC distributed
    event USDCDistributed(address indexed account, uint256 amount);

    /*=========================== Errors =========================*/

    /// @dev Thrown when the caller is not the treasury
    error NotTreasury();

    /*=========================== Constants =========================*/

    /// @dev The role for the governance
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @dev The address of the USDC token
    address public immutable USDC;

    /// @dev The address of the treasury
    address public immutable treasury;

    /*=========================== Storage =========================*/

    /// @custom:storage-location erc7201:asset-manager.main
    struct AssetManagerStorage {
        EnumerableMap.AddressToUintMap weights;
        uint256 totalWeight;
    }

    // keccak256("asset-manager.main")
    bytes32 private constant ASSET_MANAGER_STORAGE_LOCATION =
        0x80eb0cdd16cb622196d298bc0913d06d921aa48c024ad1954e8e8ef1bbf9387d;

    function _getStorage()
        private
        pure
        returns (AssetManagerStorage storage $)
    {
        assembly {
            $.slot := ASSET_MANAGER_STORAGE_LOCATION
        }
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    /*=========================== Initialization =========================*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _USDC, address _treasury) {
        USDC = _USDC;
        treasury = _treasury;

        _disableInitializers();
    }

    /// @notice Initialize the asset manager
    /// @param _admin The address of the admin
    function initialize(address _admin, address _governance) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governance);
    }

    /*=========================== Public Functions =========================*/

    /// @notice Get the total weight of the asset manager
    /// @return The total weight of the asset manager
    function getTotalWeight() external view returns (uint256) {
        AssetManagerStorage storage $ = _getStorage();
        return $.totalWeight;
    }

    /// @notice Get the weight of an account
    /// @param account The account to get the weight of
    /// @return The weight of the account
    function getWeight(address account) external view returns (uint256) {
        AssetManagerStorage storage $ = _getStorage();
        (bool exists, uint256 weight) = $.weights.tryGet(account);
        if (!exists) {
            return 0;
        }
        return weight;
    }

    /// @notice Get the weights of all accounts
    /// @return The weights of all accounts
    function getWeights() external view returns (address[] memory, uint256[] memory) {
        AssetManagerStorage storage $ = _getStorage();
        address[] memory accounts = $.weights.keys();
        uint256[] memory weights = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            (bool exists, uint256 weight) = $.weights.tryGet(accounts[i]);
            if (!exists) {
                weight = 0;
            }
            weights[i] = weight;
        }
        return (accounts, weights);
    }

    /// @notice Deposit USDC to the asset manager
    /// @param _usdcAmount The amount of USDC to deposit
    function deposit(uint256 _usdcAmount) external onlyTreasury {
        IERC20(USDC).safeTransferFrom(treasury, address(this), _usdcAmount);
        uint256 balance = IERC20(USDC).balanceOf(address(this));

        // distribute USDC to accounts based on their weights
        AssetManagerStorage storage $ = _getStorage();
        uint256 totalWeight = $.totalWeight;
        for (uint256 i = 0; i < $.weights.length(); i++) {
            (address account, uint256 weight) = $.weights.at(i);
            uint256 amount = (balance * weight) / totalWeight;
            IERC20(USDC).safeTransfer(account, amount);

            emit USDCDistributed(account, amount);
        }
    }

    /// @notice Withdraw USDC from the asset manager
    /// @param _usdcAmount The amount of USDC to withdraw
    function withdraw(uint256 _usdcAmount) external onlyTreasury {
        IERC20(USDC).safeTransfer(treasury, _usdcAmount);
    }

    /*=========================== Governance Functions =========================*/

    /// @notice Update the weight of an account
    /// @param account The account to update the weight of
    /// @param newWeight The new weight of the account
    function updateWeight(
        address account,
        uint256 newWeight
    ) external onlyRole(GOVERNANCE_ROLE) {
        AssetManagerStorage storage $ = _getStorage();
        (bool exists, uint256 oldWeight) = $.weights.tryGet(account);
        if (!exists) {
            oldWeight = 0;
        }
        if (newWeight == 0) {
            $.weights.remove(account);
        } else {
            $.weights.set(account, newWeight);
        }
        $.totalWeight = $.totalWeight - oldWeight + newWeight;

        emit WeightUpdated(account, oldWeight, newWeight);
    }

    /*=========================== UUPS Functions =========================*/

    /// @notice Authorize upgrade to new implementation
    /// @param newImplementation Address of new implementation
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(GOVERNANCE_ROLE) {}
}
