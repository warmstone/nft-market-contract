// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ProtocolManager} from "../../src/ProtocolManager.sol";

contract ProtocolManagerTest is Test {
    ProtocolManager pm;
    address owner = address(0x1001);
    address operator = address(0x2001);
    address feeRecipient = address(0x3001);
    address token = address(0x4001);

    function setUp() public {
        vm.prank(owner);
        pm = new ProtocolManager(owner, feeRecipient);
    }

    // --- Initial state ---
    function test_InitialState() public view {
        assertEq(pm.protocolFeeBPS(), 50);
        assertEq(pm.owner(), owner);
        assertEq(pm.feeRecipient(), feeRecipient);
        assertEq(pm.operator(), address(0));
        assertFalse(pm.paymentTokenAllowed(token));
    }

    // --- setProtocolFeeBPS ---
    function test_SetProtocolFeeBPS() public {
        vm.prank(owner);
        pm.setProtocolFeeBPS(100);
        assertEq(pm.protocolFeeBPS(), 100);
    }

    function test_SetProtocolFeeBPS_RevertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(ProtocolManager.FeeTooHigh.selector);
        pm.setProtocolFeeBPS(501);
    }

    function test_SetProtocolFeeBPS_RevertsNonOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBEEF)));
        pm.setProtocolFeeBPS(100);
    }

    function test_SetProtocolFeeBPS_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, false);
        emit ProtocolManager.ProtocolFeeUpdated(owner, 50, 100);
        pm.setProtocolFeeBPS(100);
    }

    // --- setFeeRecipient ---
    function test_Constructor_RevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ProtocolManager.ZeroAddress.selector);
        new ProtocolManager(owner, address(0));
    }

    function test_SetFeeRecipient() public {
        vm.prank(owner);
        pm.setFeeRecipient(feeRecipient);
        assertEq(pm.feeRecipient(), feeRecipient);
    }

    function test_SetFeeRecipient_RevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ProtocolManager.ZeroAddress.selector);
        pm.setFeeRecipient(address(0));
    }

    // --- setOperator + setPaymentTokenAllowed ---
    function test_PaymentTokenWhitelist() public {
        vm.prank(owner);
        pm.setOperator(operator);

        vm.prank(operator);
        pm.setPaymentTokenAllowed(token, true);
        assertTrue(pm.paymentTokenAllowed(token));

        vm.prank(operator);
        pm.setPaymentTokenAllowed(token, false);
        assertFalse(pm.paymentTokenAllowed(token));
    }

    function test_SetPaymentTokenAllowed_RevertsNonOperator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(ProtocolManager.NotOperator.selector);
        pm.setPaymentTokenAllowed(token, true);
    }

    // --- Events ---
    function test_SetPaymentTokenAllowed_EmitsEvent() public {
        vm.prank(owner);
        pm.setOperator(operator);
        vm.prank(operator);
        vm.expectEmit(true, true, true, false);
        emit ProtocolManager.PaymentTokenUpdated(token, true);
        pm.setPaymentTokenAllowed(token, true);
    }
}
