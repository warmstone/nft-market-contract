# NFT Market Contract v1 Implementation Plan

**Status**: Approved
**Date**: 2026-06-06
**Source**: `2026-06-05-signed-order-dex-design-v3.md`
**Approach**: Bottom-up, 3 phases. Tests written alongside each phase. v1 must-have scope only.
**Framework**: Foundry (Solidity)

---

## Phase 1: Foundation — Libraries & Interfaces

**Goal**: Establish data model, signing scheme, transfer and fee calculation libraries, plus all external interfaces. No state management or business logic.

### Files (7 files)

Build order within phase: `LibOrder` (no deps) → `LibSignature` (depends on LibOrder.hash) → `LibTransfer`, `LibFee` (no deps). Interfaces can be written any time.

```
contracts/
  libraries/
    LibOrder.sol          # Order struct + orderHash EIP-712 hashing
    LibSignature.sol      # EIP-712 domain + ECDSA signature verification
    LibTransfer.sol       # ETH/ERC20/ERC721 safe transfers
    LibFee.sol            # Fee calculation (protocol fee + royalty)
  interfaces/
    IExchange.sol         # Exchange public API
    IERC2981.sol          # EIP-2981 royalty info (minimal)
    IERC721Minimal.sol    # ERC721 minimal interface
```

### File Details

**LibOrder.sol**
- `Order` struct with all enums: `OrderSide` (Sell, Buy), `AssetType` (ERC721, ERC1155), `OrderKind` (FixedPrice, DutchAuction, CollectionBid, TraitBid, Bundle)
- `ORDER_TYPEHASH` constant
- `hash(Order memory order) internal pure returns (bytes32)` — EIP-712 order hash

**LibSignature.sol**
- EIP-712 domain: name="NFTMarketExchange", version="1"
- `domainSeparator()` — cached to avoid recomputation
- `verify(Order, signature)` — ECDSA recover + signer == maker check
- Custom error: `InvalidSignature()`
- v1 EOA ECDSA only; EIP-1271 branch stubbed (not implemented)

**LibTransfer.sol**
- `safeTransferETH(address to, uint256 amount)`
- `safeTransferERC20(address token, address to, uint256 amount)` — uses OpenZeppelin SafeERC20
- `safeTransferERC721(address token, address from, address to, uint256 tokenId)`

**LibFee.sol**
- `calcProtocolFee(uint128 price, uint128 bps) internal pure returns (uint256)`
- `calcRoyalty(uint128 price, uint128 bps) internal pure returns (uint256)`
- Pure math only, no storage reads

**IExchange.sol**
- Declares: `fulfillOrder`, `acceptOffer`, `fulfillBatch`, `cancel`, `incrementCounter`
- All events: `OrderFulfilled`, `OrderCancelled`, `CounterIncremented`, `ProtocolFeeUpdated`, `FeeRecipientUpdated`, `PaymentTokenUpdated`, `CollectionUpdated`, `OperatorUpdated`

**IERC2981.sol**
- `royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount)`

**IERC721Minimal.sol**
- Minimal set: `safeTransferFrom`, `ownerOf`

### Acceptance Criteria

- [ ] `forge build` passes, no compilation errors
- [ ] `LibOrder.hash()` unit tests: same order produces same hash; different fields produce different hashes
- [ ] `LibSignature.verify()` unit tests: valid signature passes; invalid signature reverts; high-s value reverts; different chainId signature rejects
- [ ] `LibFee` boundary tests: bps=0 yields 0 fee; bps=10000 yields fee==price
- [ ] `LibTransfer` unit tests: ETH/ERC20/ERC721 normal transfers and failure scenarios
- [ ] Gas snapshot: pure library function calls < 500 gas

---

## Phase 2: Core Settlement

**Goal**: Three abstract contracts + Exchange main entry. Complete sell-side and buy-side matchmaking flow.

### Files (4 new files)

```
contracts/
  NonceManager.sol       # Abstract: cancel + replay protection
  OrderValidator.sol     # Abstract: signature + state validation
  PaymentProcessor.sol   # Abstract: fund collection + fee distribution
  Exchange.sol           # UUPS main entry, inherits all three
```

### Build Order & Dependencies

```
NonceManager  <---  OrderValidator  <---  Exchange
                       ^                    ^
                   LibSignature         PaymentProcessor <--- LibTransfer + LibFee
```

NonceManager has no internal deps — write first. OrderValidator reads NonceManager state. PaymentProcessor is independent. Exchange combines all three.

### Contract Details

**NonceManager.sol** (abstract)

| Item | Detail |
|------|--------|
| State | `cancelledSalt[maker][salt]`, `minCounter[maker]`, `filled[orderHash]` |
| External | `cancel(uint256 salt)`, `cancel(uint256[] salts)`, `incrementCounter()` |
| Internal | `_checkNotCancelled(maker, salt)`, `_checkCounter(maker, counter)`, `_checkNotFilled(orderHash)`, `_markFilled(orderHash)` |
| Events | `OrderCancelled(maker, salt)`, `CounterIncremented(maker, newCounter)` |
| Errors | `AlreadyCancelled()`, `OrderAlreadyFilled()`, `CounterTooLow()` |

**OrderValidator.sol** (abstract)

| Item | Detail |
|------|--------|
| Deps | `NonceManager` (reads state), `LibSignature` (verify), `IProtocolManager`/`ICollectionManager` (interface refs) |
| Internal | `_validateOrder(Order, signature)` — executes all 9 validation checks |
| Checks (in order) | 1. `LibSignature.verify` -> signer == maker 2. taker match 3. `block.timestamp` in [startTime, endTime] 4. `_checkNotCancelled` 5. `_checkCounter` 6. `_checkNotFilled` 7. collection validity 8. paymentToken in whitelist |
| Errors | `InvalidSignature()`, `OrderExpired()`, `OrderNotStarted()`, `WrongTaker()`, `CollectionBlocked()`, `UnsupportedPaymentToken()`, `UnsupportedAssetType()` |

**PaymentProcessor.sol** (abstract)

| Item | Detail |
|------|--------|
| Deps | `LibTransfer`, `LibFee`, `IProtocolManager`, `IRoyaltyManager` |
| Internal | `_settlePayment(Order, price, payer, seller, ethAvailable) returns (uint256 ethSpent)` |
| Branch | `paymentToken == address(0)` -> deduct from `msg.value`; `!= address(0)` -> `safeTransferFrom(payer, address(this), price)` |
| Allocation order | Protocol fee -> Royalty -> Seller (checks-effects-interactions) |
| Errors | `InsufficientPayment()`, `InsufficientAllowance()`, `FeeExceedsPrice()`, `ETHTransferFailed()`, `ERC20TransferFailed()` |

**Exchange.sol** (UUPS main entry)

Inheritance chain:
```solidity
contract Exchange is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    NonceManager,
    OrderValidator,
    PaymentProcessor
```

| Item | Detail |
|------|--------|
| State | `IProtocolManager public protocolManager`, `IRoyaltyManager public royaltyManager`, `ICollectionManager public collectionManager` |
| Init | `initialize(protocolManager_, royaltyManager_, collectionManager_, owner_)` |
| External | `fulfillOrder(Order, signature) external payable` — buyer accepts sell order |
| | `acceptOffer(Order, signature, takerTokenId) external` — seller accepts buy offer |
| | `fulfillBatch(Order[], signature[]) external payable` — batch settlement |
| | `cancel(uint256 salt)` / `cancel(uint256[])` / `incrementCounter()` — inherited from NonceManager, exposed directly |
| Modifiers | `nonReentrant` on fulfillOrder/acceptOffer/fulfillBatch |
| | `whenNotPaused` on trade functions (cancel unaffected by pause) |
| Flow | validate -> mark filled -> settle payment -> transfer NFT -> emit event |
| UUPS | `_authorizeUpgrade` onlyOwner |

**Transfer ordering (reentrancy prevention)**:
```
fulfillOrder / acceptOffer:
  1. _validateOrder(order, signature)
  2. filled[orderHash] = true
  3. _settlePayment(...)
  4. IERC721.safeTransferFrom(...)
  5. emit OrderFulfilled(...)
```

**Phase 2 note**: `protocolManager`, `royaltyManager`, `collectionManager` are implemented in Phase 3. During Phase 2 testing, deploy minimal mocks or set to address(0) to skip checks. Exchange's `initialize` accepts these three addresses — no code changes needed when swapping in real contracts in Phase 3.

### Acceptance Criteria

- [ ] `forge build` passes
- [ ] NonceManager tests: cancel then `_checkNotCancelled` reverts; duplicate cancel reverts; incrementCounter invalidates old counter orders; A cancel salt=N does not affect B's salt=N
- [ ] OrderValidator tests: expired/notStarted/wrongTaker/wrongMaker/collectionBlocked/paymentTokenNotWhitelisted each revert
- [ ] PaymentProcessor tests: ETH payment correct; ETH excess refund; ERC20 pulled from payer; protocol fee calculation correct; royalty calculation correct; fee exceeds price reverts
- [ ] Exchange fulfillOrder integration: seller signs -> buyer pays ETH -> NFT transfers to buyer, ETH splits to seller/protocol/royalty -> correct event
- [ ] Exchange acceptOffer integration: buyer signs + approves WETH -> seller calls -> NFT transfers to buyer, WETH splits to seller/protocol/royalty
- [ ] Reentrancy protection: malicious ERC721 onERC721Received callback cannot re-enter fulfillOrder
- [ ] Batch settlement: 2 orders all succeed; any single failure reverts all
- [ ] `forge test --gas-report`: fulfillOrder ~95K, acceptOffer ~90K, cancel ~30K

---

## Phase 3: Configuration Modules + Governance

**Goal**: Three independent config contracts + Exchange UUPS upgrade finalization + Pausable + Timelock. v1 complete.

### Files (3 new contracts + Exchange additions)

```
contracts/
  ProtocolManager.sol      # Ownable non-upgradeable: fee rate + payment whitelist + operator
  RoyaltyManager.sol       # Ownable non-upgradeable: EIP-2981 lookup + fallback
  CollectionManager.sol    # Ownable non-upgradeable: allowlist/blocklist
  Exchange.sol             # Supplement: wire real config contracts, finalize UUPS + Pausable
```

### Contract Details

**ProtocolManager.sol** (Ownable, non-upgradeable)

| Item | Detail |
|------|--------|
| State | `uint128 public protocolFeeBPS = 50` (default 0.5%), `address public feeRecipient`, `address public operator`, `mapping(address => bool) public paymentTokenAllowed` |
| Owner fns | `setProtocolFeeBPS(uint128 bps)` — cap `MAX_PROTOCOL_BPS = 500`, `setFeeRecipient(address)`, `setOperator(address)` |
| Operator fns | `setPaymentTokenAllowed(address token, bool allowed)` |
| Constants | `uint128 public constant MAX_PROTOCOL_BPS = 500` |
| Events | `ProtocolFeeUpdated`, `FeeRecipientUpdated`, `PaymentTokenUpdated`, `OperatorUpdated` |
| Errors | `NotOwner()`, `NotOperator()`, `ZeroAddress()` |

**RoyaltyManager.sol** (Ownable, non-upgradeable)

| Item | Detail |
|------|--------|
| State | `mapping(address => uint96) public manualRoyaltyBPS`, `mapping(address => address) public manualReceiver` |
| Constants | `uint128 public constant MAX_ROYALTY_BPS = 1000` (10%) |
| Core fn | `getRoyalty(collection, tokenId, price) external view returns (address receiver, uint256 amount)` |
| Lookup logic | 1. `ERC165Checker.supportsInterface(collection, 0x2a55205a)` 2. Supported -> `try royaltyInfo` 3. Not supported or exception -> fallback `manualRoyaltyBPS` 4. Royalty cap truncation |
| Admin fn | `setRoyalty(collection, receiver, bps)` — bps must not exceed MAX |
| Errors | `RoyaltyTooHigh()` |

**CollectionManager.sol** (Ownable, non-upgradeable)

| Item | Detail |
|------|--------|
| State | `mapping(address => bool) public collectionAllowed`, `mapping(address => bool) public collectionBlocked` |
| Operator fns | `setCollectionAllowed(address, bool)`, `setCollectionBlocked(address, bool)` |
| Check fn | `isCollectionAllowed(address) external view returns (bool)` — if any address in allowlist -> only allow allowlisted; if allowlist empty -> allow all except blocklisted |
| Events | `CollectionUpdated(collection, allowed, blocked)` |

**Allowlist vs blocklist logic**: If any collection is in the allowlist, only allowlisted collections can trade. If allowlist is empty, all collections can trade except blocklisted ones. This lets the protocol tighten control gradually.

**Exchange Phase 3 additions**:

| Change | Detail |
|--------|--------|
| constructor + initialize | Phase 2 uses mock addresses; Phase 3 deploys real Managers and passes addresses. No Exchange code changes needed — `initialize` already accepts external addresses |
| `_authorizeUpgrade` | onlyOwner; add upgrade timelock (record `upgradeScheduled` timestamp, require `block.timestamp >= scheduledTime + 48 hours`) |
| Pausable | `whenNotPaused` already applied on trade functions. Owner calls `pause()`/`unpause()` from OpenZeppelin PausableUpgradeable |
| Events | Ensure `OrderFulfilled` event `seller`/`buyer` fields are explicit: Sell -> seller=maker, buyer=msg.sender; Buy -> seller=msg.sender, buyer=maker |

### Deployment Order

```
1. ProtocolManager   (standalone deploy, set feeRecipient + operator)
2. RoyaltyManager    (standalone deploy, register known collection royalties)
3. CollectionManager (standalone deploy, set allowlist/blocklist)
4. Exchange          (UUPS proxy deploy, initialize with above three addresses)
```

### Acceptance Criteria

- [ ] `forge build` passes
- [ ] ProtocolManager tests: owner sets fee (above cap reverts), operator manages payment whitelist, non-operator reverts
- [ ] RoyaltyManager tests: EIP-2981 normal query; suppportsInterface unsupported falls back; malicious collection revert does not block; royalty >10% truncated
- [ ] CollectionManager tests: allowlist mode only allows whitelisted; blocklist intercepts; empty allowlist + blocklisted collection blocked
- [ ] Exchange + real Manager integration: end-to-end sell/buy flow, fees and royalties correctly allocated
- [ ] UUPS upgrade test: `upgradeTo` -> new implementation -> storage state preserved; non-owner upgrade reverts
- [ ] Pausable test: paused disables trades; cancel still works when paused
- [ ] `forge test --gas-report` complete output

---

## Phase Overview

```
Phase 1 (Foundation)        Phase 2 (Core Settlement)        Phase 3 (Config + Governance)
───────────────────────    ─────────────────────────────    ────────────────────────────
LibOrder.sol               NonceManager.sol                 ProtocolManager.sol
LibSignature.sol           OrderValidator.sol               RoyaltyManager.sol
LibTransfer.sol            PaymentProcessor.sol             CollectionManager.sol
LibFee.sol                 Exchange.sol                     Exchange additions
IExchange.sol                                                  - UUPS upgrade finalize
IERC2981.sol                                                   - Pausable finalize
IERC721Minimal.sol                                             - Timelock

4 libs + 3 interfaces      3 abstract contracts + 1 entry   3 config contracts + additions
Pure functions, no state   Complete settlement flow          Governance + upgrade
```

### Error Codes Reference

All custom errors used across the project:

```solidity
// Signature
error InvalidSignature();
error InvalidERC1271Signature();  // Reserved for future

// Time
error OrderExpired();
error OrderNotStarted();

// State
error OrderCancelled();
error AlreadyCancelled();
error OrderAlreadyFilled();
error CounterTooLow();

// Taker
error WrongTaker();

// Amount
error InsufficientPayment();
error InsufficientAllowance();
error FeeExceedsPrice();
error InvalidPrice();

// Token
error UnsupportedPaymentToken();
error UnsupportedAssetType();

// Collection
error CollectionBlocked();

// Transfer
error ETHTransferFailed();
error ERC20TransferFailed();

// Permission
error NotOwner();
error NotOperator();
error ZeroAddress();

// Royalty
error RoyaltyTooHigh();
```

### v1 Must-Have Features (from design doc)

- EIP-712 signed fixed-price sell orders
- EIP-712 signed WETH buy offers
- ERC721 settlement
- ETH + WETH payment
- ECDSA signature verification
- salt-based single cancellation + counter bulk invalidation
- protocol fee (0.5% default, capped at 5%)
- EIP-2981 royalty with supportsInterface + try/catch
- collection allowlist/blocklist
- events for Go backend indexing
- Exchange UUPS upgradeable with timelock
- Pausable
- Gas report

### Deferred (not in v1)

- EIP-1271 smart wallet signature verification
- Dutch auction sell orders
- ERC1155 (struct reserved)
- CollectionBid + TraitBid (extra field reserved)
- Bundle order
- English auction
- Lending
