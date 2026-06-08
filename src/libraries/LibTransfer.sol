// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

library LibTransfer {
    using SafeERC20 for IERC20;

    error ETHTransferFailed();

    function safeTransferETH(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, ETHTransferFailed());
    }

    function safeTransferERC20(address token, address from, address to, uint256 amount) internal {
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    function safeTransferERC721(address token, address from, address to, uint256 tokenId) internal {
        IERC721(token).safeTransferFrom(from, to, tokenId);
    }
}
