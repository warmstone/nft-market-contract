// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface ICollectionManager {
    function isCollectionAllowed(address collection) external view returns (bool);
}
