// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUSX} from "../../src/interfaces/IUSX.sol";

contract MockUSX is ERC20, IUSX {
    bool private _paused;
    address private _governance;

    constructor() ERC20("USX", "USX") {
        _governance = msg.sender;
    }

    function mintUSX(address to, uint256 amount) external override {
        _mint(to, amount);
    }

    function burnUSX(address from, uint256 amount) external override {
        _burn(from, amount);
    }

    function deposit(uint256 amount) external override {
      _mint(msg.sender, amount * 10**12);
    }

    function claimUSDC() external override {}

    function requestUSDC(uint256 amount) external {}

    function pause() external override {
        _paused = true;
    }

    function unpause() external override {
        _paused = false;
    }

    function paused() external view override returns (bool) {
        return _paused;
    }

    function governance() external view override returns (address) {
        return _governance;
    }

    function updateTotalMatchedWithdrawalAmount() external override {}

    function totalOutstandingWithdrawalAmount()
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function totalMatchedWithdrawalAmount()
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }
}

contract MockUSXSwapRouter {
    function swapToUSX(
        uint256 amountIn,
        address usdc,
        address usx,
        uint256 rate
    ) external payable {
        IERC20(usdc).transferFrom(msg.sender, address(this), amountIn);
        IERC20(usx).transfer(msg.sender, amountIn * rate);
    }
}

