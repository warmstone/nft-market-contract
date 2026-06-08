// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibOrder} from "../../src/libraries/LibOrder.sol";
import {LibSignature} from "../../src/libraries/LibSignature.sol";
import {NonceManager} from "../../src/NonceManager.sol";
import {OrderValidator} from "../../src/OrderValidator.sol";
import {OrderValidatorHarness} from "../mocks/OrderValidatorHarness.sol";

contract OrderValidatorTest is Test {
    OrderValidatorHarness validator;
    uint256 constant SIGNER_KEY = 0xabc123;
    address signer;

    function setUp() public {
        validator = new OrderValidatorHarness();
        signer = vm.addr(SIGNER_KEY);
    }

    function _typedDataHash(LibOrder.Order memory order) internal view returns (bytes32) {
        return LibSignature.getTypedDataHash(order, address(validator));
    }

    function _signOrder(LibOrder.Order memory order) internal view returns (bytes memory) {
        bytes32 digest = _typedDataHash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _validOrder() internal view returns (LibOrder.Order memory) {
        return LibOrder.Order({
            maker: signer,
            taker: address(0),
            side: LibOrder.OrderSide.Sell,
            kind: LibOrder.OrderKind.FixedPrice,
            assetType: LibOrder.AssetType.ERC721,
            collection: address(0x2001),
            tokenId: 42,
            amount: 1,
            paymentToken: address(0),
            price: 1 ether,
            startPrice: 1 ether,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            salt: 12345,
            counter: 0,
            extra: bytes32(0)
        });
    }

    // --- Signature ---

    function test_Validate_ValidOrder() public view {
        LibOrder.Order memory order = _validOrder();
        bytes memory sig = _signOrder(order);
        validator.validateOrder(order, sig);
    }

    function test_Validate_InvalidSignature() public {
        LibOrder.Order memory order = _validOrder();
        bytes memory sig = _signOrder(order);
        order.price = 999;
        vm.expectRevert(LibSignature.InvalidSignature.selector);
        validator.validateOrder(order, sig);
    }

    // --- Time ---

    function test_Validate_Expired() public {
        vm.warp(1000);
        LibOrder.Order memory order = _validOrder();
        order.endTime = 999;
        bytes memory sig = _signOrder(order);
        vm.expectRevert(OrderValidator.OrderExpired.selector);
        validator.validateOrder(order, sig);
    }

    function test_Validate_EndTimeZeroNeverExpires() public view {
        LibOrder.Order memory order = _validOrder();
        order.endTime = 0;
        bytes memory sig = _signOrder(order);
        validator.validateOrder(order, sig);
    }

    function test_Validate_NotStarted() public {
        LibOrder.Order memory order = _validOrder();
        order.startTime = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOrder(order);
        vm.expectRevert(OrderValidator.OrderNotStarted.selector);
        validator.validateOrder(order, sig);
    }

    function test_Validate_StartTimeZeroAlwaysStarted() public view {
        LibOrder.Order memory order = _validOrder();
        order.startTime = 0;
        bytes memory sig = _signOrder(order);
        validator.validateOrder(order, sig);
    }

    // --- Taker ---

    function test_Validate_WrongTaker() public {
        LibOrder.Order memory order = _validOrder();
        order.taker = address(0xBEEF);
        bytes memory sig = _signOrder(order);
        vm.expectRevert(OrderValidator.WrongTaker.selector);
        validator.validateOrder(order, sig);
    }

    function test_Validate_PublicOrderAnyTaker() public view {
        LibOrder.Order memory order = _validOrder();
        order.taker = address(0);
        bytes memory sig = _signOrder(order);
        validator.validateOrder(order, sig);
    }

    // --- Asset type ---

    function test_Validate_UnsupportedAssetType() public {
        LibOrder.Order memory order = _validOrder();
        order.assetType = LibOrder.AssetType.ERC1155;
        bytes memory sig = _signOrder(order);
        vm.expectRevert(OrderValidator.UnsupportedAssetType.selector);
        validator.validateOrder(order, sig);
    }

    // --- Cancelled ---

    function test_Validate_CancelledOrderReverts() public {
        LibOrder.Order memory order = _validOrder();
        bytes memory sig = _signOrder(order);

        vm.prank(signer);
        validator.cancel(order.salt);

        vm.expectRevert(NonceManager.AlreadyCancelled.selector);
        validator.validateOrder(order, sig);
    }

    // --- Counter ---

    function test_Validate_CounterTooLowReverts() public {
        LibOrder.Order memory order = _validOrder();
        bytes memory sig = _signOrder(order);

        vm.prank(signer);
        validator.incrementCounter();

        vm.expectRevert(NonceManager.CounterTooLow.selector);
        validator.validateOrder(order, sig);
    }

    // --- Filled ---

    function test_Validate_AlreadyFilledReverts() public {
        LibOrder.Order memory order = _validOrder();
        bytes memory sig = _signOrder(order);
        bytes32 orderHash = LibOrder.hash(order);

        validator.markFilled(orderHash);

        vm.expectRevert(NonceManager.OrderAlreadyFilled.selector);
        validator.validateOrder(order, sig);
    }

    // --- Unfilled freshness ---

    function test_Validate_CounterOk() public view {
        LibOrder.Order memory order = _validOrder();
        order.counter = 0;
        bytes memory sig = _signOrder(order);
        validator.validateOrder(order, sig);
    }

    // --- Domain separator ---

    function test_DomainSeparator_MatchesLibrary() public view {
        bytes32 ds = validator.domainSeparator();
        bytes32 expected = LibSignature.domainSeparator(address(validator));
        assertEq(ds, expected);
    }
}
