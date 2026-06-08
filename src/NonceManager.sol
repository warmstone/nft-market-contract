// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

abstract contract NonceManager {
    error AlreadyCancelled();
    error OrderAlreadyFilled();
    error CounterTooLow();

    mapping(address => mapping(uint256 => bool)) public cancelledSalt;
    mapping(address => uint256) public minCounter;
    mapping(bytes32 => bool) public filled;

    event OrderCancelled(address indexed maker, uint256 indexed salt);
    event CounterIncremented(address indexed maker, uint256 newCounter);

    function cancel(uint256 salt) external {
        require(!cancelledSalt[msg.sender][salt], AlreadyCancelled());
        cancelledSalt[msg.sender][salt] = true;
        emit OrderCancelled(msg.sender, salt);
    }

    function cancel(uint256[] calldata salts) external {
        uint256 len = salts.length;
        for (uint256 i = 0; i < len; i++) {
            if (!cancelledSalt[msg.sender][salts[i]]) {
                cancelledSalt[msg.sender][salts[i]] = true;
                emit OrderCancelled(msg.sender, salts[i]);
            }
        }
    }

    function incrementCounter() external {
        minCounter[msg.sender]++;
        emit CounterIncremented(msg.sender, minCounter[msg.sender]);
    }

    function _checkNotCancelled(address maker, uint256 salt) internal view {
        require(!cancelledSalt[maker][salt], AlreadyCancelled());
    }

    function _checkCounter(address maker, uint256 counter) internal view {
        require(counter >= minCounter[maker], CounterTooLow());
    }

    function _checkNotFilled(bytes32 orderHash) internal view {
        require(!filled[orderHash], OrderAlreadyFilled());
    }

    function _markFilled(bytes32 orderHash) internal {
        filled[orderHash] = true;
    }
}
