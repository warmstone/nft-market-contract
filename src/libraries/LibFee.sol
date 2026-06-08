// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

library LibFee {
    uint128 constant BPS_DENOMINATOR = 10000;

    function calcProtocolFee(uint128 price, uint128 bps) internal pure returns (uint256) {
        return uint256(price) * uint256(bps) / BPS_DENOMINATOR;
    }

    function calcRoyalty(uint128 price, uint128 bps) internal pure returns (uint256) {
        return uint256(price) * uint256(bps) / BPS_DENOMINATOR;
    }
}
