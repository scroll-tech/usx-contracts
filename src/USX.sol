// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract USX is ERC20Upgradeable, UUPSUpgradeable {
    /*=========================== Errors =========================*/

    error ZeroAddress();
    error NotGovernance();
    error NotAdmin();
    error NotTreasury();
    error UserNotWhitelisted();
    error WithdrawalsFrozen();
    error NoOutstandingWithdrawalRequests();
    error InsufficientUSDC();
    error TreasuryAlreadySet();
    error USDCTransferFailed();

    /*=========================== Events =========================*/

    event TreasurySet(address indexed treasury);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);

    /*=========================== Modifiers =========================*/

    modifier onlyGovernance() {
        if (msg.sender != _getStorage().governanceWarchest) revert NotGovernance();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != _getStorage().admin) revert NotAdmin();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != address(_getStorage().treasury)) revert NotTreasury();
        _;
    }

    /*=========================== Storage =========================*/

    /// @custom:storage-location erc7201:usx.main
    struct USXStorage {
        IERC20 USDC;
        ITreasury treasury;
        bool withdrawalsFrozen;
        address governanceWarchest;
        address admin;
        uint256 totalOutstandingWithdrawalAmount;
        uint256 usxPrice;
        mapping(address => bool) whitelistedUsers;
        mapping(address => uint256) outstandingWithdrawalRequests;
    }

    // keccak256(abi.encode(uint256(keccak256("usx.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant USX_STORAGE_LOCATION = 0x0c53c51c00000000000000000000000000000000000000000000000000000000;

    function _getStorage() private pure returns (USXStorage storage $) {
        assembly {
            $.slot := USX_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*=========================== Initialization =========================*/

    function initialize(address _USDC, address _treasury, address _governanceWarchest, address _admin)
        public
        initializer
    {
        if (_USDC == address(0) || _governanceWarchest == address(0) || _admin == address(0)) revert ZeroAddress();

        // Initialize ERC20
        __ERC20_init("USX Token", "USX");

        USXStorage storage $ = _getStorage();
        $.USDC = IERC20(_USDC);
        $.treasury = ITreasury(_treasury);
        $.governanceWarchest = _governanceWarchest;
        $.admin = _admin;
        $.usxPrice = 1e18;
    }

    /// @dev Set the initial Treasury address - can only be called once when treasury is address(0)
    /// @param _treasury Address of the Treasury contract
    function setInitialTreasury(address _treasury) external onlyGovernance {
        if (_treasury == address(0)) revert ZeroAddress();
        USXStorage storage $ = _getStorage();
        if ($.treasury != ITreasury(address(0))) revert TreasuryAlreadySet();

        $.treasury = ITreasury(_treasury);
        emit TreasurySet(_treasury);
    }

    /*=========================== Public Functions =========================*/

    /// @notice Deposit USDC to get USX
    /// @param _amount The amount of USDC to deposit
    function deposit(uint256 _amount) public {
        USXStorage storage $ = _getStorage();

        // Check if user is whitelisted
        if (!$.whitelistedUsers[msg.sender]) revert UserNotWhitelisted();

        // Calculate USDC distribution: keep what's needed for withdrawal requests, send excess to treasury
        uint256 usdcForContract =
            _amount <= $.totalOutstandingWithdrawalAmount ? _amount : $.totalOutstandingWithdrawalAmount;
        uint256 usdcForTreasury = _amount - usdcForContract;

        // Transfer USDC to contract (if needed for withdrawal requests)
        if (usdcForContract > 0) {
            bool success = $.USDC.transferFrom(msg.sender, address(this), usdcForContract);
            if (!success) revert USDCTransferFailed();
        }

        // Transfer excess USDC to treasury
        if (usdcForTreasury > 0) {
            bool success = $.USDC.transferFrom(msg.sender, address($.treasury), usdcForTreasury);
            if (!success) revert USDCTransferFailed();
        }

        // User receives USX
        _mint(msg.sender, _amount * 1e12); // Scale USDC (6 decimals) to USX (18 decimals)
    }

    /// @notice Redeem USX to get USDC (begin withdrawal request)
    /// @param _USXredeemed The amount of USX to redeem
    function requestUSDC(uint256 _USXredeemed) public {
        USXStorage storage $ = _getStorage();

        // Check if withdrawals are frozen
        if ($.withdrawalsFrozen) revert WithdrawalsFrozen();

        // Check the USX price to determine how much USDC the user will receive
        // For 1:1 exchange rate: 1 USX = 1 USDC
        // Since USX has 18 decimals and USDC has 6 decimals,
        // we need to scale down by 10^12 to convert from USX to USDC
        uint256 usdcAmount = _USXredeemed / 1e12;

        // Burn the USX
        _burn(msg.sender, _USXredeemed);

        // Record the outstanding withdrawal request
        $.totalOutstandingWithdrawalAmount += usdcAmount;
        $.outstandingWithdrawalRequests[msg.sender] += usdcAmount;

        // TODO: Consider automatically sending USDC to user if available
    }

    // TODO: Consider allowing partial claims as well
    /// @notice Claim USDC (fulfill withdrawal request)
    function claimUSDC() public {
        USXStorage storage $ = _getStorage();

        // Check if user has outstanding withdrawal requests
        if ($.outstandingWithdrawalRequests[msg.sender] == 0) revert NoOutstandingWithdrawalRequests();

        // Check if the treasury has enough USDC to fulfill the request
        if ($.USDC.balanceOf(address(this)) < $.outstandingWithdrawalRequests[msg.sender]) revert InsufficientUSDC();

        // Fulfill the withdrawal request
        uint256 usdcAmount = $.outstandingWithdrawalRequests[msg.sender];
        $.outstandingWithdrawalRequests[msg.sender] = 0;
        $.totalOutstandingWithdrawalAmount -= usdcAmount;

        // Send the USDC to the user
        $.USDC.transfer(msg.sender, usdcAmount);
    }

    /*=========================== Governance Functions =========================*/

    /// @notice Unfreeze withdrawals, allowing users to withdraw again
    function unfreezeWithdrawals() public onlyGovernance {
        USXStorage storage $ = _getStorage();
        $.withdrawalsFrozen = false;
    }

    /// @notice Set new governance address
    /// @param newGovernance Address of new governance
    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();

        USXStorage storage $ = _getStorage();
        address oldGovernance = $.governanceWarchest;
        $.governanceWarchest = newGovernance;

        emit GovernanceTransferred(oldGovernance, newGovernance);
    }

    /*=========================== Admin Functions =========================*/

    /// @notice Whitelist a user to mint/redeem USX
    /// @param _user The address to whitelist
    /// @param _isWhitelisted Whether to whitelist the user
    function whitelistUser(address _user, bool _isWhitelisted) public onlyAdmin {
        if (_user == address(0)) revert ZeroAddress();
        USXStorage storage $ = _getStorage();
        $.whitelistedUsers[_user] = _isWhitelisted;
    }

    /*=========================== Treasury Functions =========================*/

    /// @notice Mint USX to an address
    /// @param _to The address to mint USX to
    /// @param _amount The amount of USX to mint
    /// @dev Used by Treasury to mint profits from profitable Asset Manager reports
    function mintUSX(address _to, uint256 _amount) public onlyTreasury {
        _mint(_to, _amount);
    }

    /// @notice Burn USX from an address
    /// @param _from The address to burn USX from
    /// @param _amount The amount of USX to burn
    /// @dev Used by Treasury to burn USX when losses are reported by Asset Manager
    function burnUSX(address _from, uint256 _amount) public onlyTreasury {
        _burn(_from, _amount);
    }

    /// @notice Update the USX:USDC price
    /// @param newPeg The new USX:USDC price
    /// @dev Used by Treasury to update the USX:USDC price
    function updatePeg(uint256 newPeg) public onlyTreasury {
        USXStorage storage $ = _getStorage();
        $.usxPrice = newPeg;
    }

    /// @notice Freeze withdrawals, preventing users from redeeming USX
    /// @dev Used by Treasury to freeze withdrawals when peg is broken
    function freezeWithdrawals() public onlyTreasury {
        USXStorage storage $ = _getStorage();
        $.withdrawalsFrozen = true;
    }

    /*=========================== UUPS Functions =========================*/

    /// @notice Authorize upgrade to new implementation
    /// @param newImplementation Address of new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}

    /*=========================== View Functions =========================*/

    function USDC() public view returns (IERC20) {
        return _getStorage().USDC;
    }

    function treasury() public view returns (ITreasury) {
        return _getStorage().treasury;
    }

    function withdrawalsFrozen() public view returns (bool) {
        return _getStorage().withdrawalsFrozen;
    }

    function governanceWarchest() public view returns (address) {
        return _getStorage().governanceWarchest;
    }

    function admin() public view returns (address) {
        return _getStorage().admin;
    }

    function totalOutstandingWithdrawalAmount() public view returns (uint256) {
        return _getStorage().totalOutstandingWithdrawalAmount;
    }

    function usxPrice() public view returns (uint256) {
        return _getStorage().usxPrice;
    }

    function whitelistedUsers(address user) public view returns (bool) {
        return _getStorage().whitelistedUsers[user];
    }

    function outstandingWithdrawalRequests(address user) public view returns (uint256) {
        return _getStorage().outstandingWithdrawalRequests[user];
    }
}
