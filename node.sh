#!/bin/bash

# Stop any existing reth processes before starting
echo "Checking for existing reth processes..."

# Find and kill reth processes
if pgrep -f "reth node" > /dev/null; then
    echo "Found running reth processes, stopping them..."
    pkill -f "reth node"
    
    # Wait for processes to terminate gracefully
    sleep 2
    
    # Force kill if still running
    if pgrep -f "reth node" > /dev/null; then
        echo "Force killing remaining processes..."
        pkill -9 -f "reth node"
        sleep 1
    fi
    
    echo "✅ Old processes stopped"
else
    echo "No existing reth processes found"
fi

# Clean up any stale lock files in the data directory
DATA_DIR="${RETH_DATADIR:-./data}"
rm -rf $DATA_DIR
BUILDER_GAS_LIMIT=240000000
BLOCK_TIME=1s
BLOCK_MAX_TRANSACTIONS=30000
BLOCK_INTERVAL_MS=1000
GRAVITY_PIPE_BLOCK_GAS_LIMIT=5000000000
# Default value of pipe block gas limit is 1000000000 => max number of transactions is 16666

./target/release/gravity_node node \
  --datadir ./data \
  --chain ./genesis.json \
  --dev \
  --builder.gaslimit "$BUILDER_GAS_LIMIT" \
  --http \
  --http.api eth,net,web3,txpool,debug \
  --http.port 8545 \
  --http.addr 0.0.0.0 \
  --gravity.pipe-block-gas-limit "$GRAVITY_PIPE_BLOCK_GAS_LIMIT" \
  --enable-gravity-bench \
  --batch-size $BLOCK_MAX_TRANSACTIONS \
  --block-interval-ms $BLOCK_INTERVAL_MS \
  --metrics localhost:9001 \
  --txpool.max-pending-txns 1000000 \
  --txpool.pending-max-count 17592186044415 \
  --txpool.pending-max-size 17592186044415 \
  --txpool.basefee-max-count 17592186044415 \
  --txpool.basefee-max-size 17592186044415 \
  --txpool.queued-max-count 17592186044415 \
  --txpool.queued-max-size 17592186044415 \
  --rpc.max-connections 50000 \
  --rpc.max-subscriptions-per-connection 50000 \
  -vvv
