// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

    // ERC7201

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
        if (msg.sender != governanceWarchest) revert NotGovernance();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != address(treasury)) revert NotTreasury();
        _;
    }

    /*=========================== State Variables =========================*/

    IERC20 public USDC;
    ITreasury public treasury;
    bool public withdrawalsFrozen;
    address public governanceWarchest;
    address public admin;
    uint256 public totalOutstandingWithdrawalAmount;
    uint256 public usxPrice;
    mapping(address => bool) public whitelistedUsers;
    mapping(address => uint256) public outstandingWithdrawalRequests;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*=========================== Initialization =========================*/

    function initialize(
        address _USDC,
        address _treasury,
        address _governanceWarchest,
        address _admin
    ) public initializer {
        if (_USDC == address(0) ||
            _governanceWarchest == address(0) ||
            _admin == address(0)
        ) revert ZeroAddress();
        
        // Initialize ERC20
        __ERC20_init("USX Token", "USX");
        
        USDC = IERC20(_USDC);
        treasury = ITreasury(_treasury);
        governanceWarchest = _governanceWarchest;
        admin = _admin;
    }

    /**
     * @dev Set the initial Treasury address - can only be called once when treasury is address(0)
     * @param _treasury Address of the Treasury contract
     */
    function setInitialTreasury(address _treasury) external onlyGovernance {
        if (_treasury == address(0)) revert ZeroAddress();
        if (treasury != ITreasury(address(0))) revert TreasuryAlreadySet();
        
        treasury = ITreasury(_treasury);
        emit TreasurySet(_treasury);
    }

    /*=========================== Public Functions =========================*/

    /// @notice Deposit USDC to get USX
    /// @param _amount The amount of USDC to deposit
    function deposit(uint256 _amount) public {
        // Check if user is whitelisted
        if (!whitelistedUsers[msg.sender]) revert UserNotWhitelisted();
    
        // Check if there are any outstanding withdrawal requests needing USDC
        uint256 usdcRequired = usdcRequiredForWithdrawalRequests();

        // If there outstanding withdrawal requests greater than amount deposited, leave USDC on this contract to fulfill them
        if (usdcRequired > _amount) {
            bool success = USDC.transferFrom(msg.sender, address(this), _amount);
            if (!success) revert USDCTransferFailed();
        }
        
        // If it is less, leave USDC required on this contract and send remaining USDC to the Treasury contract
        else {
            bool success = USDC.transferFrom(msg.sender, address(treasury), usdcRequired - _amount);
            if (!success) revert USDCTransferFailed();
        }

        // User receives USX
        _mint(msg.sender, _amount);
    }

    /// @notice Redeem USX to get USDC (begin withdrawal request)
    /// @param _USXredeemed The amount of USX to redeem
    function requestUSDC(uint256 _USXredeemed) public {
        // Check if withdrawals are frozen
        if (withdrawalsFrozen) revert WithdrawalsFrozen();

        // Check the USX price to determine how much USDC the user will receive
        uint256 usdcAmount = _USXredeemed * usxPrice;

        // Burn the USX
        _burn(msg.sender, _USXredeemed);

        // Record the outstanding withdrawal request
        totalOutstandingWithdrawalAmount += usdcAmount;
        outstandingWithdrawalRequests[msg.sender] += usdcAmount;

        // TODO: Consider automatically sending USDC to user if available

    }

    // TODO: Consider allowing partial claims as well
    /// @notice Claim USDC (fulfill withdrawal request)
    function claimUSDC() public {
        // Check if user has outstanding withdrawal requests
        if (outstandingWithdrawalRequests[msg.sender] == 0) revert NoOutstandingWithdrawalRequests();

        // Check if the treasury has enough USDC to fulfill the request
        if (USDC.balanceOf(address(this)) < outstandingWithdrawalRequests[msg.sender]) revert InsufficientUSDC();

        // Fulfill the withdrawal request
        uint256 usdcAmount = outstandingWithdrawalRequests[msg.sender];
        outstandingWithdrawalRequests[msg.sender] = 0;
        totalOutstandingWithdrawalAmount -= usdcAmount;
        
        // Send the USDC to the user
        USDC.transfer(msg.sender, usdcAmount);
    }

    function usdcRequiredForWithdrawalRequests() public view returns (uint256) {
        return USDC.balanceOf(address(this)) - totalOutstandingWithdrawalAmount;
    }

    /*=========================== Governance Functions =========================*/

    function unfreezeWithdrawals() public onlyGovernance {
        withdrawalsFrozen = false;
    }

    /**
     * @dev Set new governance address
     * @param newGovernance Address of new governance
     */
    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        
        address oldGovernance = governanceWarchest;
        governanceWarchest = newGovernance;
        
        emit GovernanceTransferred(oldGovernance, newGovernance);
    }

    /*=========================== Admin Functions =========================*/

    /// @notice Whitelist a user to mint/redeem USX
    /// @param _user The address to whitelist
    /// @param _isWhitelisted Whether to whitelist the user
    function whitelistUser(address _user, bool _isWhitelisted) public onlyAdmin {
        if (_user == address(0)) revert ZeroAddress();
        whitelistedUsers[_user] = _isWhitelisted;
    }

    /*=========================== Treasury Functions =========================*/

    function mintUSX(address _to, uint256 _amount) public onlyTreasury {
        _mint(_to, _amount);
    }

    function burnUSX(address _from, uint256 _amount) public onlyTreasury {
        _burn(_from, _amount);
    }

    function updatePeg(uint256 newPeg) public onlyTreasury {
        usxPrice = newPeg;
    }

    function freezeWithdrawals() public onlyTreasury {
        withdrawalsFrozen = true;
    }

    /*=========================== Internal Functions =========================*/

    /*=========================== UUPS Functions =========================*/

    /**
     * @dev Authorize upgrade to new implementation
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}
}