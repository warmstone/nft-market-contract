// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface IERC721Minimal {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}
