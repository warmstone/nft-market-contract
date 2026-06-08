// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {NonceManager} from "../../src/NonceManager.sol";

contract NonceManagerHarness is NonceManager {
    function checkNotCancelled(address maker, uint256 salt) external view {
        _checkNotCancelled(maker, salt);
    }

    function checkCounter(address maker, uint256 counter) external view {
        _checkCounter(maker, counter);
    }

    function checkNotFilled(bytes32 orderHash) external view {
        _checkNotFilled(orderHash);
    }

    function markFilled(bytes32 orderHash) external {
        _markFilled(orderHash);
    }
}
