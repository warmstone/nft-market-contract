// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "./interfaces/IERC2981.sol";

contract RoyaltyManager is Ownable {
    error RoyaltyTooHigh();

    uint128 public constant MAX_ROYALTY_BPS = 1000;

    mapping(address => uint96) public manualRoyaltyBPS;
    mapping(address => address) public manualReceiver;

    event RoyaltySet(address indexed collection, address indexed receiver, uint96 bps);

    constructor(address _owner) Ownable(_owner) {}

    function getRoyalty(address collection, uint256 tokenId, uint256 price)
        external
        view
        returns (address receiver, uint256 amount)
    {
        if (_supportsERC2981(collection)) {
            try IERC2981(collection).royaltyInfo(tokenId, price) returns (address r, uint256 a) {
                if (r != address(0) && a > 0) {
                    uint256 maxRoyalty = price * MAX_ROYALTY_BPS / 10000;
                    return (r, a > maxRoyalty ? maxRoyalty : a);
                }
            } catch {}
        }

        uint96 bps = manualRoyaltyBPS[collection];
        if (bps == 0) return (address(0), 0);
        return (manualReceiver[collection], price * bps / 10000);
    }

    function setRoyalty(address collection, address receiver, uint96 bps) external onlyOwner {
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        manualRoyaltyBPS[collection] = bps;
        manualReceiver[collection] = receiver;
        emit RoyaltySet(collection, receiver, bps);
    }

    function _supportsERC2981(address collection) private view returns (bool) {
        try IERC165(collection).supportsInterface(0x2a55205a) returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
    }
}
