// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IScrollL2ERC20Gateway {
    function withdrawERC20(
        address _token,
        address _to,
        uint256 _amount,
        uint256 _gasLimit
    ) external payable;
}
