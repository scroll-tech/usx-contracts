// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract USX is ERC20Upgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /*=========================== Errors =========================*/

    error ZeroAddress();
    error NotGovernance();
    error NotAdmin();
    error NotTreasury();
    error UserNotWhitelisted();
    error WithdrawalsFrozen();
    error Frozen();
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
    event PegUpdated(uint256 oldPeg, uint256 newPeg);
    event FrozenChanged(bool frozen);
    event WhitelistUpdated(address indexed user, bool whitelisted);

    /*=========================== Constants =========================*/

    uint256 private constant USDC_SCALAR = 1e12;

    /*=========================== Modifiers =========================*/

    modifier onlyWhitelisted() {
        if (!_getStorage().whitelistedUsers[msg.sender]) revert UserNotWhitelisted();
        _;
    }

    modifier whenNotFrozen() {
        if (_getStorage().frozen) revert Frozen();
        _;
    }

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
        bool frozen;
        address governanceWarchest;
        address admin;
        uint256 totalOutstandingWithdrawalAmount;
        uint256 totalMatchedWithdrawalAmount;
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

        // Initialize ERC20 and ReentrancyGuard
        __ERC20_init("USX", "USX");
        __ReentrancyGuard_init();

        USXStorage storage $ = _getStorage();
        $.USDC = IERC20(_USDC);
        $.treasury = ITreasury(_treasury);
        $.governanceWarchest = _governanceWarchest;
        $.admin = _admin;
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
    function deposit(uint256 _amount) public nonReentrant onlyWhitelisted whenNotFrozen {
        USXStorage storage $ = _getStorage();

        // Check if the USDC amount is valid
        if (_amount == 0) revert InvalidUSDCDepositAmount();

        // Update the total matched withdrawal amount based on the latest usdc balance
        _updateTotalMatchedWithdrawalAmount();

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
    function requestUSDC(uint256 _USXredeemed) public nonReentrant onlyWhitelisted whenNotFrozen {
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
        _updateTotalMatchedWithdrawalAmount();
    
        // Check if contract has enough USDC to fulfill the request immediately
        uint256 availableUSDCForImmedateTransfer = $.USDC.balanceOf(address(this)) - $.totalMatchedWithdrawalAmount;

        if (availableUSDCForImmedateTransfer >= usdcAmount) {
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

        // Check if user has outstanding withdrawal requests
        if ($.outstandingWithdrawalRequests[msg.sender] == 0) revert NoOutstandingWithdrawalRequests();

        // Update the total matched withdrawal amount based on the latest usdc balance
        _updateTotalMatchedWithdrawalAmount();

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

    /// @notice Unfreeze deposits and withdrawals, allowing users to deposit and withdraw again
    function unfreeze() public onlyGovernance {
        USXStorage storage $ = _getStorage();
        $.frozen = false;
        emit FrozenChanged(false);
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

    /// @notice Freeze deposits and withdrawals, preventing users from depositing and redeeming USX
    /// @dev Used by Treasury to freeze operations when peg is broken
    function freeze() public onlyTreasury {
        USXStorage storage $ = _getStorage();
        $.frozen = true;
        emit FrozenChanged(true);
    }

    /*=========================== Internal Functions =========================*/

    /// @notice Update the total matched withdrawal amount based on the latest USDC balance
    /// @dev This is because someone may transfer more USDC to the contract than requested by users
    function _updateTotalMatchedWithdrawalAmount() internal {
        USXStorage storage $ = _getStorage();

        uint256 usdcBalance = $.USDC.balanceOf(address(this));
        if (usdcBalance > $.totalMatchedWithdrawalAmount) {
            if (usdcBalance < $.totalOutstandingWithdrawalAmount) {
                $.totalMatchedWithdrawalAmount = usdcBalance;
            } else {
                $.totalMatchedWithdrawalAmount = $.totalOutstandingWithdrawalAmount;
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

    function frozen() public view returns (bool) {
        return _getStorage().frozen;
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

    function whitelistedUsers(address user) public view returns (bool) {
        return _getStorage().whitelistedUsers[user];
    }

    function outstandingWithdrawalRequests(address user) public view returns (uint256) {
        return _getStorage().outstandingWithdrawalRequests[user];
    }
}
