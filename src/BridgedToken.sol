// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {IMintableBurnable} from "@layerzerolabs/oft-evm/contracts/interfaces/IMintableBurnable.sol";

contract BridgedToken is
    ERC20Upgradeable,
    AccessControlUpgradeable,
    IMintableBurnable
{
    /*************
     * Constants *
     *************/

    /// @notice The role required to mint tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice The role required to burn tokens
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /***************
     * Constructor *
     ***************/

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract
    /// @param admin The address of the admin
    /// @param name The name of the token
    /// @param symbol The symbol of the token
    function initialize(
        address admin,
        string memory name,
        string memory symbol
    ) external initializer {
        __ERC20_init(name, symbol);
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @inheritdoc IMintableBurnable
    function burn(
        address _from,
        uint256 _amount
    ) external onlyRole(BURNER_ROLE) returns (bool success) {
        _burn(_from, _amount);

        return true;
    }

    /// @inheritdoc IMintableBurnable
    function mint(
        address _to,
        uint256 _amount
    ) external onlyRole(MINTER_ROLE) returns (bool success) {
        _mint(_to, _amount);

        return true;
    }
}
