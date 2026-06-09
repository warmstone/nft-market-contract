// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OrderValidator} from "./OrderValidator.sol";
import {PaymentProcessor, IProtocolManager, IRoyaltyManager} from "./PaymentProcessor.sol";
import {ICollectionManager} from "./interfaces/ICollectionManager.sol";
import {IExchange} from "./interfaces/IExchange.sol";
import {IERC721Minimal} from "./interfaces/IERC721Minimal.sol";
import {LibOrder} from "./libraries/LibOrder.sol";
import {LibTransfer} from "./libraries/LibTransfer.sol";

contract Exchange is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    OrderValidator,
    PaymentProcessor,
    IExchange
{
    error UnsupportedPaymentToken();
    error InsufficientAllowance();

    uint256 public upgradeScheduled;
    uint256 constant UPGRADE_TIMELOCK = 48 hours;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _protocolManager,
        address _royaltyManager,
        address _collectionManager,
        address _owner
    ) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        protocolManager = IProtocolManager(_protocolManager);
        royaltyManager = IRoyaltyManager(_royaltyManager);
        collectionManager = ICollectionManager(_collectionManager);
    }

    // --- UUPS ---

    function scheduleUpgrade() external onlyOwner {
        upgradeScheduled = block.timestamp;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {
        require(upgradeScheduled > 0, "upgrade not scheduled");
        require(block.timestamp >= upgradeScheduled + UPGRADE_TIMELOCK, "timelock not expired");
    }

    // --- Pause ---

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- Trade execution ---

    function fulfillOrder(LibOrder.Order calldata order, bytes calldata signature)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(order.side == LibOrder.OrderSide.Sell, "wrong side");
        uint256 ethSpent = _fulfillSingle(order, signature, order.price, order.tokenId, msg.value);
        if (msg.value > ethSpent) {
            LibTransfer.safeTransferETH(msg.sender, msg.value - ethSpent);
        }
    }

    function acceptOffer(LibOrder.Order calldata order, bytes calldata signature, uint256 takerTokenId)
        external
        nonReentrant
        whenNotPaused
    {
        require(order.side == LibOrder.OrderSide.Buy, "wrong side");
        _fulfillSingle(order, signature, order.price, takerTokenId, 0);
    }

    function fulfillBatch(LibOrder.Order[] calldata orders, bytes[] calldata signatures)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(orders.length == signatures.length, "length mismatch");
        uint256 totalEthSpent;
        for (uint256 i = 0; i < orders.length; i++) {
            uint256 ethAvailable = msg.value - totalEthSpent;
            totalEthSpent += _fulfillSingle(
                orders[i], signatures[i], orders[i].price, orders[i].tokenId, ethAvailable
            );
        }
        require(totalEthSpent <= msg.value, "overspent");
        if (msg.value > totalEthSpent) {
            LibTransfer.safeTransferETH(msg.sender, msg.value - totalEthSpent);
        }
    }

    // --- Internal ---

    function _fulfillSingle(
        LibOrder.Order calldata order,
        bytes calldata signature,
        uint128 price,
        uint256 takerTokenId,
        uint256 ethAvailable
    ) internal returns (uint256 ethSpent) {
        // 1. Validate
        _validateOrder(order, signature);

        // 2. Payment token whitelist
        if (order.paymentToken != address(0) && address(protocolManager) != address(0)) {
            require(protocolManager.paymentTokenAllowed(order.paymentToken), UnsupportedPaymentToken());
        }

        // 3. Mark filled before external calls
        bytes32 orderHash = LibOrder.hash(order);
        _markFilled(orderHash);

        // 4. Determine roles
        address seller;
        address buyer;
        address payer;
        if (order.side == LibOrder.OrderSide.Sell) {
            seller = order.maker;
            buyer = msg.sender;
            payer = msg.sender;
        } else {
            seller = msg.sender;
            buyer = order.maker;
            payer = order.maker;
        }

        // 5. Check WETH allowance for buy offers
        if (order.paymentToken != address(0) && order.side == LibOrder.OrderSide.Buy) {
            require(
                IERC20(order.paymentToken).allowance(order.maker, address(this)) >= price,
                InsufficientAllowance()
            );
        }

        // 6. Settle payment
        PaymentResult memory result = _settlePayment(order, price, payer, seller, ethAvailable);

        // 7. Transfer NFT
        if (order.side == LibOrder.OrderSide.Sell) {
            IERC721Minimal(order.collection).safeTransferFrom(order.maker, msg.sender, order.tokenId);
        } else {
            IERC721Minimal(order.collection).safeTransferFrom(msg.sender, order.maker, takerTokenId);
        }

        // 8. Emit event
        emit OrderFulfilled(
            orderHash,
            order.salt,
            order.maker,
            msg.sender,
            seller,
            buyer,
            order.side,
            order.kind,
            order.collection,
            takerTokenId,
            order.amount,
            order.paymentToken,
            price,
            result.protocolFee,
            result.royaltyFee
        );

        return result.ethSpent;
    }
}
