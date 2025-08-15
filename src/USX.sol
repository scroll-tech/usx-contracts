// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

    // Upgradeable smart contract UUPS
    // ERC7201
    // ReentrancyGuard

contract USX is ERC20 {

    /*=========================== Errors =========================*/

    error ZeroAddress();
    error NotGovernance();
    error NotAdmin();
    error NotTreasury();
    error UserNotWhitelisted();
    error WithdrawalsFrozen();
    error NoOutstandingWithdrawalRequests();
    error InsufficientUSDC();

    /*=========================== Events =========================*/

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

    IERC20 public immutable USDC;

    ITreasury public treasury;

    bool public withdrawalsFrozen;

    address public governanceWarchest;

    address public admin;

    uint256 public totalOutstandingWithdrawalAmount;

    uint256 public usdxPrice;

    mapping(address => bool) public whitelistedUsers;

    mapping(address => uint256) public outstandingWithdrawalRequests;

    /*=========================== Constructor =========================*/

    constructor(
        address _USDC,
        address _treasury,
        address _governanceWarchest,
        address _admin
    ) ERC20("USX Token", "USX") {
        if (_USDC == address(0) ||
            _treasury == address(0) ||
            _governanceWarchest == address(0) ||
            _admin == address(0)
            ) revert ZeroAddress();
        
        USDC = IERC20(_USDC);
        treasury = ITreasury(_treasury);
        governanceWarchest = _governanceWarchest;
        admin = _admin;
    }

    /*=========================== Public Functions =========================*/

    /// @notice Deposit USDC to get USX
    /// @param _amount The amount of USDC to deposit
    function deposit(uint256 _amount) public {
        // Check if user is whitelisted
        if (!whitelistedUsers[msg.sender]) revert UserNotWhitelisted();
    
        // Check if there are any outstanding withdrawal requests needing USDC
        uint256 usdcRequiredForWithdrawalRequests = usdcRequiredForWithdrawalRequests();

        // If there outstanding withdrawal requests greater than amount deposited, leave USDC on this contract to fulfill them
        if (usdcRequiredForWithdrawalRequests > _amount) {
            USDC.transferFrom(msg.sender, address(this), _amount);
        }
        
        // If it is less, leave USDC required on this contract and send remaining USDC to the Treasury contract
        else {
            USDC.transferFrom(msg.sender, address(treasury), usdcRequiredForWithdrawalRequests - _amount);
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
        uint256 usdcAmount = _USXredeemed * usxPrice();

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
        usdxPrice = newPeg;
    }

    function freezeWithdrawals() public onlyTreasury {
        withdrawalsFrozen = true;
    }

    /*=========================== Internal Functions =========================*/

}