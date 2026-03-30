// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IL1ERC20GatewayValidium} from "../../src/cloak/IL1ERC20GatewayValidium.sol";
import {IL2ERC20GatewayValidium} from "../../src/cloak/IL2ERC20GatewayValidium.sol";
import {IScrollMessengerValidium} from "../../src/cloak/IScrollMessengerValidium.sol";

contract MockScrollMessengerValidium is IScrollMessengerValidium {
    address private _xDomainMessageSender;

    struct Message {
        address target;
        uint256 value;
        bytes message;
        uint256 gasLimit;
        address from;
        uint256 msgValue;
    }

    Message public lastMessage;
    uint256 public messagesSent;

    function setXDomainMessageSender(address sender) external {
        _xDomainMessageSender = sender;
    }

    function xDomainMessageSender() external view returns (address) {
        return _xDomainMessageSender;
    }

    function sendMessage(
        address target,
        uint256 value,
        bytes calldata message,
        uint256 gasLimit
    ) external payable {
        lastMessage = Message({
            target: target,
            value: value,
            message: message,
            gasLimit: gasLimit,
            from: msg.sender,
            msgValue: msg.value
        });
        messagesSent++;
    }
}

contract MockL1ERC20GatewayValidium is IL1ERC20GatewayValidium {
    address public override messenger;

    struct Deposit {
        address token;
        bytes to;
        uint256 amount;
        uint256 gasLimit;
        uint256 keyId;
        uint256 value;
        address from;
    }

    Deposit public lastDeposit;
    uint256 public deposits;

    constructor(address _messenger) {
        messenger = _messenger;
    }

    function setMessenger(address _messenger) external {
        messenger = _messenger;
    }

    function depositERC20(
        address _token,
        bytes memory _to,
        uint256 _amount,
        uint256 _gasLimit,
        uint256 _keyId
    ) external payable {
        // Simulate locking tokens in the gateway before bridging.
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);

        lastDeposit = Deposit({
            token: _token,
            to: _to,
            amount: _amount,
            gasLimit: _gasLimit,
            keyId: _keyId,
            value: msg.value,
            from: msg.sender
        });
        deposits++;
    }
}

contract MockL2ERC20GatewayValidium is IL2ERC20GatewayValidium {
    address public override messenger;

    struct Withdrawal {
        address token;
        address to;
        uint256 amount;
        uint256 gasLimit;
        uint256 value;
        address from;
    }

    Withdrawal public lastWithdrawal;
    uint256 public withdrawals;

    constructor(address _messenger) {
        messenger = _messenger;
    }

    function setMessenger(address _messenger) external {
        messenger = _messenger;
    }

    function withdrawERC20(
        address token,
        address to,
        uint256 amount,
        uint256 gasLimit
    ) external payable {
        // Simulate locking tokens in the L2 gateway before bridging to L1.
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        lastWithdrawal = Withdrawal({
            token: token,
            to: to,
            amount: amount,
            gasLimit: gasLimit,
            value: msg.value,
            from: msg.sender
        });
        withdrawals++;
    }
}

contract MockSwapRouter {
    function swapToUSDC(
        uint256 amountIn,
        address tokenIn,
        address usdc
    ) external payable {
        // For ERC20 swaps, pull the input token from the caller (gateway)
        if (tokenIn != address(0)) {
            IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        }

        // Assumes the router already holds enough USDC balance.
        IERC20(usdc).transfer(msg.sender, amountIn);
    }
}

contract MockSwapRouterReverting {
    function swapToUSDC(
        uint256,
        address,
        address
    ) external payable {
        revert("swap failed");
    }
}
