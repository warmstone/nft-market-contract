// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {NonceManager} from "../../src/NonceManager.sol";
import {NonceManagerHarness} from "../mocks/NonceManagerHarness.sol";

contract NonceManagerTest is Test {
    NonceManagerHarness nm;
    address maker = address(0x1001);
    uint256 salt = 42;

    function setUp() public {
        nm = new NonceManagerHarness();
    }

    // --- Cancel by salt ---

    function test_Cancel_MarksAsCancelled() public {
        vm.prank(maker);
        nm.cancel(salt);
        vm.expectRevert(NonceManager.AlreadyCancelled.selector);
        nm.checkNotCancelled(maker, salt);
    }

    function test_Cancel_EmitsEvent() public {
        vm.prank(maker);
        vm.expectEmit(true, true, false, false);
        emit NonceManager.OrderCancelled(maker, salt);
        nm.cancel(salt);
    }

    function test_Cancel_DuplicateReverts() public {
        vm.startPrank(maker);
        nm.cancel(salt);
        vm.expectRevert(NonceManager.AlreadyCancelled.selector);
        nm.cancel(salt);
        vm.stopPrank();
    }

    function test_Cancel_CannotCancelForAnother() public {
        vm.prank(address(0xBEEF));
        nm.cancel(salt);
        // maker should NOT have cancelledSalt set
        nm.checkNotCancelled(maker, salt);
    }

    function test_Cancel_BCancelDoesNotAffectA() public {
        uint256 saltB = 99;
        address makerB = address(0x2001);

        vm.prank(maker);
        nm.cancel(salt);

        // Maker B's salt=42 should still be valid
        nm.checkNotCancelled(makerB, salt);
        // Maker B's saltB should also be valid
        nm.checkNotCancelled(makerB, saltB);
    }

    // --- Batch cancel ---

    function test_Cancel_Batch() public {
        uint256[] memory salts = new uint256[](3);
        salts[0] = 1;
        salts[1] = 2;
        salts[2] = 3;
        vm.prank(maker);
        nm.cancel(salts);

        vm.expectRevert(NonceManager.AlreadyCancelled.selector);
        nm.checkNotCancelled(maker, 2);
    }

    function test_Cancel_BatchSkipsAlreadyCancelled() public {
        vm.prank(maker);
        nm.cancel(1);

        uint256[] memory salts = new uint256[](2);
        salts[0] = 1;
        salts[1] = 2;
        vm.prank(maker);
        nm.cancel(salts);

        vm.expectRevert(NonceManager.AlreadyCancelled.selector);
        nm.checkNotCancelled(maker, 2);
    }

    // --- Increment counter ---

    function test_IncrementCounter_InvalidatesOldOrders() public {
        vm.prank(maker);
        nm.incrementCounter();
        // counter is now 1, orders with counter=0 should fail
        vm.expectRevert(NonceManager.CounterTooLow.selector);
        nm.checkCounter(maker, 0);
    }

    function test_IncrementCounter_EmitsEvent() public {
        vm.prank(maker);
        vm.expectEmit(true, false, false, false);
        emit NonceManager.CounterIncremented(maker, 1);
        nm.incrementCounter();
    }

    function test_IncrementCounter_NewOrdersWithHigherCounterPass() public {
        vm.prank(maker);
        nm.incrementCounter();
        // counter=1 should pass when minCounter=1
        nm.checkCounter(maker, 1);
    }

    // --- Filled ---

    function test_MarkFilled_PreventsDoubleFill() public {
        bytes32 orderHash = keccak256("order1");
        nm.markFilled(orderHash);
        vm.expectRevert(NonceManager.OrderAlreadyFilled.selector);
        nm.checkNotFilled(orderHash);
    }

    function test_CheckNotFilled_PassesForNewOrder() public view {
        nm.checkNotFilled(keccak256("fresh"));
    }
}
