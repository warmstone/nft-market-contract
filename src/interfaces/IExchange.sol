// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {LibOrder} from "../libraries/LibOrder.sol";

interface IExchange {
    event OrderFulfilled(
        bytes32 indexed orderHash,
        uint256 indexed salt,
        address indexed maker,
        address taker,
        address seller,
        address buyer,
        LibOrder.OrderSide side,
        LibOrder.OrderKind kind,
        address collection,
        uint256 tokenId,
        uint256 amount,
        address paymentToken,
        uint128 finalPrice,
        uint256 protocolFee,
        uint256 royaltyFee
    );

    function fulfillOrder(LibOrder.Order calldata order, bytes calldata signature) external payable;

    function acceptOffer(LibOrder.Order calldata order, bytes calldata signature, uint256 takerTokenId) external;

    function fulfillBatch(LibOrder.Order[] calldata orders, bytes[] calldata signatures) external payable;
}
