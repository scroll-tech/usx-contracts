// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// Upgradeable smart contract UUPS
// ERC7201

contract sUSX is ERC4626Upgradeable, UUPSUpgradeable {

    /*=========================== Errors =========================*/

    error ZeroAddress();
    error NotGovernance();
    error NotTreasury();
    error InsufficientBalance();
    error WithdrawalAlreadyClaimed();
    error WithdrawalPeriodNotPassed();
    error NextEpochNotStarted();
    error InvalidMinWithdrawalPeriod();
    error MaxLeverageExceeded();

    /*=========================== Events =========================*/

    /*=========================== Modifiers =========================*/

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != address(treasury)) revert NotTreasury();
        _;
    }

    /*=========================== State Variables =========================*/

    struct WithdrawalRequest {
        address user;                   // Address of withdrawer
        uint256 amount;                 // sUSX amount redeemed
        uint256 withdrawalTimestamp;    // Timestamp of the withdrawal request
        bool claimed;                   // True = withdrawal request has been claimed
    }

    // USX token reference (the underlying asset)
    IERC20 public USX;

    // treasury contract
    ITreasury public treasury;

    // address that controls governance of the contract
    address public governance;

    // withdrawal period in blocks, (default == 108000 (15 days))
    uint256 public withdrawalPeriod;
    
    // fraction of withdrawals determining the withdrawal fee, (default 0.5% == 500) with precision to 0.001 percent
    uint256 public withdrawalFeeFraction;

    // withdrawal period in blocks, (default == 108000 (15 days))
    uint256 public minWithdrawalPeriod;

    // timestamp of the last epoch
    uint256 public lastEpochTime;

    uint256 public withdrawalIdCounter;

    //  duration of epoch in blocks, (default == 216000 (30days))
    uint256 public epochDuration;

    // profits reported for previous period TODO: is this needed?
    uint256 public netEpochProfits;

    // current profit added at current epoch TODO: is this needed?
    uint256 public profitLatestEpoch;

    // determines increase in profits for each block
    uint256 public profitsPerBlock;

    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;
    // TODO: Make a nested mapping with user address and withdrawalId? stores withdrawals per user instead of global

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*=========================== Initialization =========================*/

    function initialize(
        address _usx,
        address _treasury,
        address _governance
    ) public initializer {
        if (_usx == address(0) ||
            _treasury == address(0) ||
            _governance == address(0)
        ) revert ZeroAddress();
        
        // Initialize ERC4626 and ERC20
        __ERC4626_init(IERC20(_usx));
        __ERC20_init("sUSX Token", "sUSX");
        
        USX = IERC20(_usx);
        treasury = ITreasury(_treasury);
        governance = _governance;
        
        // Set default values
        withdrawalPeriod = 108000;      // 15 days (assuming 12 second block time)
        withdrawalFeeFraction = 500;    // 0.5%
        minWithdrawalPeriod = 108000;   // 15 days
        epochDuration = 216000;         // 30 days
    }

    /*=========================== Public Functions =========================*/

    // TODO: Override base ERC4626 deposit/withdraw functions

    // instantly mints sUSX at sharePrice
    function deposit(uint256 USX_amount) public {
        // Check if the user has enough USX
        if (USX.balanceOf(msg.sender) < USX_amount) revert InsufficientBalance();

        // Check if the deposit would exceed the max leverage
        if (treasury.checkMaxLeverage(USX_amount)) revert MaxLeverageExceeded();

        // Get the amount of sUSX to mint given current sharePrice
        uint256 sUSX_amount = USX_amount * 1e18 / sharePrice();

        // Mint sUSX
        _mint(msg.sender, sUSX_amount);
    }

    // user must wait for withdrawalPeriod to pass before unstaking (withdrawalPeriod)
    function requestWithdraw(uint256 sUSX_amount) public {
        // Check if user has enough sUSX
        if (balanceOf(msg.sender) < sUSX_amount) revert InsufficientBalance();

        // Burn sUSX
        _burn(msg.sender, sUSX_amount);

        // Record withdrawal request
        withdrawalRequests[withdrawalIdCounter] = WithdrawalRequest({
            user: msg.sender,
            amount: sUSX_amount,
            withdrawalTimestamp: block.timestamp,
            claimed: false
        });

        // Increment withdrawalIdCounter
        withdrawalIdCounter++;
    }

    // after withdrawalPeriod AND epoch the user made withdrawal on is finished, after Gross Profits has been counted
    // portion is sent to the Governance Warchest (withdrawalFee applied here)
    function claimWithdraw(uint256 withdrawalId) public {
        // Check if the withdrawal request is unclaimed
        if (withdrawalRequests[withdrawalId].claimed) revert WithdrawalAlreadyClaimed();

        // Check if the withdrawal period has passed
        if (withdrawalRequests[withdrawalId].withdrawalTimestamp + withdrawalPeriod > block.timestamp) revert WithdrawalPeriodNotPassed();

        // Check if the next epoch has started since the withdrawal request was made
        if (withdrawalRequests[withdrawalId].withdrawalTimestamp > lastEpochTime) revert NextEpochNotStarted();

        // Get the total USX amount for the amount of sUSX being redeemed
        uint256 USXAmount = withdrawalRequests[withdrawalId].amount * sharePrice() / 1e18; // TODO: verify share price applied correctly

        // Distribute portion of USX to the Governance Warchest
        uint256 governanceWarchestPortion = withdrawalFee(USXAmount);
        USX.transferFrom(address(this), treasury.governanceWarchest(), governanceWarchestPortion);

        // Send the remaining USX to the user
        uint256 userPortion = USXAmount - governanceWarchestPortion;
        USX.transferFrom(address(this), withdrawalRequests[withdrawalId].user, userPortion);

        // Mark the withdrawal as claimed
        withdrawalRequests[withdrawalId].claimed = true;
    }

    // calculated using on chain USX balance and linear profit accrual (USX.balanceOf(this) + linear scaled profits from last epoch)
    function sharePrice() public view returns (uint256) {
        uint256 base    = USX.balanceOf(address(this));
        uint256 rewards = profitLatestEpoch; // TODO: Implement logic for this variable
        uint256 totalUSX = base + rewards;
        return totalUSX * 1e18 / this.totalSupply();
    }

    // withdrawal fee taken on all withdrawals that goes to the Governance Warchest
    function withdrawalFee(uint256 withdrawalAmount) public view returns (uint256) {
        return withdrawalAmount * withdrawalFeeFraction / 100000;
    }

    /*=========================== Governance Functions =========================*/

    // sets withdrawal period in blocks
    function setMinWithdrawalPeriod(uint256 _minWithdrawalPeriod) public onlyGovernance {
        if (_minWithdrawalPeriod < 108000) revert InvalidMinWithdrawalPeriod();
        minWithdrawalPeriod = _minWithdrawalPeriod;
    }

    // sets withdrawal fee with precision to 0.001 percent // TODO: Is it ok to have no min/max?
    function setWithdrawalFeeFraction(uint256 _withdrawalFeeFraction) public onlyGovernance {
        withdrawalFeeFraction = _withdrawalFeeFraction;
    }

    // duration of epoch in blocks
    function setEpochDuration(uint256 _epochDurationBlocks) public onlyGovernance {
        epochDuration = _epochDurationBlocks;
    }

    /*=========================== Treasury Functions =========================*/

    // USX profits are minted over a linear period till the next epoch
    function distributeProfits(uint256 amountProfit) public onlyTreasury {
        // Get the next epoch time
        uint256 nextEpochTime = lastEpochTime + epochDuration;

        // Calculate the amount of profits to be distributed each block until the next epoch
        profitsPerBlock = amountProfit / (nextEpochTime - block.timestamp);
    }

    /*=========================== Internal Functions =========================*/

    // linear increase in profits each block
    function _updateLastEpochTime() internal {} // TODO: Call this inside a modifier applied on all relevant user functions so it automatically updates?

    function _applyLatestProfits() internal {}
    // TODO: Call this inside a modifier applied on all relevant user functions so it automatically updates?
    // logic could be covered by sharePrice() calls?
    // Consider merge with _updateLastEpochTime in general updateFunction?
    // Consider function that allows the update to be applied manually at any point?
    // Keep in mind profits should only be distributed until next epoch. After that, no new profit accrual until Asset Manager has made new profitable report.

    /*=========================== UUPS Functions =========================*/

    /**
     * @dev Authorize upgrade to new implementation
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}
}