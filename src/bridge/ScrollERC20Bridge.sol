// SPDX-License-Identifier: MIT

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IScrollL2ERC20Gateway} from "../interfaces/IScrollERC20Bridge.sol";

contract ScrollERC20Bridge is AccessControl {
    using SafeERC20 for IERC20;

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

    /// @notice Emitted when the token is bridged from the L1 to the L2
    /// @param token The address of the token
    /// @param recipient The address of the recipient
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
    address public immutable gateway;

    /// @notice The address of the token to be bridged
    address public immutable token;

    /*********************
     * Storage Variables *
     *********************/

    /// @notice The address of the recipient of the bridged tokens
    address public recipient;

    /***************
     * Constructor *
     ***************/

    constructor(address _gateway, address _token, address _recipient) {
        gateway = _gateway;
        token = _token;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        _updateRecipient(_recipient);
    }

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice Bridges the token from the L1 to the L2
    /// @dev The caller must have the BRIDGE_ROLE
    function bridge() external onlyRole(BRIDGE_ROLE) {
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).forceApprove(gateway, amount);
        IScrollL2ERC20Gateway(gateway).withdrawERC20(
            token,
            recipient,
            amount,
            0
        );

        emit Bridged(token, recipient, amount);
    }

    /************************
     * Restricted Functions *
     ************************/

    /// @notice Updates the recipient of the bridged tokens
    /// @param newRecipient The address of the new recipient
    function updateRecipient(
        address newRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateRecipient(newRecipient);
    }

    /// @notice Emergency withdraw of the token from the bridge
    /// @dev This function is only callable by the DEFAULT_ADMIN_ROLE
    function withdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(to, amount);
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @dev Internal function to update the recipient of the bridged tokens
    /// @param newRecipient The address of the new recipient
    function _updateRecipient(address newRecipient) internal {
        address oldRecipient = recipient;
        recipient = newRecipient;

        emit UpdatedRecipient(oldRecipient, newRecipient);
    }
}
