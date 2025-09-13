// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title sUSX
/// @notice The main contract for the sUSX token, allowing USX holders to stake to share in protocols profits
/// @dev ERC4626 vault

contract sUSX is ERC4626Upgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    /*=========================== Errors =========================*/

    error ZeroAddress();
    error NotGovernance();
    error NotTreasury();
    error WithdrawalAlreadyClaimed();
    error WithdrawalPeriodNotPassed();
    error NextEpochNotStarted();
    error InvalidMinWithdrawalPeriod();
    error InvalidWithdrawalFeeFraction();
    error TreasuryAlreadySet();
    error USXTransferFailed();
    error DepositsFrozen();

    /*=========================== Events =========================*/

    event TreasurySet(address indexed treasury);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event EpochAdvanced(uint256 oldEpochBlock, uint256 newEpochBlock);
    event WithdrawalRequested(address indexed user, uint256 sharesAmount, uint256 withdrawalId);
    event WithdrawalClaimed(address indexed user, uint256 withdrawalId, uint256 usxAmount);
    event DepositsFrozenChanged(bool frozen);
    event WithdrawalPeriodSet(uint256 oldPeriod, uint256 newPeriod);
    event WithdrawalFeeFractionSet(uint256 oldFraction, uint256 newFraction);
    event EpochDurationSet(uint256 oldDuration, uint256 newDuration);

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

    /// @custom:storage-location erc7201:susx.main
    struct SUSXStorage {
        IERC20 USX; // USX token reference (the underlying asset)
        ITreasury treasury; // treasury contract
        address governance; // address that controls governance of the contract
        uint256 withdrawalPeriod; // withdrawal period in blocks, (default == 108000 (15 days))
        uint256 withdrawalFeeFraction; // fraction of withdrawals determining the withdrawal fee, (default 0.5% == 500) with precision to 0.001 percent
        uint256 minWithdrawalPeriod; // withdrawal period in blocks, (default == 108000 (15 days))
        uint256 lastEpochBlock; // block number of the last epoch
        uint256 withdrawalIdCounter;
        uint256 epochDuration; //  duration of epoch in blocks, (default == 216000 (30days))
        bool depositsFrozen; // true = deposits are frozen, false = deposits are allowed
        mapping(uint256 => WithdrawalRequest) withdrawalRequests;
    }

    struct WithdrawalRequest {
        address user; // Address of withdrawer
        uint256 amount; // sUSX amount redeemed
        uint256 withdrawalBlock; // Block number of the withdrawal request
        bool claimed; // True = withdrawal request has been claimed
    }

    // keccak256(abi.encode(uint256(keccak256("susx.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant SUSX_STORAGE_LOCATION = 0x0c53c51c00000000000000000000000000000000000000000000000000000000;

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
        $.withdrawalPeriod = 108000; // 15 days (assuming 12 second block time)
        $.withdrawalFeeFraction = 500; // 0.5%
        $.minWithdrawalPeriod = 108000; // 15 days
        $.epochDuration = 216000; // 30 days
        $.lastEpochBlock = block.number; // Set to current block number
    }

    /// @notice Set the initial Treasury address - can only be called once when treasury is address(0)
    /// @param _treasury Address of the Treasury contract
    function setInitialTreasury(address _treasury) external onlyGovernance {
        if (_treasury == address(0)) revert ZeroAddress();
        SUSXStorage storage $ = _getStorage();
        if ($.treasury != ITreasury(address(0))) revert TreasuryAlreadySet();

        $.treasury = ITreasury(_treasury);
        emit TreasurySet(_treasury);
    }

    /*=========================== Public Functions =========================*/

    /// @notice Finishes a withdrawal, claiming a specified withdrawal claim
    /// @dev Allowed after withdrawalPeriod AND epoch the user made withdrawal on is finished, after Gross Profits has been counted
    ///     Portion is sent to the Governance Warchest (withdrawalFee applied here)
    /// @param withdrawalId The id of the withdrawal to claim
    function claimWithdraw(uint256 withdrawalId) public nonReentrant {
        SUSXStorage storage $ = _getStorage();

        // Check if the withdrawal request is unclaimed
        if ($.withdrawalRequests[withdrawalId].claimed) revert WithdrawalAlreadyClaimed();

        // Check if the withdrawal period has passed
        if ($.withdrawalRequests[withdrawalId].withdrawalBlock + $.withdrawalPeriod > block.number) {
            revert WithdrawalPeriodNotPassed();
        }

        // Check if the next epoch has started since the withdrawal request was made
        if ($.withdrawalRequests[withdrawalId].withdrawalBlock > $.lastEpochBlock) revert NextEpochNotStarted();

        // Get the total USX amount for the amount of sUSX being redeemed
        uint256 USXAmount = _convertToAssets($.withdrawalRequests[withdrawalId].amount, Math.Rounding.Floor);

        // Burn sUSX shares
        _burn(msg.sender, $.withdrawalRequests[withdrawalId].amount);

        // Distribute portion of USX to the Governance Warchest
        uint256 governanceWarchestPortion = withdrawalFee(USXAmount);
        bool success = $.USX.transfer($.treasury.governanceWarchest(), governanceWarchestPortion);
        if (!success) revert USXTransferFailed();

        // Send the remaining USX to the user
        uint256 userPortion = USXAmount - governanceWarchestPortion;
        success = $.USX.transfer($.withdrawalRequests[withdrawalId].user, userPortion);
        if (!success) revert USXTransferFailed();

        // Mark the withdrawal as claimed
        $.withdrawalRequests[withdrawalId].claimed = true;

        emit WithdrawalClaimed($.withdrawalRequests[withdrawalId].user, withdrawalId, USXAmount);
    }

    /// @notice Returns the current share price of sUSX
    /// @dev Calculated using on chain USX balance and linear profit accrual (USX.balanceOf(this) - profits not yet distributed for last epoch)
    /// @return The current share price of sUSX
    function sharePrice() public view returns (uint256) {
        uint256 supply = totalSupply();

        // Handle the first deposit case
        if (supply == 0) {
            return 1e18; // 1:1 ratio for first deposit
        }

        SUSXStorage storage $ = _getStorage();
        uint256 base = $.USX.balanceOf(address(this));
        uint256 undistributedRewardsUSX = $.treasury.substractProfitLatestEpoch() * 1e12;
        uint256 totalUSX = base - undistributedRewardsUSX;

        return Math.mulDiv(totalUSX, 1e18, supply, Math.Rounding.Floor);
    }

    /// @notice Returns the withdrawal fee for a specified withdrawal amount
    /// @dev Withdrawal fee taken on all withdrawals that goes to the Governance Warchest
    /// @param withdrawalAmount The amount of sUSX to withdraw
    /// @return The withdrawal fee for the specified withdrawal amount
    function withdrawalFee(uint256 withdrawalAmount) public view returns (uint256) {
        SUSXStorage storage $ = _getStorage();
        return Math.mulDiv(withdrawalAmount, $.withdrawalFeeFraction, 1000000, Math.Rounding.Floor);
    }

    /*=========================== Governance Functions =========================*/

    /// @notice Sets withdrawal period in blocks
    /// @param _minWithdrawalPeriod The new withdrawal period in blocks
    function setMinWithdrawalPeriod(uint256 _minWithdrawalPeriod) public onlyGovernance {
        if (_minWithdrawalPeriod < 108000) revert InvalidMinWithdrawalPeriod();
        SUSXStorage storage $ = _getStorage();
        uint256 oldPeriod = $.minWithdrawalPeriod;
        $.minWithdrawalPeriod = _minWithdrawalPeriod;
        emit WithdrawalPeriodSet(oldPeriod, _minWithdrawalPeriod);
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

    /// @notice Sets duration of epoch in blocks
    /// @param _epochDurationBlocks The new epoch duration in blocks
    function setEpochDuration(uint256 _epochDurationBlocks) public onlyGovernance {
        SUSXStorage storage $ = _getStorage();
        uint256 oldDuration = $.epochDuration;
        $.epochDuration = _epochDurationBlocks;
        emit EpochDurationSet(oldDuration, _epochDurationBlocks);
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

    /// @notice Unfreeze deposits, allowing users to deposit again
    function unfreeze() external onlyGovernance {
        SUSXStorage storage $ = _getStorage();
        $.depositsFrozen = false;
        emit DepositsFrozenChanged(false);
    }

    /*=========================== Treasury Functions =========================*/

    /// @notice Updates lastEpochBlock to the current block number
    function updateLastEpochBlock() external onlyTreasury {
        SUSXStorage storage $ = _getStorage();

        uint256 oldEpochBlock = $.lastEpochBlock;
        $.lastEpochBlock = block.number;
        emit EpochAdvanced(oldEpochBlock, block.number);
    }

    /// @notice Freeze deposits, preventing users from depositing USX
    /// @dev Used by Treasury to freeze deposits if a loss is reported that is large enough to exceed Insurance Buffer and burn USX in sUSX vault
    function freezeDeposits() external onlyTreasury {
        SUSXStorage storage $ = _getStorage();
        $.depositsFrozen = true;
        emit DepositsFrozenChanged(true);
    }

    /*=========================== Internal Functions =========================*/

    /// @dev Override default ERC4626 to check if deposits are frozen
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        SUSXStorage storage $ = _getStorage();

        // Check if deposits are frozen
        if ($.depositsFrozen) revert DepositsFrozen();

        // Call parent implementation
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev User must wait for withdrawalPeriod to pass before unstaking (withdrawalPeriod)
    /// @dev Override default ERC4626 for the 2 step withdrawal process in protocol
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Record withdrawal request
        SUSXStorage storage $ = _getStorage();
        $.withdrawalRequests[$.withdrawalIdCounter] =
            WithdrawalRequest({user: receiver, amount: shares, withdrawalBlock: block.number, claimed: false});

        // Emit standard ERC4626 Withdraw event for consistency
        emit Withdraw(caller, receiver, owner, assets, shares);

        // Emit additional withdrawal request event for sUSX-specific functionality
        emit WithdrawalRequested(receiver, shares, $.withdrawalIdCounter);

        // Increment withdrawalIdCounter
        $.withdrawalIdCounter++;
    }

    /// @dev Override default ERC4626 to use sharePrice
    function _convertToShares(uint256 assets, Math.Rounding /* rounding */ )
        internal
        view
        override
        returns (uint256 shares)
    {
        return Math.mulDiv(assets, 1e18, sharePrice(), Math.Rounding.Floor);
    }

    /// @dev Override default ERC4626 to use sharePrice
    function _convertToAssets(uint256 shares, Math.Rounding /* rounding */ )
        internal
        view
        override
        returns (uint256 assets)
    {
        return Math.mulDiv(shares, sharePrice(), 1e18, Math.Rounding.Floor);
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

    function minWithdrawalPeriod() public view returns (uint256) {
        return _getStorage().minWithdrawalPeriod;
    }

    function lastEpochBlock() public view returns (uint256) {
        return _getStorage().lastEpochBlock;
    }

    function withdrawalIdCounter() public view returns (uint256) {
        return _getStorage().withdrawalIdCounter;
    }

    function epochDuration() public view returns (uint256) {
        return _getStorage().epochDuration;
    }

    function withdrawalRequests(uint256 id) public view returns (WithdrawalRequest memory) {
        return _getStorage().withdrawalRequests[id];
    }

    function depositsFrozen() public view returns (bool) {
        return _getStorage().depositsFrozen;
    }
}
