// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IERC2981 is IERC165 {
    function royaltyInfo(uint256 tokenId, uint256 salPrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
}
