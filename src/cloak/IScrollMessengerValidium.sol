// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

interface IScrollMessengerValidium {
    /*************************
     * Public View Functions *
     *************************/

    /// @notice The address of the xDomainMessageSender
    /// @return xDomainMessageSender The address of the xDomainMessageSender
    function xDomainMessageSender() external view returns (address);

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice Send cross chain message from L1 to L2 or L2 to L1.
    /// @param target The address of account who receive the message.
    /// @param value The amount of ether passed when call target contract.
    /// @param message The content of the message.
    /// @param gasLimit Gas limit required to complete the message relay on corresponding chain.
    function sendMessage(
        address target,
        uint256 value,
        bytes calldata message,
        uint256 gasLimit
    ) external payable;
}
