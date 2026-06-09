// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICollectionManager} from "./interfaces/ICollectionManager.sol";

contract CollectionManager is Ownable, ICollectionManager {
    error NotOperator();

    address public operator;
    uint256 public allowlistCount;
    mapping(address => bool) public collectionAllowed;
    mapping(address => bool) public collectionBlocked;

    event CollectionUpdated(address indexed collection, bool allowed, bool blocked);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    constructor(address _owner) Ownable(_owner) {}

    function setOperator(address _operator) external onlyOwner {
        address oldOperator = operator;
        operator = _operator;
        emit OperatorUpdated(oldOperator, _operator);
    }

    function setCollectionAllowed(address collection, bool allowed) external {
        require(msg.sender == operator, NotOperator());
        if (allowed && !collectionAllowed[collection]) {
            allowlistCount++;
        } else if (!allowed && collectionAllowed[collection]) {
            allowlistCount--;
        }
        collectionAllowed[collection] = allowed;
        emit CollectionUpdated(collection, allowed, collectionBlocked[collection]);
    }

    function setCollectionBlocked(address collection, bool blocked) external {
        require(msg.sender == operator, NotOperator());
        collectionBlocked[collection] = blocked;
        emit CollectionUpdated(collection, collectionAllowed[collection], blocked);
    }

    function isCollectionAllowed(address collection) public view returns (bool) {
        if (allowlistCount > 0) {
            return collectionAllowed[collection];
        }
        return !collectionBlocked[collection];
    }
}
