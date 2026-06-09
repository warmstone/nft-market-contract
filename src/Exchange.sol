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

/// @title NFT Signed Order DEX
/// @notice EIP-712 off-chain signed order marketplace for ERC721 NFTs.
///         Makers sign orders off-chain (zero gas), takers submit them on-chain.
///         Supports fixed-price sell orders (ETH) and buy offers (WETH).
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

    /// @notice Timestamp when the next upgrade was scheduled. Must be set via
    ///         scheduleUpgrade() before _authorizeUpgrade will succeed.
    uint256 public upgradeScheduled;

    /// @notice Minimum delay between scheduleUpgrade() and actual upgrade execution.
    uint256 constant UPGRADE_TIMELOCK = 48 hours;

    constructor() {
        _disableInitializers();
    }

    /// @notice One-time initializer called on the proxy. Sets up upgradeable
    ///         components and stores references to the three config modules.
    /// @param _protocolManager ProtocolManager address (fee config, payment whitelist)
    /// @param _royaltyManager  RoyaltyManager address (EIP-2981 lookup + fallback)
    /// @param _collectionManager CollectionManager address (allowlist/blocklist)
    /// @param _owner Initial owner of the Exchange (typically a multisig)
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

    /// @notice Begins the 48-hour upgrade timelock. Only callable by owner.
    ///         After 48 hours, _authorizeUpgrade will accept the upgrade.
    function scheduleUpgrade() external onlyOwner {
        upgradeScheduled = block.timestamp;
    }

    /// @notice UUPS authorization hook. Only owner can upgrade, and only after
    ///         the 48-hour timelock has expired since scheduleUpgrade().
    function _authorizeUpgrade(address) internal override onlyOwner {
        require(upgradeScheduled > 0, "upgrade not scheduled");
        require(block.timestamp >= upgradeScheduled + UPGRADE_TIMELOCK, "timelock not expired");
    }

    // --- Pause ---

    /// @notice Pauses all trade execution. Cancel/incrementCounter remain usable.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses trade execution.
    function unpause() external onlyOwner {
        _unpause();
    }

    // --- Trade execution ---

    /// @notice Accept a maker-signed sell order. Caller pays ETH and receives
    ///         the NFT from the maker. Excess ETH is refunded.
    /// @param order EIP-712 signed order (side must be Sell)
    /// @param signature ECDSA signature from order.maker
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

    /// @notice Accept a maker-signed buy offer. Caller sends the NFT to the maker
    ///         and receives the payment token (typically WETH) in return.
    /// @param order EIP-712 signed order (side must be Buy)
    /// @param signature ECDSA signature from order.maker
    /// @param takerTokenId The token ID the caller is selling to the maker
    function acceptOffer(LibOrder.Order calldata order, bytes calldata signature, uint256 takerTokenId)
        external
        nonReentrant
        whenNotPaused
    {
        require(order.side == LibOrder.OrderSide.Buy, "wrong side");
        _fulfillSingle(order, signature, order.price, takerTokenId, 0);
    }

    /// @notice Batch version of fulfillOrder. Both sell and buy orders can be
    ///         mixed. Excess ETH is refunded. Any single failure reverts all.
    /// @param orders Array of EIP-712 signed orders
    /// @param signatures Matching array of ECDSA signatures
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

    /// @dev Core settlement flow: validate → mark filled → collect funds → transfer NFT → emit event.
    ///      Marking filled before external calls prevents reentrancy.
    /// @param order The signed order to settle
    /// @param signature ECDSA signature
    /// @param price Final settlement price
    /// @param takerTokenId Actual token ID being transferred (order.tokenId for Sell; caller-provided for Buy)
    /// @param ethAvailable ETH forwarded from msg.value (0 for non-ETH payments)
    /// @return ethSpent Amount of ETH consumed (0 for ERC20 payments)
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
