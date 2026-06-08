// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibTransfer} from "../../src/libraries/LibTransfer.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockERC20 is ERC20("Mock20", "M20") {
    constructor() {
        _mint(msg.sender, 1000 ether);
    }
}

contract MockERC721 is ERC721("Mock721", "M721") {
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract LibTransferTest is Test {
    MockERC20 erc20;
    MockERC721 erc721;
    address recipient = address(0xBEEF);

    function setUp() public {
        erc20 = new MockERC20();
        erc721 = new MockERC721();
    }

    function test_SafeTransferETH() public {
        uint256 bal = recipient.balance;
        LibTransfer.safeTransferETH(recipient, 1 ether);
        assertEq(recipient.balance, bal + 1 ether);
    }

    function test_SafeTransferERC20() public {
        erc20.approve(address(this), 100 ether);
        LibTransfer.safeTransferERC20(address(erc20), address(this), recipient, 100 ether);
        assertEq(erc20.balanceOf(recipient), 100 ether);
    }

    function test_SafeTransferERC721() public {
        erc721.mint(address(this), 1);
        LibTransfer.safeTransferERC721(address(erc721), address(this), recipient, 1);
        assertEq(erc721.ownerOf(1), recipient);
    }
}
