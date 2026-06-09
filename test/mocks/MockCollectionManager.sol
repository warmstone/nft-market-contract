// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

contract MockCollectionManager {
    mapping(address => bool) public collectionBlocked;

    function setCollectionBlocked(address collection, bool blocked) external {
        collectionBlocked[collection] = blocked;
    }

    function isCollectionAllowed(address collection) external view returns (bool) {
        return !collectionBlocked[collection];
    }
}
