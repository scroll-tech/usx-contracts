// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStakedUSX} from "./interfaces/IStakedUSX.sol";

/// @title StakedUSX
/// @notice The main contract for the sUSX token, allowing USX holders to stake to share in protocols profits
/// @dev ERC4626 vault

contract StakedUSX is ERC4626Upgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IStakedUSX {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /*=========================== Errors =========================*/

    error ZeroAddress();
    error ZeroAmount();
    error NotGovernance();
    error NotTreasury();
    error WithdrawalAlreadyClaimed();
    error WithdrawalPeriodNotPassed();
    error InvalidWithdrawalPeriod();
    error InvalidWithdrawalFeeFraction();
    error InvalidEpochDuration();
    error TreasuryAlreadySet();
    error DepositsPaused();

    /*=========================== Events =========================*/

    event TreasurySet(address indexed treasury);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event EpochAdvanced(uint256 oldEpochBlock, uint256 newEpochBlock);
    event WithdrawalRequested(address indexed user, uint256 sharesAmount, uint256 withdrawalId);
    event WithdrawalClaimed(address indexed user, uint256 withdrawalId, uint256 usxAmount);
    event DepositPausedChanged(bool paused);
    event WithdrawalPeriodSet(uint256 oldPeriod, uint256 newPeriod);
    event WithdrawalFeeFractionSet(uint256 oldFraction, uint256 newFraction);
    event EpochDurationSet(uint256 oldDuration, uint256 newDuration);
    event RewardsReceived(uint256 amount);

    /*=========================== Constants =========================*/

    /// @dev Minimum epoch duration in seconds
    uint256 private constant MIN_EPOCH_DURATION = 1 days;

    /// @dev Precision for the fee fractions
    uint256 private constant FEE_PRECISION = 1000000;

    /*=========================== Modifiers =========================*/

    modifier onlyGovernance() {
        if (msg.sender != _getStorage().governance) revert NotGovernance();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != address(_getStorage().treasury)) revert NotTreasury();
        _;
    }

    /*=========================== Storage =========================*/

    /// @dev Compiler will pack this into single `uint256`.
    /// Usually, we assume the amount of rewards won't exceed `uint96.max`.
    /// In such case, the rate won't exceed `uint80.max`, since `periodLength` is at least `86400`.
    /// Also `uint40.max` is enough for timestamp, which is about 30000 years.
    struct RewardData {
        // The amount of rewards pending to distribute. In normal case it should always be the rounding error.
        uint96 queued;
        // The current reward rate per second.
        uint80 rate;
        // The last timestamp when the reward is distributed.
        uint40 lastUpdate;
        // The timestamp when this period will finish.
        uint40 finishAt;
    }

    /// @custom:storage-location erc7201:susx.main
    struct SUSXStorage {
        IERC20 USX; // USX token reference (the underlying asset)
        ITreasury treasury; // treasury contract
        address governance; // address that controls governance of the contract
        uint256 withdrawalPeriod; // withdrawal period in seconds, (default == 15 * 24 * 60 * 60 (15 days))
        uint256 withdrawalFeeFraction; // fraction of withdrawals determining the withdrawal fee, (default 0.05% == 500) with precision 6 decimals
        uint256 withdrawalCounter;
        RewardData rewardData;
        uint256 epochDuration; //  duration of epoch in seconds, (default == 30 * 24 * 60 * 60 (30 days))
        bool depositPaused; // true = deposits are frozen, false = deposits are allowed
        uint256 totalPendingWithdrawals; // the total amount of USX that is pending to be withdrawn
        mapping(uint256 => WithdrawalRequest) withdrawalRequests;
    }

    struct WithdrawalRequest {
        address user; // Address of withdrawer
        uint256 amount; // USX amount redeemed
        uint256 withdrawalTimestamp; // Timestamp of the withdrawal request
        bool claimed; // True = withdrawal request has been claimed
    }

    // keccak256(abi.encode(uint256(keccak256("susx.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant SUSX_STORAGE_LOCATION = 0x7ef495ffa61cc9596b858592e81bad4189b8a35b6b875460d576397f44d3c900;

    function _getStorage() private pure returns (SUSXStorage storage $) {
        assembly {
            $.slot := SUSX_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*=========================== Initialization =========================*/

    /// @notice Initialize the sUSX contract
    /// @param _usx Address of the USX token
    /// @param _treasury Address of the Treasury contract
    /// @param _governance Address of the governance
    function initialize(address _usx, address _treasury, address _governance) public initializer {
        if (_usx == address(0) || _governance == address(0)) revert ZeroAddress();

        // Initialize ERC4626, ERC20, and ReentrancyGuard
        __ERC4626_init(IERC20(_usx));
        __ERC20_init("sUSX", "sUSX");
        __ReentrancyGuard_init();

        SUSXStorage storage $ = _getStorage();
        $.USX = IERC20(_usx);
        $.treasury = ITreasury(_treasury);
        $.governance = _governance;

        // Set default values
        $.withdrawalPeriod = 15 days;
        $.withdrawalFeeFraction = 500;
        $.epochDuration = 30 days;
    }

    /// @notice Set the initial Treasury address - can only be called once when treasury is address(0)
    /// @param _treasury Address of the Treasury contract
    function initializeTreasury(address _treasury) external onlyGovernance {
        if (_treasury == address(0)) revert ZeroAddress();
        SUSXStorage storage $ = _getStorage();
        if ($.treasury != ITreasury(address(0))) revert TreasuryAlreadySet();

        $.treasury = ITreasury(_treasury);
        emit TreasurySet(_treasury);
    }

    /*=========================== Public Functions =========================*/

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view override returns (uint256) {
        SUSXStorage storage $ = _getStorage();
        uint256 balanceOfUSX = $.USX.balanceOf(address(this));
        (, uint256 undistributedRewardsUSX) = _pendingRewards($.rewardData);
        return balanceOfUSX - undistributedRewardsUSX - $.totalPendingWithdrawals;
    }

    /// @notice Finishes a withdrawal, claiming a specified withdrawal claim
    /// @dev Allowed only after withdrawalPeriod has passed since the withdrawal request
    /// @param withdrawalId The id of the withdrawal to claim
    function claimWithdraw(uint256 withdrawalId) public nonReentrant {
        SUSXStorage storage $ = _getStorage();

        // Check if the withdrawal request is unclaimed
        if ($.withdrawalRequests[withdrawalId].claimed) revert WithdrawalAlreadyClaimed();

        // Check if the withdrawal period has passed
        if ($.withdrawalRequests[withdrawalId].withdrawalTimestamp + $.withdrawalPeriod > block.timestamp) {
            revert WithdrawalPeriodNotPassed();
        }

        // Get the total USX amount for the amount of sUSX being redeemed
        uint256 USXAmount = $.withdrawalRequests[withdrawalId].amount;

        // Distribute portion of USX to the Governance Warchest
        uint256 governanceWarchestPortion = withdrawalFee(USXAmount);
        $.USX.safeTransfer($.treasury.governanceWarchest(), governanceWarchestPortion);

        // Send the remaining USX to the user
        uint256 userPortion = USXAmount - governanceWarchestPortion;
        $.USX.safeTransfer($.withdrawalRequests[withdrawalId].user, userPortion);

        // Mark the withdrawal as claimed
        $.withdrawalRequests[withdrawalId].claimed = true;
        $.totalPendingWithdrawals -= USXAmount;

        emit WithdrawalClaimed($.withdrawalRequests[withdrawalId].user, withdrawalId, USXAmount);
    }

    /// @notice Returns the current share price of sUSX
    /// @dev Calculated using on chain USX balance and linear profit accrual (USX.balanceOf(this) - profits not yet distributed for last epoch)
    /// @return The current share price of sUSX
    function sharePrice() public view returns (uint256) {
        return convertToAssets(1e18);
    }

    /// @notice Returns the withdrawal fee for a specified withdrawal amount
    /// @dev Withdrawal fee taken on all withdrawals that goes to the Governance Warchest
    /// @param withdrawalAmount The amount of sUSX to withdraw
    /// @return The withdrawal fee for the specified withdrawal amount
    function withdrawalFee(uint256 withdrawalAmount) public view returns (uint256) {
        SUSXStorage storage $ = _getStorage();
        return Math.mulDiv(withdrawalAmount, $.withdrawalFeeFraction, FEE_PRECISION, Math.Rounding.Floor);
    }

    /*=========================== Governance Functions =========================*/

    /// @notice Sets withdrawal period in seconds
    /// @param _withdrawalPeriod The new withdrawal period in seconds
    function setWithdrawalPeriod(uint256 _withdrawalPeriod) public onlyGovernance {
        SUSXStorage storage $ = _getStorage();
        uint256 oldPeriod = $.withdrawalPeriod;
        $.withdrawalPeriod = _withdrawalPeriod;
        emit WithdrawalPeriodSet(oldPeriod, _withdrawalPeriod);
    }

    /// @notice Sets withdrawal fee with precision to 0.001 percent
    /// @param _withdrawalFeeFraction The new withdrawal fee fraction
    function setWithdrawalFeeFraction(uint256 _withdrawalFeeFraction) public onlyGovernance {
        if (_withdrawalFeeFraction > 20000) revert InvalidWithdrawalFeeFraction();
        SUSXStorage storage $ = _getStorage();
        uint256 oldFraction = $.withdrawalFeeFraction;
        $.withdrawalFeeFraction = _withdrawalFeeFraction;
        emit WithdrawalFeeFractionSet(oldFraction, _withdrawalFeeFraction);
    }

    /// @notice Sets duration of epoch in seconds
    /// @param _epochDurationSeconds The new epoch duration in seconds
    function setEpochDuration(uint256 _epochDurationSeconds) public onlyGovernance {
        if (_epochDurationSeconds < MIN_EPOCH_DURATION) revert InvalidEpochDuration();
        SUSXStorage storage $ = _getStorage();
        uint256 oldDuration = $.epochDuration;
        $.epochDuration = _epochDurationSeconds;
        emit EpochDurationSet(oldDuration, _epochDurationSeconds);
    }

    /// @notice Set new governance address
    /// @param newGovernance Address of new governance
    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();

        SUSXStorage storage $ = _getStorage();
        address oldGovernance = $.governance;
        $.governance = newGovernance;

        emit GovernanceTransferred(oldGovernance, newGovernance);
    }

    /// @notice Unpause deposit, allowing users to deposit again
    function unpauseDeposit() external onlyGovernance {
        SUSXStorage storage $ = _getStorage();
        $.depositPaused = false;
        emit DepositPausedChanged(false);
    }

    /// @notice Pause deposit, preventing users from depositing USX
    function pauseDeposit() external onlyGovernance {
        SUSXStorage storage $ = _getStorage();
        $.depositPaused = true;
        emit DepositPausedChanged(true);
    }

    /*=========================== Treasury Functions =========================*/

    /// @notice Allows the owner to transfer rewards from the controller contract into this contract.
    /// @dev Caller should make sure the rewards are transferred to this contract before calling this function
    /// @param amount The amount of rewards to transfer.
    function notifyRewards(uint256 amount) external nonReentrant onlyTreasury {
        if (amount == 0) return; // do nothing when no rewards are transferred
        SUSXStorage storage $ = _getStorage();

        // update rewards
        RewardData memory data = $.rewardData;
        _increaseRewards(data, $.epochDuration, amount);
        $.rewardData = data;

        emit RewardsReceived(amount);
    }

    /*=========================== Internal Functions =========================*/

    /// @dev Override default ERC4626 to check if deposits are frozen
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal nonReentrant override {
        if (assets == 0 || shares == 0) revert ZeroAmount();

        SUSXStorage storage $ = _getStorage();

        // Check if deposits are frozen
        if ($.depositPaused) revert DepositsPaused();

        // Call parent implementation
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev User must wait for withdrawalPeriod to pass before unstaking (withdrawalPeriod)
    /// @dev Override default ERC4626 for the 2 step withdrawal process in protocol
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        nonReentrant
        override
    {
        if (assets == 0 || shares == 0) revert ZeroAmount();

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);

        // Record withdrawal request
        SUSXStorage storage $ = _getStorage();
        $.totalPendingWithdrawals += assets;
        $.withdrawalRequests[$.withdrawalCounter] =
            WithdrawalRequest({user: receiver, amount: assets, withdrawalTimestamp: block.timestamp, claimed: false});

        // Emit standard ERC4626 Withdraw event for consistency
        emit Withdraw(caller, receiver, owner, assets, shares);

        // Emit additional withdrawal request event for sUSX-specific functionality
        emit WithdrawalRequested(receiver, assets, $.withdrawalCounter);

        // Increment withdrawalCounter
        $.withdrawalCounter++;
    }

    /// @dev Add new rewards to current one.
    ///
    /// @param _data The struct of reward data, will be modified inplace.
    /// @param _periodLength The length of a period, caller should make sure it is at least `86400`.
    /// @param _amount The amount of new rewards to distribute.
    function _increaseRewards(
        RewardData memory _data,
        uint256 _periodLength,
        uint256 _amount
    ) internal view {
        _amount = _amount + _data.queued;
        _data.queued = 0;

        // no supply, all rewards are queued
        if (totalSupply() == 0) {
            if (block.timestamp < _data.finishAt) {
                _amount += uint256(_data.rate) * (_data.finishAt - block.timestamp);
            }
            _data.rate = 0;
            _data.lastUpdate = uint40(block.timestamp);
            _data.finishAt = uint40(block.timestamp + _periodLength);
            _data.queued = uint96(_amount);
            return;
        }

        if (block.timestamp >= _data.finishAt) {
            // period finished, distribute to next period
            _data.rate = (_amount / _periodLength).toUint80();
            _data.queued = uint96(_amount - (_data.rate * _periodLength)); // keep rounding error
            _data.lastUpdate = uint40(block.timestamp);
            _data.finishAt = uint40(block.timestamp + _periodLength);
        } else {
            _amount = _amount + uint256(_data.rate) * (_data.finishAt - block.timestamp);
            _data.rate = (_amount / _periodLength).toUint80();
            _data.queued = uint96(_amount - (_data.rate * _periodLength)); // keep rounding error
            _data.lastUpdate = uint40(block.timestamp);
            _data.finishAt = uint40(block.timestamp + _periodLength);
        }
    }

    /// @dev Return the amount of pending distributed rewards in current period.
    ///
    /// @param _data The struct of reward data.
    /// @return The amount of distributed rewards in current period.
    /// @return The amount of pending distributed rewards in current period.
    function _pendingRewards(RewardData memory _data) internal view returns (uint256, uint256) {
        uint256 _elapsed;
        uint256 _left;
        if (block.timestamp > _data.finishAt) {
            // finishAt < lastUpdate will never happen, but just in case.
            _elapsed = _data.finishAt >= _data.lastUpdate ? _data.finishAt - _data.lastUpdate : 0;
        } else {
            unchecked {
                _elapsed = block.timestamp - _data.lastUpdate;
                _left = uint256(_data.finishAt) - block.timestamp;
            }
        }

        return (uint256(_data.rate) * _elapsed, uint256(_data.rate) * _left + _data.queued);
    }

    /*=========================== UUPS Functions =========================*/

    /// @dev Authorize upgrade to new implementation
    /// @param newImplementation Address of new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {}

    /*=========================== View Functions =========================*/

    function USX() public view returns (IERC20) {
        return _getStorage().USX;
    }

    function treasury() public view returns (ITreasury) {
        return _getStorage().treasury;
    }

    function governance() public view returns (address) {
        return _getStorage().governance;
    }

    function withdrawalPeriod() public view returns (uint256) {
        return _getStorage().withdrawalPeriod;
    }

    function withdrawalFeeFraction() public view returns (uint256) {
        return _getStorage().withdrawalFeeFraction;
    }

    function rewardData() public view returns (RewardData memory) {
        return _getStorage().rewardData;
    }

    function withdrawalCounter() public view returns (uint256) {
        return _getStorage().withdrawalCounter;
    }

    function epochDuration() public view returns (uint256) {
        return _getStorage().epochDuration;
    }

    function withdrawalRequests(uint256 id) public view returns (WithdrawalRequest memory) {
        return _getStorage().withdrawalRequests[id];
    }

    function depositPaused() public view returns (bool) {
        return _getStorage().depositPaused;
    }
}
