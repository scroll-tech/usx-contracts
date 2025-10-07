// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUSX} from "./interfaces/IUSX.sol";

contract USX is ERC20Upgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IUSX {
    using SafeERC20 for IERC20;

    /*=========================== Errors =========================*/

    error ZeroAddress();
    error NotGovernance();
    error NotAdmin();
    error NotTreasury();
    error UserNotWhitelisted();
    error Paused();
    error NoOutstandingWithdrawalRequests();
    error InsufficientUSDC();
    error TreasuryAlreadySet();
    error InvalidUSDCDepositAmount();
    error InvalidUSXRedeemAmount();

    /*=========================== Events =========================*/

    event TreasurySet(address indexed treasury);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event Deposit(address indexed user, uint256 usdcAmount, uint256 usxMinted);
    event Redeem(address indexed user, uint256 usxAmount, uint256 usdcAmount);
    event Claim(address indexed user, uint256 amount);
    event PausedChanged(bool paused);
    event WhitelistUpdated(address indexed user, bool whitelisted);

    /*=========================== Constants =========================*/

    /// @dev Scalar to scale USDC to 18 decimals
    uint256 private constant USDC_SCALAR = 1e12;

    /*=========================== Modifiers =========================*/

    modifier onlyWhitelisted() {
        if (!_getStorage().whitelistedUsers[msg.sender]) revert UserNotWhitelisted();
        _;
    }

    modifier notPaused() {
        if (_getStorage().paused) revert Paused();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != _getStorage().governance) revert NotGovernance();
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
        bool paused;
        address governance;
        address admin;
        uint256 totalOutstandingWithdrawalAmount;
        uint256 totalMatchedWithdrawalAmount;
        mapping(address => bool) whitelistedUsers;
        mapping(address => uint256) outstandingWithdrawalRequests;
    }

    // keccak256(abi.encode(uint256(keccak256("usx.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant USX_STORAGE_LOCATION = 0xc9db443a76878c18b8727ca7977c3e648e5a60974201d1ee927d7e63744b5500;

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

    function initialize(address _USDC, address _treasury, address _governance, address _admin)
        public
        initializer
    {
        if (_USDC == address(0) || _governance == address(0) || _admin == address(0)) revert ZeroAddress();

        // Initialize ERC20 and ReentrancyGuard
        __ERC20_init("USX", "USX");
        __ReentrancyGuard_init();

        USXStorage storage $ = _getStorage();
        $.USDC = IERC20(_USDC);
        $.treasury = ITreasury(_treasury);
        $.governance = _governance;
        $.admin = _admin;
    }

    /// @dev Set the initial Treasury address - can only be called once when treasury is address(0)
    /// @param _treasury Address of the Treasury contract
    function initializeTreasury(address _treasury) external onlyGovernance {
        if (_treasury == address(0)) revert ZeroAddress();
        USXStorage storage $ = _getStorage();
        if ($.treasury != ITreasury(address(0))) revert TreasuryAlreadySet();

        $.treasury = ITreasury(_treasury);
        emit TreasurySet(_treasury);
    }

    /*=========================== Public Functions =========================*/

    /// @notice Deposit USDC to get USX
    /// @param _amount The amount of USDC to deposit
    function deposit(uint256 _amount) public nonReentrant onlyWhitelisted notPaused {
        USXStorage storage $ = _getStorage();

        // Check if the USDC amount is valid
        if (_amount == 0) revert InvalidUSDCDepositAmount();

        // Update the total matched withdrawal amount based on the latest usdc balance
        _updateTotalMatchedWithdrawalAmount(true);

        // Calculate USDC distribution: keep what's needed for withdrawal requests, send excess to treasury
        uint256 usdcShortfall = $.totalOutstandingWithdrawalAmount - $.totalMatchedWithdrawalAmount;
        uint256 usdcForContract = Math.min(_amount, usdcShortfall);
        uint256 usdcForTreasury = _amount - usdcForContract;
        $.totalMatchedWithdrawalAmount += usdcForContract;

        // Transfer USDC to contract (if needed for withdrawal requests)
        if (usdcForContract > 0) {
            $.USDC.safeTransferFrom(msg.sender, address(this), usdcForContract);
        }

        // Transfer excess USDC to treasury
        if (usdcForTreasury > 0) {
            $.USDC.safeTransferFrom(msg.sender, address($.treasury), usdcForTreasury);
        }

        // User receives USX
        uint256 usxMinted = _amount * USDC_SCALAR;
        _mint(msg.sender, usxMinted);

        emit Deposit(msg.sender, _amount, usxMinted);
    }

    /// @notice Redeem USX to get USDC (automatically send if available, otherwise create withdrawal request)
    /// @param _USXredeemed The amount of USX to redeem
    function requestUSDC(uint256 _USXredeemed) public nonReentrant onlyWhitelisted notPaused {
        USXStorage storage $ = _getStorage();

        // Check if the USX amount is a multiple of USDC_SCALAR
        // We shall keep the total supple of USX as a multiple of USDC_SCALAR, in case somewhere is
        // using USDC reserve and total supply to calculate the peg. This will always make the peg 1:1.
        // Otherwise, 1 USX will a bit more than 1 USDC when someone redeemed non-multiple amount of USX.
        if (_USXredeemed == 0 || _USXredeemed % USDC_SCALAR != 0) revert InvalidUSXRedeemAmount();

        // Check the USX price to determine how much USDC the user will receive
        // Since USX has 18 decimals and USDC has 6 decimals,
        // we need to scale down by 10^12 to convert from USX to USDC
        uint256 usdcAmount = _USXredeemed / USDC_SCALAR;

        // Burn the USX
        _burn(msg.sender, _USXredeemed);

        // Update the total matched withdrawal amount based on the latest usdc balance
        _updateTotalMatchedWithdrawalAmount(false);

        // Check if contract has enough USDC to fulfill the request immediately
        uint256 availableUSDCForImmediateTransfer = $.USDC.balanceOf(address(this)) - $.totalMatchedWithdrawalAmount;

        if (availableUSDCForImmediateTransfer >= usdcAmount) {
            // Automatically send USDC to user if available
            $.USDC.safeTransfer(msg.sender, usdcAmount);
            emit Redeem(msg.sender, _USXredeemed, usdcAmount);
        } else {
            // Record the outstanding withdrawal request if insufficient USDC
            $.totalOutstandingWithdrawalAmount += usdcAmount;
            $.outstandingWithdrawalRequests[msg.sender] += usdcAmount;
            emit Redeem(msg.sender, _USXredeemed, usdcAmount);
        }
    }

    /// @notice Claim USDC (fulfill withdrawal request)
    /// @dev Allows partial claims if there is some USDC available for users total claim
    function claimUSDC() public nonReentrant {
        USXStorage storage $ = _getStorage();

        // @note It is possible that users with smaller withdrawal request amount can frontrun the
        // user with larger withdrawal request amount. But eventually, all users will be able to claim
        // their USDC.

        // Check if user has outstanding withdrawal requests
        if ($.outstandingWithdrawalRequests[msg.sender] == 0) revert NoOutstandingWithdrawalRequests();

        // Update the total matched withdrawal amount based on the latest usdc balance
        _updateTotalMatchedWithdrawalAmount(true);

        // Revert if contract has no USDC available
        uint256 usdcAvailableForClaim = $.totalMatchedWithdrawalAmount;
        if (usdcAvailableForClaim == 0) revert InsufficientUSDC();

        uint256 userRequestAmount = $.outstandingWithdrawalRequests[msg.sender];

        // Determine how much can be claimed (minimum of request amount and available balance)
        uint256 claimableAmount = Math.min(userRequestAmount, usdcAvailableForClaim);

        // Update user's outstanding request
        $.outstandingWithdrawalRequests[msg.sender] -= claimableAmount;
        $.totalOutstandingWithdrawalAmount -= claimableAmount;
        $.totalMatchedWithdrawalAmount -= claimableAmount;

        // Send the claimable USDC to the user
        $.USDC.safeTransfer(msg.sender, claimableAmount);

        emit Claim(msg.sender, claimableAmount);
    }

    /*=========================== Governance Functions =========================*/

    /// @notice Pause deposits and withdrawals, preventing users from depositing and redeeming USX
    function pause() public onlyGovernance {
        USXStorage storage $ = _getStorage();
        $.paused = true;
        emit PausedChanged(true);
    }

    /// @notice Unpause deposits and withdrawals, allowing users to deposit and withdraw again
    function unpause() public onlyGovernance {
        USXStorage storage $ = _getStorage();
        $.paused = false;
        emit PausedChanged(false);
    }

    /// @notice Set new governance address
    /// @param newGovernance Address of new governance
    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();

        USXStorage storage $ = _getStorage();
        address oldGovernance = $.governance;
        $.governance = newGovernance;

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
        emit WhitelistUpdated(_user, _isWhitelisted);
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

    /// @notice Update the total matched withdrawal amount based on the latest USDC balance
    /// @dev Used by Treasury to update the total matched withdrawal amount
    function updateTotalMatchedWithdrawalAmount() external onlyTreasury {
        _updateTotalMatchedWithdrawalAmount(true);
    }

    /*=========================== Internal Functions =========================*/

    /// @notice Update the total matched withdrawal amount based on the latest USDC balance
    /// @dev This is because someone may transfer USDC directly to this contract.
    function _updateTotalMatchedWithdrawalAmount(bool transferExcessToTreasury) internal {
        USXStorage storage $ = _getStorage();

        uint256 usdcBalance = $.USDC.balanceOf(address(this));
        if (usdcBalance > $.totalMatchedWithdrawalAmount) {
            if (usdcBalance <= $.totalOutstandingWithdrawalAmount) {
                $.totalMatchedWithdrawalAmount = usdcBalance;
            } else {
                $.totalMatchedWithdrawalAmount = $.totalOutstandingWithdrawalAmount;

                // Transfer the remaining USDC to the treasury
                if (transferExcessToTreasury) {
                    uint256 remainingUSDC = usdcBalance - $.totalOutstandingWithdrawalAmount;
                    $.USDC.safeTransfer(address($.treasury), remainingUSDC);
                }
            }
        }
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

    function paused() public view returns (bool) {
        return _getStorage().paused;
    }

    function governance() public view returns (address) {
        return _getStorage().governance;
    }

    function admin() public view returns (address) {
        return _getStorage().admin;
    }

    function totalOutstandingWithdrawalAmount() public view returns (uint256) {
        return _getStorage().totalOutstandingWithdrawalAmount;
    }

    function totalMatchedWithdrawalAmount() public view returns (uint256) {
        return _getStorage().totalMatchedWithdrawalAmount;
    }

    function whitelistedUsers(address user) public view returns (bool) {
        return _getStorage().whitelistedUsers[user];
    }

    function outstandingWithdrawalRequests(address user) public view returns (uint256) {
        return _getStorage().outstandingWithdrawalRequests[user];
    }
}
