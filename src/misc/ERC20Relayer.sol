// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IScrollL2ERC20Gateway} from "../interfaces/IScrollERC20Bridge.sol";

contract ERC20Relayer is AccessControl {
    using SafeERC20 for IERC20;

    /**********
     * Errors *
     **********/
    error ZeroAddress();

    /**********
     * Events *
     **********/

    /// @notice Emitted when the recipient of the bridged tokens is updated
    /// @param oldRecipient The address of the old recipient
    /// @param newRecipient The address of the new recipient
    event UpdatedRecipient(
        address indexed oldRecipient,
        address indexed newRecipient
    );

    /// @notice Emitted when the token is bridged from L2 to L1
    /// @param token The token address on L2
    /// @param recipient The recipient address on L1
    /// @param amount The amount of the token bridged
    event Bridged(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    /*************
     * Constants *
     *************/

    /// @notice The role required to bridge the token from the L2 to the L1
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /***********************
     * Immutable Variables *
     ***********************/

    /// @notice The address of the Scroll L2 ERC20 gateway
    /// @dev This is immutable because it is set in the constructor
    address public immutable GATEWAY;

    /// @notice The token address on L2
    /// @dev This is immutable because it is set in the constructor
    address public immutable TOKEN;

    /*********************
     * Storage Variables *
     *********************/

    /// @notice The recipient address on L1
    address public recipient;

    /***************
     * Constructor *
     ***************/

    constructor(address _gateway, address _token, address _recipient) {
        GATEWAY = _gateway;
        TOKEN = _token;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        _updateRecipient(_recipient);
    }

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice Bridges the token from L2 to L1
    /// @dev The caller must be granted to the BRIDGE_ROLE
    function bridge() external onlyRole(BRIDGE_ROLE) {
        uint256 amount = IERC20(TOKEN).balanceOf(address(this));
        IERC20(TOKEN).forceApprove(GATEWAY, amount);
        IScrollL2ERC20Gateway(GATEWAY).withdrawERC20(
            TOKEN,
            recipient,
            amount,
            0
        );

        emit Bridged(TOKEN, recipient, amount);
    }

    /************************
     * Restricted Functions *
     ************************/

    /// @notice Updates the recipient of the bridged tokens
    /// @param newRecipient The address of the new recipient
    /// @dev This function is only callable by the DEFAULT_ADMIN_ROLE
    function updateRecipient(
        address newRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateRecipient(newRecipient);
    }

    /// @notice Rescue ERC20 tokens locked up in this contract
    /// @dev This function is only callable by the DEFAULT_ADMIN_ROLE
    function rescueERC20(
        IERC20 tokenContract,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenContract.safeTransfer(to, amount);
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @dev Internal function to update the recipient of the bridged tokens
    /// @param newRecipient The address of the new recipient
    function _updateRecipient(address newRecipient) internal {
        if (newRecipient == address(0)) {
            revert ZeroAddress();
        }
        address oldRecipient = recipient;
        recipient = newRecipient;

        emit UpdatedRecipient(oldRecipient, newRecipient);
    }
}
