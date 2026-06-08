// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibOrder} from "src/libraries/LibOrder.sol";

contract LibOrderTest is Test {
    using LibOrder for LibOrder.Order;

    function _defaultOrder() internal view returns (LibOrder.Order memory) {
        return LibOrder.Order({
            maker: address(0x1001),
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

    function test_Hash_SameOrderSameHash() public {
        LibOrder.Order memory o1 = _defaultOrder();
        LibOrder.Order memory o2 = _defaultOrder();
        assertEq(o1.hash(), o2.hash());
    }

    function test_Hash_DifferentFieldsDifferentHash() public {
        LibOrder.Order memory o1 = _defaultOrder();
        LibOrder.Order memory o2 = _defaultOrder();
        o2.salt = 99999;
        assertTrue(o1.hash() != o2.hash());
    }

    function test_Hash_DifferentMakerDifferentHash() public {
        LibOrder.Order memory o1 = _defaultOrder();
        LibOrder.Order memory o2 = _defaultOrder();
        o2.maker = address(0xBEEF);
        assertTrue(o1.hash() != o2.hash());
    }

    function test_Hash_IncludesAllFields() public {
        // Change any field -> hash changes
        LibOrder.Order memory base = _defaultOrder();
        bytes32 baseHash = base.hash();

        LibOrder.Order memory changed = _defaultOrder();
        changed.price = 2 ether;
        assertTrue(baseHash != changed.hash());
    }

    function test_TypeHash_IsConstant() public {
        bytes32 th1 = LibOrder.ORDER_TYPEHASH;
        bytes32 th2 = LibOrder.ORDER_TYPEHASH;
        assertEq(th1, th2);
    }
}
