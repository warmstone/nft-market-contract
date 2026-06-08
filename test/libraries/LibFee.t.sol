// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibFee} from "../../src/libraries/LibFee.sol";

contract LibFeeTest is Test {
    function test_CalcProtocolFee_ZeroBPS() public pure {
        assertEq(LibFee.calcProtocolFee(1 ether, 0), 0);
    }

    function test_CalcProtocolFee_MaxBPS() public pure {
        assertEq(LibFee.calcProtocolFee(1 ether, 10000), 1 ether);
    }

    function test_CalcProtocolFee_DefaultBPS() public pure {
        // 0.5% = 50 BPS. On 1 ETH = 0.005 ETH
        assertEq(LibFee.calcProtocolFee(1 ether, 50), 0.005 ether);
    }

    function test_CalcProtocolFee_RoundingDown() public pure {
        // 1 wei * 50 / 10000 = 0 (integer division)
        assertEq(LibFee.calcProtocolFee(1, 50), 0);
    }

    function test_CalcRoyalty() public pure {
        assertEq(LibFee.calcRoyalty(1 ether, 500), 0.05 ether); // 5%
    }

    function test_CalcRoyalty_ZeroBPS() public pure {
        assertEq(LibFee.calcRoyalty(1 ether, 0), 0);
    }
}
