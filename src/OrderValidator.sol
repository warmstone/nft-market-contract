// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {NonceManager} from "./NonceManager.sol";
import {LibOrder} from "./libraries/LibOrder.sol";
import {LibSignature} from "./libraries/LibSignature.sol";

abstract contract OrderValidator is NonceManager {
    error OrderExpired();
    error OrderNotStarted();
    error WrongTaker();
    error UnsupportedAssetType();

    function domainSeparator() public view virtual returns (bytes32) {
        return LibSignature.domainSeparator(address(this));
    }

    function _validateOrder(LibOrder.Order calldata order, bytes calldata signature) internal view {
        // 1. 校验签名
        LibSignature.verify(order, signature, address(this));

        // 2. 校验 Taker
        if (order.taker != address(0)) {
            require(msg.sender == order.taker, WrongTaker());
        }

        // 3. 校验时间窗口
        if (order.startTime > 0) {
            require(block.timestamp >= order.startTime, OrderNotStarted());
        }
        if (order.endTime > 0) {
            require(block.timestamp <= order.endTime, OrderExpired());
        }

        // 4. 取消状态校验
        _checkNotCancelled(order.maker, order.salt);

        // 5. Counter 校验
        _checkCounter(order.maker, order.counter);

        // 6. 成交校验
        bytes32 orderHash = LibOrder.hash(order);
        _checkNotFilled(orderHash);

        // 7. 资产类型校验
        require(order.assetType == LibOrder.AssetType.ERC721, UnsupportedAssetType());
    }
}
