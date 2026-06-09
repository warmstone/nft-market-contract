// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ProtocolManager is Ownable {
    error FeeTooHigh();
    error NotOperator();
    error ZeroAddress();

    uint128 public constant MAX_PROTOCOL_BPS = 500;

    uint128 public protocolFeeBPS;
    address public feeRecipient;
    address public operator;
    mapping(address => bool) public paymentTokenAllowed;

    event ProtocolFeeUpdated(address indexed setter, uint128 oldBPS, uint128 newBPS);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event PaymentTokenUpdated(address indexed token, bool allowed);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    constructor(address _owner) Ownable(_owner) {
        protocolFeeBPS = 50;
    }

    function setProtocolFeeBPS(uint128 _bps) external onlyOwner {
        if (_bps > MAX_PROTOCOL_BPS) revert FeeTooHigh();
        uint128 oldBPS = protocolFeeBPS;
        protocolFeeBPS = _bps;
        emit ProtocolFeeUpdated(msg.sender, oldBPS, _bps);
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        address oldRecipient = feeRecipient;
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(oldRecipient, _recipient);
    }

    function setOperator(address _operator) external onlyOwner {
        address oldOperator = operator;
        operator = _operator;
        emit OperatorUpdated(oldOperator, _operator);
    }

    function setPaymentTokenAllowed(address _token, bool _allowed) external {
        if (msg.sender != operator) revert NotOperator();
        paymentTokenAllowed[_token] = _allowed;
        emit PaymentTokenUpdated(_token, _allowed);
    }
}
