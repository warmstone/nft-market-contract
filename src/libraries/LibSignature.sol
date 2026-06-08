// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {LibOrder} from "./LibOrder.sol";

library LibSignature {
    using ECDSA for bytes32;

    error InvalidSignature();

    bytes32 private constant _TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant _NAME_HASH = keccak256(bytes("NFTMarketExchange"));
    bytes32 private constant _VERSION_HASH = keccak256(bytes("1"));

    function domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(abi.encode(_TYPE_HASH, _NAME_HASH, _VERSION_HASH, block.chainid, verifyingContract));
    }

    function getTypedDataHash(LibOrder.Order memory order, address verifyingContract) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(verifyingContract), LibOrder.hash(order)));
    }

    function verify(LibOrder.Order memory order, bytes memory signature, address verifyingContract) public view {
        bytes32 digest = getTypedDataHash(order, verifyingContract);
        address recoveredSigner = ECDSA.recover(digest, signature);
        require(recoveredSigner == order.maker, InvalidSignature());
    }
}
