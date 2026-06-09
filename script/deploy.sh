#!/usr/bin/env bash
# deploy.sh — Helper script for deploying the NFT Signed Order DEX
#
# Usage:
#   source .env && ./script/deploy.sh [COMMAND] [OPTIONS]
#
# Commands:
#   dry-sepolia       Simulate Sepolia deployment (no broadcast)
#   deploy-sepolia    Deploy to Sepolia + verify
#   dry-mainnet       Simulate Mainnet deployment (no broadcast)
#   deploy-mainnet    Deploy to Mainnet + verify
#   verify            Verify all deployed contracts on Etherscan
#
# Environment variables required (in .env):
#   PRIVATE_KEY, OWNER_ADDRESS, FEE_RECIPIENT, OPERATOR_ADDRESS
#   SEPOLIA_RPC_URL, MAINNET_RPC_URL, ETHERSCAN_API_KEY
#   WETH_ADDRESS (optional — falls back to chain default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_env() {
    local missing=()
    for var in PRIVATE_KEY OWNER_ADDRESS FEE_RECIPIENT ETHERSCAN_API_KEY; do
        if [ -z "${!var:-}" ]; then
            missing+=("$var")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required environment variables: ${missing[*]}"
        log_error "Make sure you have sourced .env: source .env"
        exit 1
    fi
}

run_forge_script() {
    local rpc_url="$1"
    local broadcast="${2:-false}"
    local verify="${3:-false}"

    local cmd="forge script script/Deploy.s.sol:DeployScript --sig \"run()\" --rpc-url \"$rpc_url\" --private-key \"$PRIVATE_KEY\" -vvvv"

    if [ "$broadcast" = "true" ]; then
        cmd="$cmd --broadcast"
    fi

    if [ "$verify" = "true" ]; then
        cmd="$cmd --verify --etherscan-api-key \"$ETHERSCAN_API_KEY\""
    fi

    log_info "Running: $cmd"
    echo ""
    eval "$cmd"
}

# --- Main ---

COMMAND="${1:-}"
case "$COMMAND" in
    dry-sepolia)
        log_info "Simulating Sepolia deployment..."
        check_env
        RPC="${SEPOLIA_RPC_URL:-}"
        if [ -z "$RPC" ]; then
            log_error "SEPOLIA_RPC_URL is not set"
            exit 1
        fi
        run_forge_script "$RPC" false false
        ;;

    deploy-sepolia)
        log_info "Deploying to Sepolia..."
        check_env
        RPC="${SEPOLIA_RPC_URL:-}"
        if [ -z "$RPC" ]; then
            log_error "SEPOLIA_RPC_URL is not set"
            exit 1
        fi
        log_warn "This will broadcast real transactions to Sepolia!"
        read -rp "Continue? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            log_info "Aborted."
            exit 0
        fi
        run_forge_script "$RPC" true true
        ;;

    dry-mainnet)
        log_info "Simulating Mainnet deployment..."
        check_env
        RPC="${MAINNET_RPC_URL:-}"
        if [ -z "$RPC" ]; then
            log_error "MAINNET_RPC_URL is not set"
            exit 1
        fi
        run_forge_script "$RPC" false false
        ;;

    deploy-mainnet)
        log_info "Deploying to Mainnet..."
        check_env
        RPC="${MAINNET_RPC_URL:-}"
        if [ -z "$RPC" ]; then
            log_error "MAINNET_RPC_URL is not set"
            exit 1
        fi
        log_warn "!!! PRODUCTION DEPLOYMENT !!!"
        log_warn "This will broadcast real transactions to Ethereum Mainnet!"
        log_warn "Deployer: $(cast wallet address "$PRIVATE_KEY" 2>/dev/null || echo "unknown")"
        read -rp "Type 'DEPLOY' to confirm: " confirm
        if [ "$confirm" != "DEPLOY" ]; then
            log_info "Aborted."
            exit 0
        fi
        run_forge_script "$RPC" true true
        ;;

    verify)
        log_info "Verifying contracts..."
        check_env
        RPC="${SEPOLIA_RPC_URL:-}"
        CHAIN_ID="${CHAIN_ID:-11155111}"
        ADDR_FILE="script/deployment-${CHAIN_ID}.json"
        if [ ! -f "$ADDR_FILE" ]; then
            log_error "Deployment file not found: $ADDR_FILE"
            log_error "Run deploy-sepolia or deploy-mainnet first."
            exit 1
        fi
        # Extract addresses and verify each contract
        CM=$(grep -o '"collectionManager": *"[^"]*"' "$ADDR_FILE" | cut -d'"' -f4)
        PM=$(grep -o '"protocolManager": *"[^"]*"' "$ADDR_FILE" | cut -d'"' -f4)
        RM=$(grep -o '"royaltyManager": *"[^"]*"' "$ADDR_FILE" | cut -d'"' -f4)
        EX=$(grep -o '"exchangeImpl": *"[^"]*"' "$ADDR_FILE" | cut -d'"' -f4)
        log_info "Verifying CollectionManager: $CM"
        forge verify-contract "$CM" CollectionManager \
            --etherscan-api-key "$ETHERSCAN_API_KEY" --chain "$CHAIN_ID" || true
        log_info "Verifying ProtocolManager: $PM"
        forge verify-contract "$PM" ProtocolManager \
            --etherscan-api-key "$ETHERSCAN_API_KEY" --chain "$CHAIN_ID" || true
        log_info "Verifying RoyaltyManager: $RM"
        forge verify-contract "$RM" RoyaltyManager \
            --etherscan-api-key "$ETHERSCAN_API_KEY" --chain "$CHAIN_ID" || true
        log_info "Verifying Exchange (impl): $EX"
        forge verify-contract "$EX" Exchange \
            --etherscan-api-key "$ETHERSCAN_API_KEY" --chain "$CHAIN_ID" || true
        ;;

    *)
        echo "NFT Signed Order DEX — Deployment Helper"
        echo ""
        echo "Usage: source .env && ./script/deploy.sh [COMMAND]"
        echo ""
        echo "Commands:"
        echo "  dry-sepolia       Simulate Sepolia deployment"
        echo "  deploy-sepolia    Deploy to Sepolia + verify"
        echo "  dry-mainnet       Simulate Mainnet deployment"
        echo "  deploy-mainnet    Deploy to Mainnet + verify"
        echo "  verify            Re-verify all contracts from deployment JSON"
        echo ""
        echo "Prerequisites:"
        echo "  1. Configure .env (see .env.example or existing .env)"
        echo "  2. source .env"
        echo "  3. Run one of the above commands"
        ;;
esac
