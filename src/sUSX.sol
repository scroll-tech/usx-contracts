// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

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
    error TreasuryAlreadySet();
    error USXTransferFailed();

    /*=========================== Events =========================*/

    event TreasurySet(address indexed treasury);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);

    /*=========================== Modifiers =========================*/

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    /*=========================== State Variables =========================*/

    struct WithdrawalRequest {
        address user;                   // Address of withdrawer
        uint256 amount;                 // sUSX amount redeemed
        uint256 withdrawalBlock;        // Block number of the withdrawal request
        bool claimed;                   // True = withdrawal request has been claimed
    }

    IERC20 public USX; // USX token reference (the underlying asset)
    ITreasury public treasury;     // treasury contract
    address public governance;    // address that controls governance of the contract
    uint256 public withdrawalPeriod;    // withdrawal period in blocks, (default == 108000 (15 days))
    uint256 public withdrawalFeeFraction;    // fraction of withdrawals determining the withdrawal fee, (default 0.5% == 500) with precision to 0.001 percent
    uint256 public minWithdrawalPeriod;     // withdrawal period in blocks, (default == 108000 (15 days))
    uint256 public lastEpochBlock;     // block number of the last epoch
    uint256 public withdrawalIdCounter; 
    uint256 public epochDuration;     //  duration of epoch in blocks, (default == 216000 (30days))
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

    // after withdrawalPeriod AND epoch the user made withdrawal on is finished, after Gross Profits has been counted
    // portion is sent to the Governance Warchest (withdrawalFee applied here)
    function claimWithdraw(uint256 withdrawalId) public {
        // Check if the withdrawal request is unclaimed
        if (withdrawalRequests[withdrawalId].claimed) revert WithdrawalAlreadyClaimed();

        // Check if the withdrawal period has passed
        if (withdrawalRequests[withdrawalId].withdrawalBlock + withdrawalPeriod > block.number) revert WithdrawalPeriodNotPassed();

        // Check if the next epoch has started since the withdrawal request was made
        if (withdrawalRequests[withdrawalId].withdrawalBlock > lastEpochBlock) revert NextEpochNotStarted();

        // Get the total USX amount for the amount of sUSX being redeemed
        uint256 USXAmount = withdrawalRequests[withdrawalId].amount * sharePrice() / 1e18;

        // Distribute portion of USX to the Governance Warchest
        uint256 governanceWarchestPortion = withdrawalFee(USXAmount);
        bool success = USX.transferFrom(address(this), treasury.governanceWarchest(), governanceWarchestPortion);
        if (!success) revert USXTransferFailed();

        // Send the remaining USX to the user
        uint256 userPortion = USXAmount - governanceWarchestPortion;
        success = USX.transferFrom(address(this), withdrawalRequests[withdrawalId].user, userPortion);
        if (!success) revert USXTransferFailed();

        // Mark the withdrawal as claimed
        withdrawalRequests[withdrawalId].claimed = true;
    }

    // calculated using on chain USX balance and linear profit accrual (USX.balanceOf(this) + linear scaled profits from last epoch)
    function sharePrice() public view returns (uint256) {
        uint256 base    = USX.balanceOf(address(this));
        uint256 rewards = treasury.profitLatestEpoch();
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

    /**
     * @dev Set new governance address
     * @param newGovernance Address of new governance
     */
    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        
        address oldGovernance = governance;
        governance = newGovernance;
        
        emit GovernanceTransferred(oldGovernance, newGovernance);
    }

    /*=========================== Internal Functions =========================*/

    // user must wait for withdrawalPeriod to pass before unstaking (withdrawalPeriod)
    // "requestWithdraw" function
    // override default ERC4626 for the 2 step withdrawal process in protocol
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override returns (uint256) {
        // Check if user has enough sUSX shares
        if (balanceOf(owner) < shares) revert InsufficientBalance();

        // Burn sUSX shares
        _burn(owner, shares);

        // Record withdrawal request
        withdrawalRequests[withdrawalIdCounter] = WithdrawalRequest({
            user: receiver,
            amount: assets,
            withdrawalBlock: block.number,
            claimed: false
        });

        // Increment withdrawalIdCounter
        withdrawalIdCounter++;

        // Return the shares that were burned
        return shares;
    }

    // override default ERC4626 to use sharePrice
    function _convertToShares(uint256 assets) internal view override returns (uint256 shares) {
        return assets * 1e18 / sharePrice();
    }

    // override default ERC4626 to use sharePrice
    function _convertToAssets(uint256 shares) internal view override returns (uint256 assets) {
        return shares * sharePrice() / 1e18;
    }

    function _updateLastEpochBlock() internal {} // TODO: Implement

    /*=========================== UUPS Functions =========================*/

    /**
     * @dev Authorize upgrade to new implementation
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}
}