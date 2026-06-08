// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {LibOrder} from "./libraries/LibOrder.sol";
import {LibFee} from "./libraries/LibFee.sol";
import {LibTransfer} from "./libraries/LibTransfer.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IProtocolManager {
    function protocolFeeBPS() external view returns (uint128);
    function feeRecipient() external view returns (address);
    function paymentTokenAllowed(address) external view returns (bool);
}

interface IRoyaltyManager {
    function getRoyalty(address collection, uint256 tokenId, uint256 price)
        external
        view
        returns (address receiver, uint256 amount);
}

abstract contract PaymentProcessor {
    error InsufficientPayment();
    error FeeExceedsPrice();

    IProtocolManager public protocolManager;
    IRoyaltyManager public royaltyManager;

    struct PaymentResult {
        uint256 ethSpent;
        uint256 protocolFee;
        uint256 royaltyFee;
    }

    function _settlePayment(
        LibOrder.Order calldata order,
        uint128 price,
        address payer,
        address seller,
        uint256 ethAvailable
    ) internal returns (PaymentResult memory result) {
        // 1. 计算手续费、版税
        result.protocolFee = LibFee.calcProtocolFee(price, protocolManager.protocolFeeBPS());
        (address royaltyReceiver, uint256 royaltyFee) =
            royaltyManager.getRoyalty(order.collection, order.tokenId, price);
        result.royaltyFee = royaltyFee;
        require(result.protocolFee + result.royaltyFee <= price, FeeExceedsPrice());

        // 2. 收集付款
        if (order.paymentToken == address(0)) {
            require(ethAvailable >= price, InsufficientPayment());
            result.ethSpent = price;
        } else {
            IERC20(order.paymentToken).transferFrom(payer, address(this), price);
        }

        // 3. 手续费
        if (result.protocolFee > 0) {
            _transferFunds(protocolManager.feeRecipient(), result.protocolFee, order.paymentToken);
        }

        // 4. 版税
        if (result.royaltyFee > 0) {
            _transferFunds(royaltyReceiver, result.royaltyFee, order.paymentToken);
        }

        // 5. 卖家
        uint256 sellerAmount = price - result.protocolFee - result.royaltyFee;
        if (sellerAmount > 0) {
            _transferFunds(seller, sellerAmount, order.paymentToken);
        }
    }

    function _transferFunds(address to, uint256 amount, address paymentToken) private {
        if (paymentToken ==  address(0)) {
            LibTransfer.safeTransferETH(to, amount);
        } else {
            IERC20(paymentToken).transfer(to, amount);
        }
    }
}
