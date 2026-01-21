#!/bin/bash

# Script to scan blocks for GlobalTimeUpdated events from the Timestamp contract
# Usage: 
#   ./scan_events.sh [RPC_URL]                    - Scan all blocks
#   ./scan_events.sh [RPC_URL] [FROM_BLOCK] [TO_BLOCK] - Scan specific block range
# Example: 
#   ./scan_events.sh http://localhost:8545
#   ./scan_events.sh http://localhost:8545 0 1000

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
FROM_BLOCK="${1:-}"
TO_BLOCK="${2:-}"
RPC_URL="${3:-http://localhost:8545}"

TIMESTAMP_CONTRACT="0x0000000000000000000000000000000000002017"
GLOBAL_TIME_UPDATED_TOPIC="0x6cc05721af7c15004e1eaab31fb461549b56c41e7f7c25aea69d87abed358ef2"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed. Please install curl."
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed. Please install jq."
        exit 1
    fi
    
    if ! command -v bc &> /dev/null; then
        log_error "bc is required but not installed. Please install bc."
        exit 1
    fi
}

# Make JSON-RPC call
rpc_call() {
    local method="$1"
    local params="$2"
    local id="${3:-1}"
    
    local response=$(curl -s -X POST "$RPC_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":$id}" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log_error "Failed to connect to RPC endpoint: $RPC_URL"
        return 1
    fi
    
    # Check for RPC error
    local error=$(echo "$response" | jq -r '.error // empty')
    if [ -n "$error" ] && [ "$error" != "null" ]; then
        log_error "RPC error: $(echo "$response" | jq -r '.error.message')"
        return 1
    fi
    
    echo "$response"
}

# Convert hex to decimal
hex_to_dec() {
    local hex="$1"
    if [ -z "$hex" ] || [ "$hex" == "null" ]; then
        echo "0"
        return
    fi
    # Remove 0x prefix if present
    hex="${hex#0x}"
    # Handle empty string after removing 0x
    if [ -z "$hex" ]; then
        echo "0"
        return
    fi
    # Convert to uppercase for bc
    hex=$(echo "$hex" | tr '[:lower:]' '[:upper:]')
    # Remove leading zeros for bc, but keep at least one digit
    hex=$(echo "$hex" | sed 's/^0*\([0-9A-F]\)/\1/')
    if [ -z "$hex" ]; then
        echo "0"
        return
    fi
    local result=$(echo "ibase=16; $hex" | bc 2>/dev/null)
    if [ -z "$result" ]; then
        echo "0"
    else
        echo "$result"
    fi
}

# Get latest block number
get_latest_block_number() {
    local response=$(rpc_call "eth_blockNumber" "[]")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    local hex_block=$(echo "$response" | jq -r '.result')
    if [ -z "$hex_block" ] || [ "$hex_block" == "null" ]; then
        return 1
    fi
    
    hex_to_dec "$hex_block"
}

# Convert microseconds to readable date (if date command supports it)
format_microseconds() {
    local microseconds="$1"
    local seconds=$((microseconds / 1000000))
    
    if date -r "$seconds" &> /dev/null 2>&1; then
        # macOS date command
        date -r "$seconds" "+%Y-%m-%d %H:%M:%S UTC"
    elif date -d "@$seconds" &> /dev/null 2>&1; then
        # Linux date command
        date -d "@$seconds" "+%Y-%m-%d %H:%M:%S UTC"
    else
        echo "N/A"
    fi
}

# Scan blocks for GlobalTimeUpdated events
scan_global_time_events() {
    log_info "Scanning blocks for GlobalTimeUpdated events..."
    log_info "Contract: $TIMESTAMP_CONTRACT"
    log_info "RPC URL: $RPC_URL"
    echo ""
    
    # Get block range
    local latest_block=$(get_latest_block_number)
    if [ $? -ne 0 ] || [ -z "$latest_block" ]; then
        log_error "Failed to get latest block number"
        return 1
    fi
    
    local from_block="${FROM_BLOCK:-0}"
    local to_block="${TO_BLOCK:-$latest_block}"
    
    # Convert to hex if needed
    if [[ ! "$from_block" =~ ^0x ]]; then
        from_block=$(printf "0x%x" "$from_block")
    fi
    if [[ ! "$to_block" =~ ^0x ]]; then
        to_block=$(printf "0x%x" "$to_block")
    fi
    
    log_info "Scanning from block $from_block to $to_block"
    echo ""
    
    # Prepare filter for eth_getLogs
    # Event signature: GlobalTimeUpdated(address indexed proposer, uint64 oldTimestamp, uint64 newTimestamp, bool isNilBlock)
    # topics[0] = event signature
    # topics[1] = proposer (indexed address)
    # data = oldTimestamp (32 bytes) + newTimestamp (32 bytes) + isNilBlock (32 bytes)
    
    local filter_json="{\"fromBlock\":\"$from_block\",\"toBlock\":\"$to_block\",\"address\":\"$TIMESTAMP_CONTRACT\",\"topics\":[[\"$GLOBAL_TIME_UPDATED_TOPIC\"]]}"
    
    # Make eth_getLogs call
    local response=$(rpc_call "eth_getLogs" "[$filter_json]")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Extract logs array
    local logs=$(echo "$response" | jq -r '.result')
    
    if [ -z "$logs" ] || [ "$logs" == "null" ] || [ "$logs" == "[]" ]; then
        log_info "No GlobalTimeUpdated events found in the specified block range"
        return 0
    fi
    
    # Count events
    local event_count=$(echo "$logs" | jq 'length')
    log_success "Found $event_count GlobalTimeUpdated event(s)"
    echo ""
    
    # Parse and display each event
    echo "=========================================="
    echo "      GlobalTimeUpdated Events"
    echo "=========================================="
    echo ""
    
    # Process each log
    local idx=0
    while [ $idx -lt $event_count ]; do
        local log=$(echo "$logs" | jq -r ".[$idx]")
        
        # Extract event data
        local block_number=$(echo "$log" | jq -r '.blockNumber')
        local block_num_dec=$(hex_to_dec "$block_number")
        local tx_hash=$(echo "$log" | jq -r '.transactionHash')
        local log_index=$(echo "$log" | jq -r '.logIndex')
        local topics=$(echo "$log" | jq -r '.topics')
        local data=$(echo "$log" | jq -r '.data')
        
        # Parse topics
        # topics[0] = event signature (we already filtered by this)
        # topics[1] = proposer address (indexed)
        local proposer=$(echo "$topics" | jq -r '.[1]')
        if [ -z "$proposer" ] || [ "$proposer" == "null" ]; then
            proposer="0x0000000000000000000000000000000000000000"
        else
            # Convert proposer from 32-byte hex to address (last 40 chars = 20 bytes)
            proposer="0x${proposer: -40}"
        fi
        
        # Parse data
        # data = oldTimestamp (64 hex chars) + newTimestamp (64 hex chars) + isNilBlock (64 hex chars)
        local hex_data="${data#0x}"
        
        # Validate data length (should be 192 hex chars = 3 * 64)
        local data_len=${#hex_data}
        if [ "$data_len" -lt 192 ]; then
            log_error "Invalid event data length: expected 192 hex chars, got $data_len"
            idx=$((idx + 1))
            continue
        fi
        
        # oldTimestamp (first 64 chars, but it's uint64 so we need to extract the actual value)
        # In ABI encoding, uint64 is padded to 32 bytes (64 hex chars)
        local old_timestamp_hex="0x${hex_data:0:64}"
        local old_timestamp=$(hex_to_dec "$old_timestamp_hex")
        
        # newTimestamp (next 64 chars)
        local new_timestamp_hex="0x${hex_data:64:64}"
        local new_timestamp=$(hex_to_dec "$new_timestamp_hex")
        
        # isNilBlock (last 64 chars, but only the last byte matters)
        local is_nil_hex="0x${hex_data:128:64}"
        local is_nil_dec=$(hex_to_dec "$is_nil_hex")
        local is_nil_block="false"
        if [ "$is_nil_dec" != "0" ]; then
            is_nil_block="true"
        fi
        
        # Calculate time difference
        local time_diff=$((new_timestamp - old_timestamp))
        local time_diff_sec=$((time_diff / 1000000))
        
        # Format timestamps
        local old_date=$(format_microseconds "$old_timestamp")
        local new_date=$(format_microseconds "$new_timestamp")
        
        # Display event
        echo -e "${CYAN}Event #$((idx + 1))${NC}"
        echo -e "  ${BLUE}Block Number:${NC} $block_num_dec ($block_number)"
        echo -e "  ${BLUE}Transaction:${NC} $tx_hash"
        echo -e "  ${BLUE}Log Index:${NC} $(hex_to_dec "$log_index")"
        echo -e "  ${BLUE}Proposer:${NC} $proposer"
        echo ""
        echo -e "  ${BLUE}Old Timestamp:${NC} $old_timestamp microseconds"
        if [ "$old_date" != "N/A" ]; then
            echo -e "                ${MAGENTA}$old_date${NC}"
        fi
        echo -e "  ${BLUE}New Timestamp:${NC} $new_timestamp microseconds"
        if [ "$new_date" != "N/A" ]; then
            echo -e "                ${MAGENTA}$new_date${NC}"
        fi
        echo ""
        if [ "$time_diff" -gt 0 ]; then
            echo -e "  ${GREEN}Time Advanced:${NC} +$time_diff microseconds (+$time_diff_sec seconds)"
        elif [ "$time_diff" -eq 0 ]; then
            echo -e "  ${YELLOW}Time Unchanged:${NC} No time advancement"
        else
            echo -e "  ${RED}Time Regression:${NC} $time_diff microseconds (should not happen!)"
        fi
        echo -e "  ${BLUE}Is NIL Block:${NC} $is_nil_block"
        echo ""
        
        if [ $idx -lt $((event_count - 1)) ]; then
            echo "  ----------------------------------------"
            echo ""
        fi
        
        idx=$((idx + 1))
    done
    
    echo "=========================================="
    echo ""
    log_success "Scanned $event_count event(s) from block $(hex_to_dec "$from_block") to block $(hex_to_dec "$to_block")"
    
    return 0
}

# Main execution
main() {
    check_prerequisites
    scan_global_time_events
}

# Run main function
main

