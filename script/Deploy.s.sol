// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollectionManager} from "../src/CollectionManager.sol";
import {ProtocolManager} from "../src/ProtocolManager.sol";
import {RoyaltyManager} from "../src/RoyaltyManager.sol";
import {Exchange} from "../src/Exchange.sol";

/// @title DeployScript
/// @notice Deploy all contracts for the NFT Signed Order DEX to a target network.
///         Uses env vars for configuration to avoid inline chain IDs.
///         Supports Sepolia testnet and Ethereum mainnet.
///
/// ## Required `.env` variables
/// ```
/// PRIVATE_KEY=<deployer private key (with 0x prefix)>
/// OWNER_ADDRESS=<contract owner (typically a multisig)>
/// FEE_RECIPIENT=<protocol fee recipient address>
/// OPERATOR_ADDRESS=<operator for collection/payment whitelist management>
/// ETHERSCAN_API_KEY=<for contract verification>
/// SEPOLIA_RPC_URL=<Sepolia RPC endpoint>
/// MAINNET_RPC_URL=<Mainnet RPC endpoint>
/// WETH_ADDRESS=<WETH token address for the target chain> (optional, auto per chainId)
/// ```
///
/// ## Usage
/// ```bash
/// source .env
///
/// # Sepolia dry-run
/// forge script script/Deploy.s.sol:DeployScript --sig "run()" \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY -vvvv
///
/// # Sepolia deploy + verify
/// forge script script/Deploy.s.sol:DeployScript --sig "run()" \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
///
/// # Mainnet dry-run
/// forge script script/Deploy.s.sol:DeployScript --sig "run()" \
///     --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY -vvvv
///
/// # Mainnet deploy + verify
/// forge script script/Deploy.s.sol:DeployScript --sig "run()" \
///     --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
/// ```
contract DeployScript is Script {
    // --- Struct: deployment configuration ---
    struct DeployConfig {
        address owner;
        address feeRecipient;
        address operator;
        address weth;
    }

    // --- Struct: deployed contract addresses ---
    struct DeployedAddresses {
        address collectionManager;
        address protocolManager;
        address royaltyManager;
        address exchangeImpl;
        address exchangeProxy;
    }

    error UnsupportedChain(uint256 chainId);

    function run() external {
        // 1. Load configuration from environment
        DeployConfig memory config = _loadConfig();

        // 2. Start broadcast — uses key from CLI flags (--private-key, --account, --ledger, etc.)
        //    msg.sender becomes the deployer EOA once broadcast starts.
        vm.startBroadcast();
        address deployer = msg.sender;

        console.log("==============================================");
        console.log("NFT Signed Order DEX -- Deployment");
        console.log("==============================================");
        console.log("Chain ID:     ", block.chainid);
        console.log("Deployer:     ", deployer);
        console.log("Owner:        ", config.owner);
        console.log("Fee Recipient:", config.feeRecipient);
        console.log("Operator:     ", config.operator);
        console.log("WETH:         ", config.weth);
        console.log("==============================================");

        // 3. Deploy
        DeployedAddresses memory addrs = _deployAll(config, deployer);

        vm.stopBroadcast();

        // 4. Log result
        console.log("==============================================");
        console.log("Deployment Complete");
        console.log("==============================================");
        console.log("CollectionManager: ", addrs.collectionManager);
        console.log("ProtocolManager:   ", addrs.protocolManager);
        console.log("RoyaltyManager:    ", addrs.royaltyManager);
        console.log("Exchange (impl):   ", addrs.exchangeImpl);
        console.log("Exchange (proxy):  ", addrs.exchangeProxy);
        console.log("==============================================");
        console.log("");
        console.log("## Verify commands (if --verify was omitted) ##");
        console.log("forge verify-contract", addrs.collectionManager, "CollectionManager --etherscan-api-key $ETHERSCAN_API_KEY --chain", block.chainid);
        console.log("forge verify-contract", addrs.protocolManager,   "ProtocolManager   --etherscan-api-key $ETHERSCAN_API_KEY --chain", block.chainid);
        console.log("forge verify-contract", addrs.royaltyManager,    "RoyaltyManager    --etherscan-api-key $ETHERSCAN_API_KEY --chain", block.chainid);
        console.log("forge verify-contract", addrs.exchangeImpl,      "Exchange          --etherscan-api-key $ETHERSCAN_API_KEY --chain", block.chainid);

        // 5. Output JSON for Go backend consumption
        _writeAddressesJSON(addrs);
    }

    // ===== Configuration =====

    function _loadConfig() internal view returns (DeployConfig memory) {
        return DeployConfig({
            owner:        vm.envAddress("OWNER_ADDRESS"),
            feeRecipient: vm.envAddress("FEE_RECIPIENT"),
            operator:     _envOr("OPERATOR_ADDRESS", vm.envAddress("OWNER_ADDRESS")),
            weth:         _envOr("WETH_ADDRESS", _chainWETH())
        });
    }

    /// @dev Per-chain WETH address defaults
    function _chainWETH() internal view returns (address) {
        if (block.chainid == 1) {
            // Ethereum Mainnet
            return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        } else if (block.chainid == 11155111) {
            // Sepolia Testnet
            return 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        } else if (block.chainid == 17000) {
            // Holesky Testnet
            return 0x94373a4919B3240D86eA41593D5eBa789FEF3848;
        }
        // For any other chain, require explicit WETH_ADDRESS in .env
        revert UnsupportedChain(block.chainid);
    }

    // ===== Core deployment =====

    function _deployAll(DeployConfig memory config, address deployer)
        internal
        returns (DeployedAddresses memory addrs)
    {
        // --- Phase 1: Deploy standalone config modules ---
        // These are NOT upgradeable -- simple Ownable contracts.

        // CollectionManager: manages collection allowlist / blocklist
        addrs.collectionManager = address(new CollectionManager(config.owner));
        console.log("[1/5] CollectionManager deployed:  ", addrs.collectionManager);

        // ProtocolManager: manages fees, fee recipient, payment token whitelist
        addrs.protocolManager = address(new ProtocolManager(config.owner, config.feeRecipient));
        console.log("[2/5] ProtocolManager deployed:    ", addrs.protocolManager);

        // RoyaltyManager: EIP-2981 royalty lookup + manual fallback
        addrs.royaltyManager = address(new RoyaltyManager(config.owner));
        console.log("[3/5] RoyaltyManager deployed:     ", addrs.royaltyManager);

        // --- Phase 2: Deploy Exchange (UUPS upgradeable) ---

        // Deploy the implementation contract
        addrs.exchangeImpl = address(new Exchange());
        console.log("[4/5] Exchange implementation:     ", addrs.exchangeImpl);

        // Deploy ERC1967 proxy pointing to the Exchange implementation
        ERC1967Proxy proxy = new ERC1967Proxy(addrs.exchangeImpl, "");
        addrs.exchangeProxy = address(proxy);
        console.log("[5/5] Exchange proxy deployed:     ", addrs.exchangeProxy);

        // Initialize the proxy -- wires up all three config modules
        Exchange(addrs.exchangeProxy).initialize(
            addrs.protocolManager,
            addrs.royaltyManager,
            addrs.collectionManager,
            config.owner
        );
        console.log("      Exchange proxy initialized");

        // --- Phase 3: Post-deployment configuration ---

        // CollectionManager: set operator (skip if operator == owner, since owner has all powers anyway)
        if (config.operator != config.owner && config.operator != address(0)) {
            CollectionManager(addrs.collectionManager).setOperator(config.operator);
            console.log("      CollectionManager operator set");
        }

        // ProtocolManager: set operator, whitelist WETH, set fee
        // setPaymentTokenAllowed can only be called by the operator, not the owner.
        // Since we are the owner but not yet the operator, we first make ourselves (deployer)
        // the operator, whitelist WETH, set the fee, then transfer operator to the target.
        {
            // Step 1: Make deployer the operator
            ProtocolManager pm = ProtocolManager(addrs.protocolManager);
            pm.setOperator(deployer);
            // Step 2: Whitelist WETH (deployer is now the operator)
            pm.setPaymentTokenAllowed(config.weth, true);
            console.log("      WETH whitelisted as payment token");

            // Step 3: Set protocol fee (default 50 bps = 0.5%, from env var PROTOCOL_FEE_BPS)
            uint256 feeBps = vm.envOr("PROTOCOL_FEE_BPS", uint256(50));
            if (feeBps > 0) {
                pm.setProtocolFeeBPS(uint128(feeBps));
                console.log("      Protocol fee set:", feeBps, "bps");
            }

            // Step 4: Transfer operator to target (if different from deployer/owner)
            if (config.operator != deployer && config.operator != config.owner && config.operator != address(0)) {
                pm.setOperator(config.operator);
                console.log("      ProtocolManager operator transferred");
            }
        }

        console.log("");
    }

    // ===== Output helpers =====

    /// @dev Write deployment addresses to a JSON file for the Go backend.
    ///      Saved to `script/deployment-<chainId>.json`.
    function _writeAddressesJSON(DeployedAddresses memory addrs) internal {
        string memory path = string(
            abi.encodePacked("script/deployment-", vm.toString(block.chainid), ".json")
        );
        string memory json = string(
            abi.encodePacked(
                "{\n",
                '  "chainId": ', vm.toString(block.chainid), ",\n",
                '  "collectionManager": "', vm.toString(addrs.collectionManager), '",\n',
                '  "protocolManager": "', vm.toString(addrs.protocolManager), '",\n',
                '  "royaltyManager": "', vm.toString(addrs.royaltyManager), '",\n',
                '  "exchangeImpl": "', vm.toString(addrs.exchangeImpl), '",\n',
                '  "exchangeProxy": "', vm.toString(addrs.exchangeProxy), '"\n',
                "}\n"
            )
        );
        vm.writeFile(path, json);
        console.log("Addresses written to", path);
    }

    // --- Helper: envOr for address types ---
    // forge-std doesn't provide vm.envOr for address, so we implement it here.
    function _envOr(string memory key, address defaultValue) internal view returns (address) {
        try vm.envAddress(key) returns (address val) {
            return val;
        } catch {
            return defaultValue;
        }
    }
}
