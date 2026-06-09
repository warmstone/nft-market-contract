// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {RoyaltyManager} from "../../src/RoyaltyManager.sol";
import {MockERC2981, MockMaliciousERC2981, MockNoERC2981} from "../mocks/MockERC2981.sol";

contract RoyaltyManagerTest is Test {
    RoyaltyManager rm;
    address owner = address(0x1001);
    MockERC2981 compliant;
    MockMaliciousERC2981 malicious;
    MockNoERC2981 noRoyalty;

    function setUp() public {
        vm.prank(owner);
        rm = new RoyaltyManager(owner);
        compliant = new MockERC2981();
        malicious = new MockMaliciousERC2981();
        noRoyalty = new MockNoERC2981();
    }

    function test_GetRoyalty_EIP2981() public {
        compliant.setRoyalty(address(0xBEEF), 500);
        (address receiver, uint256 amount) = rm.getRoyalty(address(compliant), 1, 1 ether);
        assertEq(receiver, address(0xBEEF));
        assertEq(amount, 0.05 ether);
    }

    function test_GetRoyalty_CappedAt10Percent() public {
        compliant.setRoyalty(address(0xBEEF), 1500);
        (address receiver, uint256 amount) = rm.getRoyalty(address(compliant), 1, 1 ether);
        assertEq(amount, 0.1 ether);
    }

    function test_GetRoyalty_MaliciousDoesNotBlock() public view {
        (address receiver, uint256 amount) = rm.getRoyalty(address(malicious), 1, 1 ether);
        assertEq(receiver, address(0));
        assertEq(amount, 0);
    }

    function test_GetRoyalty_NoEIP2981Support() public view {
        (address receiver, uint256 amount) = rm.getRoyalty(address(noRoyalty), 1, 1 ether);
        assertEq(receiver, address(0));
        assertEq(amount, 0);
    }

    function test_GetRoyalty_ManualFallback() public {
        vm.prank(owner);
        rm.setRoyalty(address(noRoyalty), address(0xCAFE), 300);
        (address receiver, uint256 amount) = rm.getRoyalty(address(noRoyalty), 1, 1 ether);
        assertEq(receiver, address(0xCAFE));
        assertEq(amount, 0.03 ether);
    }

    function test_SetRoyalty_RevertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(RoyaltyManager.RoyaltyTooHigh.selector);
        rm.setRoyalty(address(noRoyalty), address(0xCAFE), 1001);
    }

    function test_SetRoyalty_RevertsNonOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBEEF)));
        rm.setRoyalty(address(noRoyalty), address(0xCAFE), 100);
    }
}
