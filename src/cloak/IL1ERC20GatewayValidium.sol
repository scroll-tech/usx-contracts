// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

interface IL1ERC20GatewayValidium {
    /*************************
     * Public View Functions *
     *************************/

    /// @notice The address of the messenger
    /// @return messenger The address of the messenger
    function messenger() external view returns (address);

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice Deposit some token to a recipient's account on L2.
    /// @dev Make this function payable to send relayer fee in Ether.
    /// @param _token The address of token in L1.
    /// @param _to The encrypted address of recipient's account on L2.
    /// @param _amount The amount of token to transfer.
    /// @param _gasLimit Gas limit required to complete the deposit on L2.
    function depositERC20(
        address _token,
        bytes memory _to,
        uint256 _amount,
        uint256 _gasLimit,
        uint256 _keyId
    ) external payable;
}
