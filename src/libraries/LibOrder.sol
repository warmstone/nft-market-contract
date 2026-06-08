// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

library LibOrder {
    // 买单、卖单
    enum OrderSide {
        Sell,
        Buy
    }
    // 资产类型
    enum AssetType {
        ERC721,
        ERC1155
    }

    enum OrderKind {
        FixedPrice,
        DutchAuction,
        CollectionBid,
        TraitBid,
        Bundle
    }
    // 订单结构体类型签名
    bytes32 constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address taker,uint8 side,uint8 kind,uint8 assetType,address collection,uint256 tokenId,uint256 amount,address paymentToken,uint128 price,uint128 startPrice,uint64 startTime,uint64 endTime,uint256 salt,uint256 counter,bytes32 extra)"
    );

    // 订单结构体
    struct Order {
        // 挂单方
        address maker;
        // 吃单方
        address taker;
        // 买、卖
        OrderSide side;
        // 订单类型
        OrderKind kind;
        // 资产类型
        AssetType assetType;
        // NFT合约地址
        address collection;
        // 目标NFT的tokenID
        uint256 tokenId;
        // ERC1155数量，ERC721固定为1
        uint256 amount;
        // 支付代币地址
        address paymentToken;
        // 固定价(FixedPrice)
        uint128 price;
        // 荷兰拍起拍价
        uint128 startPrice;
        // 订单生效时间
        uint64 startTime;
        // 订单过期时间
        uint64 endTime;
        // 唯一盐值，用于取消单个订单
        uint256 salt;
        // maker 的计数器，用于批量作废
        uint256 counter;
        // 扩展字段
        bytes32 extra;
    }

    function hash(Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.maker,
                order.taker,
                order.side,
                order.kind,
                order.assetType,
                order.collection,
                order.tokenId,
                order.amount,
                order.paymentToken,
                order.price,
                order.startPrice,
                order.startTime,
                order.endTime,
                order.salt,
                order.counter,
                order.extra
            )
        );
    }
}
