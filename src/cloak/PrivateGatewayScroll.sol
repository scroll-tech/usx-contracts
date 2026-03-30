// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IL1ERC20GatewayValidium} from "./IL1ERC20GatewayValidium.sol";
import {IScrollMessengerValidium} from "./IScrollMessengerValidium.sol";

import {PrivateGatewayCloak} from "./PrivateGatewayCloak.sol";

/// @title PrivateGatewayScroll
/// @notice A contract for private gateway in scroll
/// @dev This contract is used to transfer USDC to cloak.
contract PrivateGatewayScroll is
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /**********
     * Events *
     **********/

    /// @notice Emitted when a new encryption key is registered
    /// @param keyId The ID of the new encryption key
    /// @param key The new encryption key
    event NewEncryptionKey(uint256 indexed keyId, bytes key);

    /// @notice Emitted when the minimum amount of USDC to transfer is updated
    /// @param oldMinUSDCAmount The old minimum amount of USDC to transfer
    /// @param newMinUSDCAmount The new minimum amount of USDC to transfer
    event MinUSDCAmountUpdated(
        uint256 oldMinUSDCAmount,
        uint256 newMinUSDCAmount
    );

    /// @notice Emitted when the fee percentage is updated
    /// @param oldFeePercentage The old fee percentage
    /// @param newFeePercentage The new fee percentage
    event FeePercentageUpdated(
        uint256 oldFeePercentage,
        uint256 newFeePercentage
    );

    /// @notice Emitted when the max fee amount is updated
    /// @param oldMaxFeeAmount The old max fee amount
    /// @param newMaxFeeAmount The new max fee amount
    event MaxFeeAmountUpdated(uint256 oldMaxFeeAmount, uint256 newMaxFeeAmount);

    /// @notice Emitted when USDC is transferred
    /// @param nonce The nonce of the transfer
    /// @param encryptedReceiver The encrypted receiver
    /// @param keyId The ID of the encryption key used to encrypt the receiver
    /// @param amountUSDC The amount of USDC transferred
    event USDCTransferred(
        uint256 indexed nonce,
        bytes encryptedReceiver,
        uint256 keyId,
        uint256 amountUSDC
    );

    /// @notice Emitted when the expected USDC receiver is updated
    /// @param oldExpectedUSDCReceiver The old expected USDC receiver
    /// @param newExpectedUSDCReceiver The new expected USDC receiver
    event ExpectedUSDCReceiverUpdated(EncryptedReceiver oldExpectedUSDCReceiver, EncryptedReceiver newExpectedUSDCReceiver);

    /**********
     * Errors *
     **********/

    /// @dev Thrown when the amount is invalid
    error ErrorInvalidAmount();

    /// @dev Thrown when the fee percentage is invalid
    error ErrorInvalidFeePercentage();

    /// @dev Thrown when the encryption key is unknown
    error ErrorUnknownEncryptionKey();

    /// @dev Thrown when the encryption key is deprecated
    error ErrorDeprecatedEncryptionKey();

    /// @dev Thrown when the encryption key length is invalid
    error ErrorInvalidEncryptionKeyLength();

    /// @dev Thrown when the encryption key is invalid
    error ErrorInvalidEncryptionKey();

    /// @dev Thrown when the token is not supported
    error ErrorTokenNotSupported();

    /// @dev Thrown when the swap router is not supported
    error ErrorSwapRouterNotSupported();

    /// @dev Thrown when the swap failed
    error ErrorSwapFailed();

    /// @dev Thrown when the USDC receiver is invalid
    error ErrorInvalidUSDCReceiver();

    /*************
     * Constants *
     *************/

    /// @notice The role required to register new encryption keys
    bytes32 public constant KEY_MANAGER_ROLE = keccak256("KEY_MANAGER_ROLE");

    /// @notice The gas limit for the deposit operation
    uint256 private constant GAS_LIMIT = 1000000;

    /// @notice The precision for the fee percentage
    uint256 private constant PRECISION = 1e18;

    /// @notice The maximum fee percentage
    uint256 private constant MAX_FEE_PERCENTAGE = 1e17; // 10%

    /***********
     * Structs *
     ***********/

    /// @notice A struct representing an encrypted receiver
    /// @param receiver The encrypted receiver
    /// @param keyId The ID of the encryption key used to encrypt the receiver
    struct EncryptedReceiver {
        bytes receiver;
        uint256 keyId;
    }

    /***********************
     * Immutable Variables *
     ***********************/

    /// @notice The address of the USDC token
    address public immutable USDC;

    /// @notice The address of the USX token
    address public immutable USX;

    /// @notice The address of the ERC20 gateway in scroll
    address public immutable erc20Gateway;

    /// @notice The address of the messenger
    address public immutable messenger;

    /// @notice The address of the private gateway in cloak.
    address public immutable counterpart;

    /*********************
     * Storage Variables *
     *********************/

    /// @notice The nonce of the private gateway scroll contract.
    uint256 public nonce;

    /// @notice The list of encryption keys
    bytes[] public encryptionKeys;

    /// @notice The list of supported tokens
    EnumerableSet.AddressSet private supportedTokens;

    /// @notice The list of supported swap routers
    EnumerableSet.AddressSet private supportedSwapRouters;

    /// @notice Mapping from swap router to token spender
    mapping(address => address) private spenders;

    /// @notice The minimum amount of the USDC to transfer
    uint256 public minUSDCAmount;

    /// @notice The fee percentage of the private gateway scroll contract.
    uint256 public feePercentage;

    /// @notice The max fee amount of the private gateway scroll contract.
    uint256 public maxFeeAmount;

    /// @notice The expected USDC receiver
    EncryptedReceiver public expectedUSDCReceiver;

    /***************
     * Constructor *
     ***************/

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev This constructor is used to initialize the immutable variables
    /// @param _USDC The address of the USDC token
    /// @param _USX The address of the USX token
    /// @param _erc20Gateway The address of the ERC20 gateway in scroll
    /// @param _counterpart The address of the private gateway in cloak
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
        messenger = IL1ERC20GatewayValidium(_erc20Gateway).messenger();
        counterpart = _counterpart;
    }

    /// @notice Initializes the contract
    /// @param initialAdmin The address of the initial admin
    function initialize(
        address initialAdmin,
        uint256 _minUSDCAmount,
        uint256 _feePercentage,
        uint256 _maxFeeAmount
    ) external initializer {
        __Context_init();
        __ERC165_init();
        __AccessControl_init();
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);

        _updateMinUSDCAmount(_minUSDCAmount);
        _updateFeePercentage(_feePercentage);
        _updateMaxFeeAmount(_maxFeeAmount);
    }

    /// @notice Receive function for ETH
    receive() external payable {}

    /*************************
     * Public View Functions *
     *************************/

    /// @notice Returns the latest encryption key
    /// @return keyId The ID of the latest encryption key
    /// @return key The latest encryption key
    function getLatestEncryptionKey()
        public
        view
        returns (uint256 keyId, bytes memory key)
    {
        uint256 _numKeys = encryptionKeys.length;
        if (_numKeys == 0) revert ErrorUnknownEncryptionKey();
        keyId = _numKeys - 1;
        key = encryptionKeys[_numKeys - 1];
    }

    /// @notice Returns the encryption key at the given ID
    /// @param _keyId The ID of the encryption key to return
    /// @return key The encryption key at the given ID
    function getEncryptionKey(
        uint256 _keyId
    ) external view returns (bytes memory) {
        uint256 _numKeys = encryptionKeys.length;
        if (_numKeys == 0) revert ErrorUnknownEncryptionKey();
        if (_keyId >= _numKeys) revert ErrorUnknownEncryptionKey();
        if (_keyId < _numKeys - 1) revert ErrorDeprecatedEncryptionKey();
        return encryptionKeys[_numKeys - 1];
    }

    /// @notice Returns the supported tokens
    /// @return tokens The supported tokens
    function getSupportedTokens()
        external
        view
        returns (address[] memory tokens)
    {
        tokens = new address[](supportedTokens.length());
        for (uint256 i = 0; i < supportedTokens.length(); i++) {
            tokens[i] = supportedTokens.at(i);
        }
    }

    /// @notice Returns the supported swap routers
    /// @return swapRouters The supported swap routers
    function getSupportedSwapRouters()
        external
        view
        returns (address[] memory swapRouters)
    {
        swapRouters = new address[](supportedSwapRouters.length());
        for (uint256 i = 0; i < supportedSwapRouters.length(); i++) {
            swapRouters[i] = supportedSwapRouters.at(i);
        }
    }

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice Transfers USDC to the encrypted receivers
    /// @param amount The amount of USDC to transfer
    /// @param usxReceiver The encrypted receiver for the USX token
    /// @param usdcReceiver The encrypted receiver for the USDC token
    function transferUSDC(
        uint256 amount,
        EncryptedReceiver memory usxReceiver,
        EncryptedReceiver memory usdcReceiver
    ) external nonReentrant {
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);

        _transferUSDC(amount, usxReceiver, usdcReceiver);
    }

    /// @notice Transfers a token to the encrypted receivers
    /// @param token The address of the token to transfer
    /// @param swapAmount The amount of token to swap
    /// @param swapRouter The address of the swap router
    /// @param swapData The data for the swap
    /// @param usxReceiver The encrypted receiver for the USX token
    /// @param usdcReceiver The encrypted receiver for the USDC token
    function transferToken(
        address token,
        uint256 swapAmount,
        address swapRouter,
        bytes memory swapData,
        EncryptedReceiver memory usxReceiver,
        EncryptedReceiver memory usdcReceiver
    ) external payable nonReentrant {
        // check if the token is supported
        if (!supportedTokens.contains(token)) {
            revert ErrorTokenNotSupported();
        }

        // check if the swap router is supported
        if (!supportedSwapRouters.contains(swapRouter)) {
            revert ErrorSwapRouterNotSupported();
        }

        // transfer the token from msg.sender to this contract
        if (token == address(0)) {
            if (msg.value != swapAmount) revert ErrorInvalidAmount();
        } else {
            if (msg.value != 0) revert ErrorInvalidAmount();
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                swapAmount
            );
        }

        // swap the token to USDC
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        if (token != address(0)) {
            IERC20(token).forceApprove(spenders[swapRouter], swapAmount);
        }
        (bool success, ) = swapRouter.call{value: msg.value}(swapData);
        if (!success) revert ErrorSwapFailed();
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        uint256 usdcAmount = usdcAfter - usdcBefore;
        if (token != address(0)) {
            IERC20(token).forceApprove(spenders[swapRouter], 0); // remove approval
        }

        _transferUSDC(usdcAmount, usxReceiver, usdcReceiver);
    }

    /************************
     * Restricted Functions *
     ************************/

    /// @notice Registers a new encryption key
    /// @param _key The new encryption key to register
    /// @return keyId The ID of the new encryption key
    function registerNewEncryptionKey(
        bytes memory _key
    ) external onlyRole(KEY_MANAGER_ROLE) returns (uint256 keyId) {
        if (_key.length != 33) revert ErrorInvalidEncryptionKeyLength();
        keyId = encryptionKeys.length;
        encryptionKeys.push(_key);

        emit NewEncryptionKey(keyId, _key);
    }

    /// @notice Updates the minimum amount of USDC to transfer
    /// @param newMinUSDCAmount The new minimum amount of USDC to transfer
    function updateMinUSDCAmount(
        uint256 newMinUSDCAmount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateMinUSDCAmount(newMinUSDCAmount);
    }

    /// @notice Updates the fee percentage
    /// @param newFeePercentage The new fee percentage
    function updateFeePercentage(
        uint256 newFeePercentage
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateFeePercentage(newFeePercentage);
    }

    /// @notice Updates the max fee amount
    /// @param newMaxFeeAmount The new max fee amount
    function updateMaxFeeAmount(
        uint256 newMaxFeeAmount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateMaxFeeAmount(newMaxFeeAmount);
    }

    /// @notice Withdraws tokens from the contract
    /// @dev This function is used to withdraw fees or unexpected tokens from the contract.
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

    /// @notice Updates the supported tokens
    /// @param tokens The addresses of the tokens to update
    /// @param isSupported Whether the tokens are supported
    function updateSupportedTokens(
        address[] memory tokens,
        bool isSupported
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (isSupported) {
                supportedTokens.add(tokens[i]);
            } else {
                supportedTokens.remove(tokens[i]);
            }
        }
    }

    /// @notice Updates the supported swap routers
    /// @param swapRouter The address of the swap router to update
    /// @param spender The address of the spender to update
    /// @param isSupported Whether the swap router is supported
    function updateSupportedSwapRouter(
        address swapRouter,
        address spender,
        bool isSupported
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (isSupported) {
            supportedSwapRouters.add(swapRouter);
            spenders[swapRouter] = spender;
        } else {
            supportedSwapRouters.remove(swapRouter);
            delete spenders[swapRouter];
        }
    }

    /// @notice Updates the expected USDC receiver
    /// @param newExpectedUSDCReceiver The new expected USDC receiver
    function updateExpectedUSDCReceiver(
        EncryptedReceiver memory newExpectedUSDCReceiver
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EncryptedReceiver memory oldExpectedUSDCReceiver = expectedUSDCReceiver;
        expectedUSDCReceiver = newExpectedUSDCReceiver;

        emit ExpectedUSDCReceiverUpdated(oldExpectedUSDCReceiver, newExpectedUSDCReceiver);
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @dev Internal function to update the minimum amount of USDC to transfer
    /// @param newMinUSDCAmount The new minimum amount of USDC to transfer
    function _updateMinUSDCAmount(uint256 newMinUSDCAmount) internal {
        uint256 oldMinUSDCAmount = minUSDCAmount;
        minUSDCAmount = newMinUSDCAmount;

        emit MinUSDCAmountUpdated(oldMinUSDCAmount, newMinUSDCAmount);
    }

    /// @dev Internal function to update the fee percentage
    /// @param newFeePercentage The new fee percentage
    function _updateFeePercentage(uint256 newFeePercentage) internal {
        if (newFeePercentage > MAX_FEE_PERCENTAGE)
            revert ErrorInvalidFeePercentage();

        uint256 oldFeePercentage = feePercentage;
        feePercentage = newFeePercentage;

        emit FeePercentageUpdated(oldFeePercentage, newFeePercentage);
    }

    /// @dev Internal function to update the max fee amount
    /// @param newMaxFeeAmount The new max fee amount
    function _updateMaxFeeAmount(uint256 newMaxFeeAmount) internal {
        uint256 oldMaxFeeAmount = maxFeeAmount;
        maxFeeAmount = newMaxFeeAmount;

        emit MaxFeeAmountUpdated(oldMaxFeeAmount, newMaxFeeAmount);
    }

    /// @dev Internal function to transfer USDC to the L1 ERC20 gateway validium
    /// @param amount The amount of USDC to transfer
    /// @param usxReceiver The encrypted receiver for the USX token
    /// @param usdcReceiver The encrypted receiver for the USDC token
    function _transferUSDC(
        uint256 amount,
        EncryptedReceiver memory usxReceiver,
        EncryptedReceiver memory usdcReceiver
    ) internal {
        // 1. basic validation:
        // - check usxReceiver.keyId is the latest encryption key
        // - check the amount is greater than the minimum amount
        // - the usdcReceiver.keyId will be checked in `IL1ERC20GatewayValidium(erc20Gateway).depositERC20`.
        // - check the usdcReceiver is the expected USDC receiver, if not, revert.
        (uint256 latestKeyId, ) = getLatestEncryptionKey();
        if (usxReceiver.keyId != latestKeyId) {
            revert ErrorInvalidEncryptionKey();
        }
        if (amount < minUSDCAmount) {
            revert ErrorInvalidAmount();
        }
        if (keccak256(abi.encode(usdcReceiver)) != keccak256(abi.encode(expectedUSDCReceiver))) {
            revert ErrorInvalidUSDCReceiver();
        }

        // 2. charge the fee.
        uint256 fee = (amount * feePercentage) / PRECISION;
        if (fee > maxFeeAmount) fee = maxFeeAmount;
        amount -= fee;

        // 3. approve and deposit USDC to the L1 ERC20 gateway validium
        IERC20(USDC).forceApprove(erc20Gateway, amount);
        IL1ERC20GatewayValidium(erc20Gateway).depositERC20(
            USDC,
            usdcReceiver.receiver,
            amount,
            GAS_LIMIT,
            usdcReceiver.keyId
        );

        // 4. increment the nonce
        uint256 nextNonce = nonce + 1;
        nonce = nextNonce;

        // 5. send message to the L1 ERC20 gateway validium
        IScrollMessengerValidium(messenger).sendMessage(
            counterpart,
            0,
            abi.encodeCall(
                PrivateGatewayCloak.confirmDeposit,
                (nextNonce, usxReceiver.receiver, usxReceiver.keyId, amount)
            ),
            GAS_LIMIT
        );

        emit USDCTransferred(
            nextNonce,
            usxReceiver.receiver,
            usxReceiver.keyId,
            amount
        );
    }
}
