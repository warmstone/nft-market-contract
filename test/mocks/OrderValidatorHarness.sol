// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {LibOrder} from "../../src/libraries/LibOrder.sol";
import {OrderValidator} from "../../src/OrderValidator.sol";

contract OrderValidatorHarness is OrderValidator {
    function validateOrder(LibOrder.Order calldata order, bytes calldata signature) external view {
        _validateOrder(order, signature);
    }

    function markFilled(bytes32 orderHash) external {
        _markFilled(orderHash);
    }
}
