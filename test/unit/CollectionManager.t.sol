// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {CollectionManager} from "../../src/CollectionManager.sol";

contract CollectionManagerTest is Test {
    CollectionManager cm;
    address owner = address(0x1001);
    address operator = address(0x2001);
    address A = address(0xA);
    address B = address(0xB);

    function setUp() public {
        vm.prank(owner);
        cm = new CollectionManager(owner);
    }

    function test_DefaultAllowsAll() public view {
        assertTrue(cm.isCollectionAllowed(A));
        assertTrue(cm.isCollectionAllowed(B));
    }

    function test_AllowlistMode() public {
        vm.prank(owner);
        cm.setOperator(operator);
        vm.prank(operator);
        cm.setCollectionAllowed(A, true);
        assertTrue(cm.isCollectionAllowed(A));
        assertFalse(cm.isCollectionAllowed(B));
    }

    function test_BlocklistMode() public {
        vm.prank(owner);
        cm.setOperator(operator);
        vm.prank(operator);
        cm.setCollectionBlocked(A, true);
        assertFalse(cm.isCollectionAllowed(A));
        assertTrue(cm.isCollectionAllowed(B));
    }

    function test_AllowlistTakesPrecedence() public {
        vm.prank(owner);
        cm.setOperator(operator);
        vm.startPrank(operator);
        cm.setCollectionAllowed(A, true);
        cm.setCollectionBlocked(A, true);
        vm.stopPrank();
        assertTrue(cm.isCollectionAllowed(A));
    }

    function test_Events() public {
        vm.prank(owner);
        cm.setOperator(operator);
        vm.prank(operator);
        vm.expectEmit(true, true, true, false);
        emit CollectionManager.CollectionUpdated(A, true, false);
        cm.setCollectionAllowed(A, true);
    }

    function test_RevertsNonOperator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(CollectionManager.NotOperator.selector);
        cm.setCollectionAllowed(A, true);
    }

    function test_RevertsNonOwnerSetOperator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBEEF)));
        cm.setOperator(operator);
    }
}
