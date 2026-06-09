// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

contract MockProtocolManager {
    uint128 public protocolFeeBPS = 50;
    address public feeRecipient = address(0xFEE);
    mapping(address => bool) public paymentTokenAllowed;

    function setPaymentTokenAllowed(address token, bool allowed) external {
        paymentTokenAllowed[token] = allowed;
    }
}
