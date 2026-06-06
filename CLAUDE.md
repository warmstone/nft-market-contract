# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

NFT Signed Order DEX — an EIP-712 off-chain signed order marketplace for ERC721 NFTs. Makers sign orders off-chain (zero gas), takers submit them on-chain for settlement. A Go backend maintains the searchable orderbook, metadata, and API; the contract layer handles only trustless operations: signature verification, replay protection, NFT transfer, fund settlement, and royalty distribution.

**Current state**: Design phase. Detailed spec in `2026-06-05-signed-order-dex-design-v3.md`. No contract code written yet.

## Tech Stack

- **Smart contracts**: Solidity, Foundry toolchain (`forge build`, `forge test`, `forge test --gas-report`)
- **Upgrade pattern**: UUPS (OpenZeppelin), `Exchange.sol` as the sole upgradeable contract
- **Libraries**: OpenZeppelin Contracts (OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, ECDSA, SafeERC20, ERC165Checker)

## Commands

```bash
forge build                    # Compile contracts
forge test                     # Run all tests
forge test --gas-report        # Run tests with gas report
forge test --match-test <NAME> # Run a single test
forge coverage                 # Test coverage report
```

## Architecture

Contract module hierarchy (see design doc sections 1 & 2 for full details):

```
Exchange.sol (UUPS, main entry)
  ├── OrderValidator.sol  (abstract: signature + state validation)
  ├── NonceManager.sol    (abstract: cancel + replay protection)
  ├── PaymentProcessor.sol (abstract: ETH/ERC20 settlement + fee/royalty distribution)
  ├── ProtocolManager.sol  (config: fee rate, whitelist, operator role)
  ├── RoyaltyManager.sol   (config: EIP-2981 lookup + fallback)
  └── CollectionManager.sol (config: allowlist/blocklist)

libraries/
  LibOrder.sol      # Order struct + orderHash
  LibSignature.sol  # EIP-712 domain + ECDSA verification
  LibTransfer.sol   # Safe ETH/ERC20/ERC721 transfers
  LibFee.sol        # Fee calculation
```

**v1 recommendation**: `OrderValidator`, `NonceManager`, `PaymentProcessor` as abstract contracts integrated into `Exchange` via inheritance. `ProtocolManager`, `RoyaltyManager`, `CollectionManager` may be independent contracts referenced by `Exchange`.

## Key Design Decisions

- **Payment**: Buy orders use WETH + allowance (standard OpenSea/Blur pattern), not pre-deposited ETH
- **Replay protection**: Three-tier — `cancelledSalt[maker][salt]` for single order cancel, `minCounter[maker]` for bulk invalidation, `filled[orderHash]` for execution state
- **Royalty safety**: Three-layer defense — ERC165 `supportsInterface` check, `try/catch` on `royaltyInfo`, and a `MAX_ROYALTY_BPS` cap (10%)
- **Transfer ordering**: Mark `filled[orderHash] = true` before external calls (`safeTransferFrom`), preventing reentrancy
- **Operator role**: Separate from owner — operator manages collection/payment token whitelists, owner controls fees and upgrades
- **Timelock**: 48-hour timelock on UUPS upgrades gives users an exit window

## v1 Scope

Must deliver: EIP-712 fixed-price sell/buy orders, ERC721, ETH+WETH payments, ECDSA signatures, salt cancel + counter invalidation, protocol fee (0.5%, capped 5%), EIP-2981 royalties, collection allowlist/blocklist, UUPS upgradeable, Pausable, full event set for Go backend indexing.

Deferred: EIP-1271 smart wallet signatures, Dutch auctions, ERC1155, CollectionBid/TraitBid, bundles.
