// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

interface IL2ERC20GatewayValidium {
    /*************************
     * Public View Functions *
     *************************/

    /// @notice The address of the messenger
    /// @return messenger The address of the messenger
    function messenger() external view returns (address);

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice Withdraw of some token to a recipient's account on L1.
    /// @dev Make this function payable to send relayer fee in Ether.
    /// @param token The address of token in L2.
    /// @param to The address of recipient's account on L1.
    /// @param amount The amount of token to transfer.
    /// @param gasLimit Unused, but included for potential forward compatibility considerations.
    function withdrawERC20(
        address token,
        address to,
        uint256 amount,
        uint256 gasLimit
    ) external payable;
}
