// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    event EpochAdvanced(uint256 oldEpochBlock, uint256 newEpochBlock, address indexed caller);

    /*=========================== Modifiers =========================*/

    modifier onlyGovernance() {
        if (msg.sender != _getStorage().governance) revert NotGovernance();
        _;
    }

    modifier updateEpoch() {
        _updateLastEpochBlock();
        _;
    }

    /*=========================== Storage =========================*/

    /// @custom:storage-location erc7201:susx.main
    struct SUSXStorage {
        IERC20 USX; // USX token reference (the underlying asset)
        ITreasury treasury;     // treasury contract
        address governance;    // address that controls governance of the contract
        uint256 withdrawalPeriod;    // withdrawal period in blocks, (default == 108000 (15 days))
        uint256 withdrawalFeeFraction;    // fraction of withdrawals determining the withdrawal fee, (default 0.5% == 500) with precision to 0.001 percent
        uint256 minWithdrawalPeriod;     // withdrawal period in blocks, (default == 108000 (15 days))
        uint256 lastEpochBlock;     // block number of the last epoch
        uint256 withdrawalIdCounter; 
        uint256 epochDuration;     //  duration of epoch in blocks, (default == 216000 (30days))
        mapping(uint256 => WithdrawalRequest) withdrawalRequests;
    }

    struct WithdrawalRequest {
        address user;                   // Address of withdrawer
        uint256 amount;                 // sUSX amount redeemed
        uint256 withdrawalBlock;        // Block number of the withdrawal request
        bool claimed;                   // True = withdrawal request has been claimed
    }

    // keccak256(abi.encode(uint256(keccak256("susx.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant SUSX_STORAGE_LOCATION =
        0x0c53c51c00000000000000000000000000000000000000000000000000000000;

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
        
        SUSXStorage storage $ = _getStorage();
        $.USX = IERC20(_usx);
        $.treasury = ITreasury(_treasury);
        $.governance = _governance;
        
        // Set default values
        $.withdrawalPeriod = 108000;      // 15 days (assuming 12 second block time)
        $.withdrawalFeeFraction = 500;    // 0.5%
        $.minWithdrawalPeriod = 108000;   // 15 days
        $.epochDuration = 216000;         // 30 days
        $.lastEpochBlock = block.number;  // Set to current block number
    }

    /**
     * @dev Set the initial Treasury address - can only be called once when treasury is address(0)
     * @param _treasury Address of the Treasury contract
     */
    function setInitialTreasury(address _treasury) external onlyGovernance {
        if (_treasury == address(0)) revert ZeroAddress();
        SUSXStorage storage $ = _getStorage();
        if ($.treasury != ITreasury(address(0))) revert TreasuryAlreadySet();
        
        $.treasury = ITreasury(_treasury);
        emit TreasurySet(_treasury);
    }

    /*=========================== Public Functions =========================*/

    // after withdrawalPeriod AND epoch the user made withdrawal on is finished, after Gross Profits has been counted
    // portion is sent to the Governance Warchest (withdrawalFee applied here)
    function claimWithdraw(uint256 withdrawalId) public updateEpoch {
        SUSXStorage storage $ = _getStorage();
        
        // Check if the withdrawal request is unclaimed
        if ($.withdrawalRequests[withdrawalId].claimed) revert WithdrawalAlreadyClaimed();

        // Check if the withdrawal period has passed
        if ($.withdrawalRequests[withdrawalId].withdrawalBlock + $.withdrawalPeriod > block.number) revert WithdrawalPeriodNotPassed();

        // Check if the next epoch has started since the withdrawal request was made
        if ($.withdrawalRequests[withdrawalId].withdrawalBlock > $.lastEpochBlock) revert NextEpochNotStarted();

        // Get the total USX amount for the amount of sUSX being redeemed
        uint256 USXAmount = $.withdrawalRequests[withdrawalId].amount * sharePrice() / 1e18;

        // Distribute portion of USX to the Governance Warchest
        uint256 governanceWarchestPortion = withdrawalFee(USXAmount);
        bool success = $.USX.transferFrom(address(this), $.treasury.governanceWarchest(), governanceWarchestPortion);
        if (!success) revert USXTransferFailed();

        // Send the remaining USX to the user
        uint256 userPortion = USXAmount - governanceWarchestPortion;
        success = $.USX.transferFrom(address(this), $.withdrawalRequests[withdrawalId].user, userPortion);
        if (!success) revert USXTransferFailed();

        // Mark the withdrawal as claimed
        $.withdrawalRequests[withdrawalId].claimed = true;
    }

    // calculated using on chain USX balance and linear profit accrual (USX.balanceOf(this) + linear scaled profits from last epoch)
    function sharePrice() public view returns (uint256) {
        uint256 supply = totalSupply();
        
        // Handle the first deposit case
        if (supply == 0) {
            return 1e18; // 1:1 ratio for first deposit
        }
        
        SUSXStorage storage $ = _getStorage();
        uint256 base = $.USX.balanceOf(address(this));
        uint256 rewards = $.treasury.profitLatestEpoch();
        uint256 totalUSX = base + rewards;
        
        return totalUSX * 1e18 / supply;
    }

    // withdrawal fee taken on all withdrawals that goes to the Governance Warchest
    function withdrawalFee(uint256 withdrawalAmount) public view returns (uint256) {
        SUSXStorage storage $ = _getStorage();
        return withdrawalAmount * $.withdrawalFeeFraction / 100000;
    }

    /*=========================== Governance Functions =========================*/

    // sets withdrawal period in blocks
    function setMinWithdrawalPeriod(uint256 _minWithdrawalPeriod) public onlyGovernance {
        if (_minWithdrawalPeriod < 108000) revert InvalidMinWithdrawalPeriod();
        SUSXStorage storage $ = _getStorage();
        $.minWithdrawalPeriod = _minWithdrawalPeriod;
    }

    // sets withdrawal fee with precision to 0.001 percent // TODO: Is it ok to have no min/max?
    function setWithdrawalFeeFraction(uint256 _withdrawalFeeFraction) public onlyGovernance {
        SUSXStorage storage $ = _getStorage();
        $.withdrawalFeeFraction = _withdrawalFeeFraction;
    }

    // duration of epoch in blocks
    function setEpochDuration(uint256 _epochDurationBlocks) public onlyGovernance {
        SUSXStorage storage $ = _getStorage();
        $.epochDuration = _epochDurationBlocks;
    }

    /**
     * @dev Set new governance address
     * @param newGovernance Address of new governance
     */
    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        
        SUSXStorage storage $ = _getStorage();
        address oldGovernance = $.governance;
        $.governance = newGovernance;
        
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
    ) internal override {
        // Update epochs before processing withdrawal
        _updateLastEpochBlock();
        
        // Check if user has enough sUSX shares
        if (balanceOf(owner) < shares) revert InsufficientBalance();

        // Burn sUSX shares
        _burn(owner, shares);

        // Record withdrawal request
        SUSXStorage storage $ = _getStorage();
        $.withdrawalRequests[$.withdrawalIdCounter] = WithdrawalRequest({
            user: receiver,
            amount: shares,
            withdrawalBlock: block.number,
            claimed: false
        });

        // Increment withdrawalIdCounter
        $.withdrawalIdCounter++;
    }

    // override default ERC4626 to use sharePrice
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256 shares) {
        return assets * 1e18 / sharePrice();
    }

    // override default ERC4626 to use sharePrice
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256 assets) {
        return shares * sharePrice() / 1e18;
    }

    // updates lastEpochBlock to the current epoch start block if an epoch has finished
    function _updateLastEpochBlock() internal {
        SUSXStorage storage $ = _getStorage();
        uint256 currentEpochStart = (block.number / $.epochDuration) * $.epochDuration;
        
        // Update if we're in a new epoch
        if (currentEpochStart > $.lastEpochBlock) {
            uint256 oldEpochBlock = $.lastEpochBlock;
            $.lastEpochBlock = currentEpochStart;
            emit EpochAdvanced(oldEpochBlock, currentEpochStart, msg.sender);
        }
    }

    // Manual epoch advancement (anyone can call)
    function advanceEpochs() external {
        SUSXStorage storage $ = _getStorage();
        uint256 currentEpochStart = (block.number / $.epochDuration) * $.epochDuration;
        
        // Update if we're in a new epoch OR if we're at the beginning and need to initialize
        if (currentEpochStart > $.lastEpochBlock || ($.lastEpochBlock == 0 && block.number > 0)) {
            uint256 oldEpochBlock = $.lastEpochBlock;
            $.lastEpochBlock = currentEpochStart;
            emit EpochAdvanced(oldEpochBlock, currentEpochStart, msg.sender);
        }
    }

    /*=========================== UUPS Functions =========================*/

    /**
     * @dev Authorize upgrade to new implementation
     * @param newImplementation Address of new implementation
     */
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
}