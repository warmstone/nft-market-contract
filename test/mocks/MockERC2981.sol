// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "../../src/interfaces/IERC2981.sol";

contract MockERC2981 is IERC2981 {
    address public receiver;
    uint96 public bps;

    function setRoyalty(address _receiver, uint96 _bps) external {
        receiver = _receiver;
        bps = _bps;
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (receiver, uint256(salePrice) * bps / 10000);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract MockMaliciousERC2981 is IERC2981 {
    function royaltyInfo(uint256, uint256) external pure returns (address, uint256) {
        revert("malicious");
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract MockNoERC2981 is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}
