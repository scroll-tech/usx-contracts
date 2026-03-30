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

import {IUSX} from "../interfaces/IUSX.sol";
import {PrivateGatewayCloak} from "./PrivateGatewayCloak.sol";

/// @title USXRebalancer
/// @notice A contract for rebalancing USX and USDC.
contract USXRebalancer is
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /**********
     * Events *
     **********/

    /// @notice Emitted when the expected USX receiver is updated
    /// @param oldExpectedUSXReceiver The old expected USX receiver
    /// @param newExpectedUSXReceiver The new expected USX receiver
    event ExpectedUSXReceiverUpdated(
        EncryptedReceiver oldExpectedUSXReceiver,
        EncryptedReceiver newExpectedUSXReceiver
    );

    /**********
     * Errors *
     **********/

    /// @dev Thrown when the insufficient USDC balance
    error ErrorInsufficientUSDCBalance();

    /// @dev Thrown when the swap router is not supported
    error ErrorSwapRouterNotSupported();

    /// @dev Thrown when the swap failed
    error ErrorSwapFailed();

    /// @dev Thrown when the insufficient USX amount
    error ErrorInsufficientUSXAmount();

    /// @dev Thrown when the USX receiver is invalid
    error ErrorInvalidUSXReceiver();

    /*************
     * Constants *
     *************/

    /// @notice The role required to rebalance the contract
    bytes32 public constant REBALANCE_ROLE = keccak256("REBALANCE_ROLE");

    /// @notice The gas limit for the deposit operation
    uint256 private constant GAS_LIMIT = 1000000;

    /***********************
     * Immutable Variables *
     ***********************/

    /// @notice The address of the USDC token
    address public immutable USDC;

    /// @notice The address of the USX token
    address public immutable USX;

    /// @notice The address of the ERC20 gateway in scroll
    address public immutable erc20Gateway;

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

    /*********************
     * Storage Variables *
     *********************/

    /// @notice The list of supported swap routers
    EnumerableSet.AddressSet private supportedSwapRouters;

    /// @notice Mapping from swap router to token spender
    mapping(address => address) private spenders;

    /// @notice The expected USX receiver
    EncryptedReceiver public expectedUSXReceiver;

    /***************
     * Constructor *
     ***************/

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev This constructor is used to initialize the immutable variables
    /// @param _USDC The address of the USDC token
    /// @param _USX The address of the USX token
    /// @param _erc20Gateway The address of the ERC20 gateway in scroll
    constructor(address _USDC, address _USX, address _erc20Gateway) {
        _disableInitializers();

        USDC = _USDC;
        USX = _USX;
        erc20Gateway = _erc20Gateway;
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

    /// @notice Receive function for ETH
    receive() external payable {}

    /*************************
     * Public View Functions *
     *************************/

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

    /// @notice Rebalances the contract by minting USX with USDC
    /// @param amountUSDC The amount of USDC to mint
    function rebalanceByMinting(
        uint256 amountUSDC,
        EncryptedReceiver memory usxReceiver
    ) external onlyRole(REBALANCE_ROLE) nonReentrant {
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        if (usdcBalance < amountUSDC) revert ErrorInsufficientUSDCBalance();

        // mint USX with USDC
        uint256 minted = IUSX(USX).balanceOf(address(this));
        IERC20(USDC).forceApprove(USX, amountUSDC);
        IUSX(USX).deposit(amountUSDC);
        minted = IUSX(USX).balanceOf(address(this)) - minted;

        _transferUSX(minted, usxReceiver);
    }

    /// @notice Transfers a token to the encrypted receivers
    /// @param amountUSDC The amount of USDC to swap
    /// @param swapRouter The address of the swap router
    /// @param swapData The data for the swap
    /// @param usxReceiver The encrypted receiver for the USX token
    function rebalanceBySwapping(
        uint256 amountUSDC,
        address swapRouter,
        bytes memory swapData,
        EncryptedReceiver memory usxReceiver
    ) external payable nonReentrant {
        // check if the swap router is supported
        if (!supportedSwapRouters.contains(swapRouter)) {
            revert ErrorSwapRouterNotSupported();
        }

        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        if (usdcBalance < amountUSDC) revert ErrorInsufficientUSDCBalance();

        // swap the token to USX
        uint256 usxBefore = IERC20(USX).balanceOf(address(this));
        IERC20(USDC).forceApprove(spenders[swapRouter], amountUSDC);
        (bool success, ) = swapRouter.call{value: msg.value}(swapData);
        if (!success) revert ErrorSwapFailed();
        uint256 usxAfter = IERC20(USX).balanceOf(address(this));
        uint256 usxAmount = usxAfter - usxBefore;
        IERC20(USDC).forceApprove(spenders[swapRouter], 0); // remove approval

        if (usxAmount < amountUSDC * 10 ** 12) {
            revert ErrorInsufficientUSXAmount();
        }

        _transferUSX(usxAmount, usxReceiver);
    }

    /************************
     * Restricted Functions *
     ************************/

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

    /// @notice Updates the expected USX receiver
    /// @param newExpectedUSXReceiver The new expected USX receiver to update
    function updateExpectedUSXReceiver(
        EncryptedReceiver memory newExpectedUSXReceiver
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EncryptedReceiver memory oldExpectedUSXReceiver = expectedUSXReceiver;
        expectedUSXReceiver = newExpectedUSXReceiver;

        emit ExpectedUSXReceiverUpdated(
            oldExpectedUSXReceiver,
            newExpectedUSXReceiver
        );
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @dev Internal function to transfer USX to the L1 ERC20 gateway validium
    /// @param amountUSX The amount of USX to transfer
    /// @param usxReceiver The encrypted receiver for the USX token
    function _transferUSX(
        uint256 amountUSX,
        EncryptedReceiver memory usxReceiver
    ) internal {
        if (
            keccak256(abi.encode(usxReceiver)) !=
            keccak256(abi.encode(expectedUSXReceiver))
        ) {
            revert ErrorInvalidUSXReceiver();
        }

        // approve and deposit USX to the L1 ERC20 gateway validium
        IERC20(USX).forceApprove(erc20Gateway, amountUSX);
        IL1ERC20GatewayValidium(erc20Gateway).depositERC20(
            USX,
            usxReceiver.receiver,
            amountUSX,
            GAS_LIMIT,
            usxReceiver.keyId
        );
    }
}
