#!/bin/bash

# test_transactions.sh - Send transactions to reth nodes and verify they can be queried
# Usage: ./test_transactions.sh [num_nodes]

set -e

# Default values
NUM_NODES=${1:-3}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if cast is available
if ! command -v cast &> /dev/null; then
    error "cast command not found. Please install foundry: https://getfoundry.sh/"
    exit 1
fi

# Test account with known private key for testing
# This is a well-known test private key - DO NOT use in production
TEST_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
TEST_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Function to wait for transaction receipt with timeout
wait_for_receipt() {
    local rpc_url=$1
    local tx_hash=$2
    local timeout=$3
    local start_time=$(date +%s)
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            return 1  # Timeout
        fi
        
        local receipt=$(RUST_LOG= cast receipt --rpc-url "$rpc_url" "$tx_hash" --json 2>/dev/null || echo "")
        if [ -n "$receipt" ] && echo "$receipt" | jq -e '.blockNumber != null' >/dev/null 2>&1; then
            return 0  # Transaction mined
        fi
        
        sleep 1
    done
}

# Main test logic
log "Starting transaction tests on $NUM_NODES nodes..."

# Store transaction hashes
declare -a TX_HASHES

# Generate some test addresses to send to
TEST_TO_ADDRESSES=(
    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
    "0x90F79bf6EB2c4f870365E785982E1f101E93b906"
)

# Send transactions from different nodes
log "Sending test transactions..."
failed_count=0

for i in $(seq 0 $((NUM_NODES - 1))); do
    port=$((8545 + i))
    rpc_url="http://127.0.0.1:$port"
    to_address=${TEST_TO_ADDRESSES[$i]}
    value_wei=$((1000000000000000000 + i * 100000000000000000)) # 1 + 0.1*i ETH in wei
    
    log "Sending transaction to node $i (port $port) recipient: $to_address..."
    
    # Send transaction using cast (suppress debug output)
    tx_output=$(RUST_LOG= cast send \
        --rpc-url "$rpc_url" \
        --private-key "$TEST_PRIVATE_KEY" \
        --value "${value_wei}wei" \
        "$to_address" \
        --json 2>&1)
    
    tx_hash=$(echo "$tx_output" | jq -r '.transactionHash' 2>/dev/null || echo "")
    
    if [ -n "$tx_hash" ] && [ "$tx_hash" != "null" ] && [ "$tx_hash" != "" ]; then
        TX_HASHES+=("$tx_hash")
        log "Transaction sent: $tx_hash"
    else
        error "Failed to send transaction to node $i"
        failed_count=$((failed_count + 1))
        
        # Try to get error details
        if echo "$tx_output" | jq -e '.error' >/dev/null 2>&1; then
            error_msg=$(echo "$tx_output" | jq -r '.error' 2>/dev/null || echo "unknown error")
            error "Error details: $error_msg"
        elif [ -n "$tx_output" ]; then
            error "Raw output: $tx_output"
        fi
        
        # Check account balance
        log "Checking account balance..."
        balance=$(RUST_LOG= cast balance --rpc-url "$rpc_url" "$TEST_ADDRESS" 2>/dev/null || echo "unknown")
        log "Account balance: $balance"
    fi
    
    # Small delay between transactions
    sleep 1
done

# Check if any transactions were successfully sent
if [ ${#TX_HASHES[@]} -eq 0 ]; then
    error "No transactions were successfully sent!"
    
    # Check if the test account has balance on any node
    log "Checking test account balance on all nodes..."
    for i in $(seq 0 $((NUM_NODES - 1))); do
        port=$((8545 + i))
        rpc_url="http://127.0.0.1:$port"
        balance=$(RUST_LOG= cast balance --rpc-url "$rpc_url" "$TEST_ADDRESS" 2>/dev/null || echo "error")
        log "Node $i balance: $balance"
    done
    
    exit 1
fi

if [ $failed_count -gt 0 ]; then
    log "Warning: $failed_count out of $NUM_NODES transaction attempts failed"
fi

# Wait for transactions to be mined with timeout
log "Waiting for transactions to be mined (timeout: 60s per transaction)..."
for tx_hash in "${TX_HASHES[@]}"; do
    # Use the first node's RPC for waiting
    rpc_url="http://127.0.0.1:8545"
    
    log "Waiting for transaction $tx_hash to be mined..."
    if wait_for_receipt "$rpc_url" "$tx_hash" 60; then
        log "  ✓ Transaction $tx_hash has been mined"
    else
        error "  ✗ Transaction $tx_hash was not mined within timeout"
    fi
done

# Verify transactions can be queried from all nodes
log "Verifying transactions can be queried by hash from all nodes..."
success_count=0
total_checks=$((${#TX_HASHES[@]} * NUM_NODES))

for tx_hash in "${TX_HASHES[@]}"; do
    log "Checking transaction $tx_hash..."
    
    for i in $(seq 0 $((NUM_NODES - 1))); do
        port=$((8545 + i))
        rpc_url="http://127.0.0.1:$port"
        
        # Get transaction using cast
        tx_data=$(RUST_LOG= cast tx --rpc-url "$rpc_url" "$tx_hash" --json 2>/dev/null || echo "")
        
        if [ -n "$tx_data" ] && echo "$tx_data" | jq -e '.hash' >/dev/null 2>&1; then
            log "  ✓ Transaction found on node $i"
            success_count=$((success_count + 1))
            
            # Also check receipt
            receipt=$(RUST_LOG= cast receipt --rpc-url "$rpc_url" "$tx_hash" --json 2>/dev/null || echo "")
            if [ -n "$receipt" ] && echo "$receipt" | jq -e '.blockNumber' >/dev/null 2>&1; then
                block_num=$(echo "$receipt" | jq -r '.blockNumber')
                log "  ✓ Receipt found on node $i (block $block_num)"
            else
                log "  ✗ Receipt not found on node $i"
            fi
        else
            error "  ✗ Transaction NOT found on node $i"
        fi
    done
done

# Report results
log "Transaction test complete!"
log "Successfully verified $success_count out of $total_checks transaction queries"

if [ $success_count -eq $total_checks ]; then
    log "SUCCESS: All transactions can be queried from all nodes"
    exit 0
else
    error "FAILURE: Some transactions could not be queried"
    exit 1
fi