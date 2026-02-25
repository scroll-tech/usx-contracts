// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IL2ERC20GatewayValidium} from "./IL2ERC20GatewayValidium.sol";
import {IScrollMessengerValidium} from "./IScrollMessengerValidium.sol";

/// @title PrivateGatewayCloak
/// @notice A contract for private gateway in cloak
/// @dev This contract is used to confirm USDC deposits and withdraw USX to scroll.
contract PrivateGatewayCloak is
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /**********
     * Events *
     **********/

    /// @notice Emitted when a deposit is confirmed
    /// @param nonce The nonce of the deposit
    /// @param encryptedReceiver The encrypted receiver
    /// @param keyId The ID of the encryption key used to encrypt the receiver
    /// @param amountUSDC The amount of USDC transferred
    event DepositConfirmed(
        uint256 nonce,
        bytes encryptedReceiver,
        uint256 keyId,
        uint256 amountUSDC
    );

    /// @notice Emitted when USX is withdrawn
    /// @param nonce The nonce of the deposit
    /// @param encryptedReceiver The encrypted receiver
    /// @param keyId The ID of the encryption key used to encrypt the receiver
    /// @param amountUSDC The amount of USDC transferred
    /// @param actualReceiver The actual receiver of the USX
    /// @param amountUSX The amount of USX withdrawn
    event WithdrawUSX(
        uint256 nonce,
        bytes encryptedReceiver,
        uint256 keyId,
        uint256 amountUSDC,
        address actualReceiver,
        uint256 amountUSX
    );

    /**********
     * Errors *
     **********/

    /// @dev Thrown when the deposit is already confirmed (duplicate confirm)
    error ErrorDepositAlreadyConfirmed();

    /// @dev Thrown when the deposit is not confirmed
    error ErrorDepositNotConfirmed();

    /// @dev Thrown when the deposit is already withdrawn (duplicate withdraw)
    error ErrorDepositAlreadyWithdrawn();

    /// @dev Thrown when the caller is not the messenger
    error ErrorCallerIsNotMessenger();

    /// @dev Thrown when the caller is not the counterpart gateway
    error ErrorCallerIsNotCounterpartGateway();

    /*************
     * Constants *
     *************/

    /// @notice The role required to withdraw USX
    bytes32 public constant WITHDRAW_USX_ROLE = keccak256("WITHDRAW_USX_ROLE");

    /***********************
     * Immutable Variables *
     ***********************/

    /// @notice The address of the USDC token
    address public immutable USDC;

    /// @notice The address of the USX token
    address public immutable USX;

    /// @notice The address of the ERC20 gateway in cloak
    address public immutable erc20Gateway;

    /// @notice The address of the messenger
    address public immutable messenger;

    /// @notice The address of the private gateway in scroll.
    address public immutable counterpart;

    /*********************
     * Storage Variables *
     *********************/

    /// @notice Mapping from hash to confirmed deposits
    mapping(bytes32 => bool) public confirmedDeposits;

    /// @notice Mapping from hash to withdrawn deposits
    mapping(bytes32 => bool) public withdrawnDeposits;

    /***************
     * Constructor *
     ***************/

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev This constructor is used to initialize the immutable variables
    /// @param _USDC The address of the USDC token
    /// @param _USX The address of the USX token
    /// @param _erc20Gateway The address of the ERC20 gateway in cloak
    /// @param _counterpart The address of the private gateway in scroll
    constructor(
        address _USDC,
        address _USX,
        address _erc20Gateway,
        address _counterpart
    ) {
        _disableInitializers();

        USDC = _USDC;
        USX = _USX;
        erc20Gateway = _erc20Gateway;
        messenger = IL2ERC20GatewayValidium(_erc20Gateway).messenger();
        counterpart = _counterpart;
    }

    /// @notice Initializes the contract
    /// @param initialAdmin The address of the initial admin
    function initialize(address initialAdmin) external initializer {
        __Context_init();
        __ERC165_init();
        __AccessControl_init();
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice Confirms a deposit
    /// @dev The caller must be the messenger and the counterpart gateway in scroll
    /// @param nonce The nonce of the deposit
    /// @param encryptedReceiver The encrypted receiver
    /// @param keyId The ID of the encryption key used to encrypt the receiver
    /// @param amountUSDC The amount of USDC transferred
    function confirmDeposit(
        uint256 nonce,
        bytes memory encryptedReceiver,
        uint256 keyId,
        uint256 amountUSDC
    ) external nonReentrant {
        // check if the caller is the messenger
        if (msg.sender != messenger) {
            revert ErrorCallerIsNotMessenger();
        }

        // check if the caller is the counterpart gateway in scroll
        if (
            counterpart !=
            IScrollMessengerValidium(messenger).xDomainMessageSender()
        ) {
            revert ErrorCallerIsNotCounterpartGateway();
        }

        bytes32 hash = keccak256(
            abi.encode(nonce, encryptedReceiver, keyId, amountUSDC)
        );
        // just in case, should not happen
        if (confirmedDeposits[hash]) revert ErrorDepositAlreadyConfirmed();

        confirmedDeposits[hash] = true;

        emit DepositConfirmed(nonce, encryptedReceiver, keyId, amountUSDC);
    }

    /// @notice Withdraws USX from the contract
    /// @dev The caller must have the WITHDRAW_USX_ROLE role to withdraw USX
    /// @param nonce The nonce of the deposit
    /// @param encryptedReceiver The encrypted receiver
    /// @param amountUSDC The amount of USDC transferred
    /// @param actualReceiver The actual receiver of the USX
    function withdrawUSX(
        uint256 nonce,
        bytes memory encryptedReceiver,
        uint256 keyId,
        uint256 amountUSDC,
        address actualReceiver
    ) external onlyRole(WITHDRAW_USX_ROLE) nonReentrant {
        bytes32 hash = keccak256(
            abi.encode(nonce, encryptedReceiver, keyId, amountUSDC)
        );
        if (!confirmedDeposits[hash]) {
            revert ErrorDepositNotConfirmed();
        }
        if (withdrawnDeposits[hash]) {
            revert ErrorDepositAlreadyWithdrawn();
        }
        withdrawnDeposits[hash] = true;

        // USDC has decimal 6 and USX has decimal 18, so we need to scale up by 10**12
        uint256 amountUSX = amountUSDC * 10 ** 12;

        // approve just in case
        IERC20(USX).forceApprove(erc20Gateway, amountUSX);
        IL2ERC20GatewayValidium(erc20Gateway).withdrawERC20(
            USX,
            actualReceiver,
            amountUSX,
            0
        );

        emit WithdrawUSX(
            nonce,
            encryptedReceiver,
            keyId,
            amountUSDC,
            actualReceiver,
            amountUSX
        );
    }

    /// @notice Withdraws tokens from the contract
    /// @param token The address of the token to withdraw
    /// @param amount The amount of tokens to withdraw
    function withdrawTokens(
        address token,
        address receiver,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) {
            Address.sendValue(payable(receiver), amount);
        } else {
            IERC20(token).safeTransfer(receiver, amount);
        }
    }
}
