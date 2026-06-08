// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibOrder} from "../../src/libraries/LibOrder.sol";
import {LibSignature} from "../../src/libraries/LibSignature.sol";

contract LibSignatureTest is Test {
    uint256 constant SIGNER_KEY = 0xabc123;
    address internal signer;

    function setUp() public {
        signer = vm.addr(SIGNER_KEY);
    }

    function _signOrder(LibOrder.Order memory order, uint256 key) internal view returns (bytes memory) {
        bytes32 digest = LibSignature.getTypedDataHash(order, address(this));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_Verify_ValidSignature() public view {
        LibOrder.Order memory order = _defaultOrder();
        order.maker = signer;
        bytes memory sig = _signOrder(order, SIGNER_KEY);
        LibSignature.verify(order, sig, address(this));
    }

    function test_Verify_InvalidSignatureReverts() public {
        LibOrder.Order memory order = _defaultOrder();
        order.maker = signer;
        bytes memory sig = _signOrder(order, SIGNER_KEY);
        order.price = 999; // Tampered order
        vm.expectRevert(LibSignature.InvalidSignature.selector);
        LibSignature.verify(order, sig, address(this));
    }

    function test_Verify_WrongSignerReverts() public {
        LibOrder.Order memory order = _defaultOrder();
        order.maker = signer;
        bytes memory sig = _signOrder(order, SIGNER_KEY);
        order.maker = address(0xBEEF);
        vm.expectRevert(LibSignature.InvalidSignature.selector);
        LibSignature.verify(order, sig, address(this));
    }

    function test_Verify_HighSValueReverts() public {
        LibOrder.Order memory order = _defaultOrder();
        order.maker = signer;
        bytes32 digest = LibSignature.getTypedDataHash(order, address(this));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        uint256 highS = uint256(s);
        if (highS < 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            highS = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - highS + 1;
        }
        bytes memory sig = abi.encodePacked(r, bytes32(highS), v);
        vm.expectRevert();
        LibSignature.verify(order, sig, address(this));
    }

    function test_DomainSeparator_IncludesChainId() public view {
        bytes32 ds1 = LibSignature.domainSeparator(address(this));
        bytes32 ds2 = LibSignature.domainSeparator(address(this));
        assertEq(ds1, ds2);
    }

    function _defaultOrder() internal view returns (LibOrder.Order memory) {
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
}
