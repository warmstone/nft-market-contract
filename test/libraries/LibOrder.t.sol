// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibOrder} from "src/libraries/LibOrder.sol";

contract LibOrderTest is Test {
    using LibOrder for LibOrder.Order;
}
