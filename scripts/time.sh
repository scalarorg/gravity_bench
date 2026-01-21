#!/bin/bash

# Script to call getTimeInfo() on the Timestamp contract
# Usage: 
#   ./time.sh [RPC_URL]                    - Get current time info
# Example: 
#   ./time.sh http://localhost:8545

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
RPC_URL="${1:-http://localhost:8545}"

TIMESTAMP_CONTRACT="0x0000000000000000000000000000000000002017"
GET_TIME_INFO_SELECTOR="0x6fe8022c"

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

# Call getTimeInfo() function
call_get_time_info() {
    log_info "Calling getTimeInfo() on Timestamp contract..."
    log_info "Contract: $TIMESTAMP_CONTRACT"
    log_info "RPC URL: $RPC_URL"
    echo ""
    
    # Prepare the call data (function selector only, no parameters)
    local call_data="${GET_TIME_INFO_SELECTOR}"
    
    # Make eth_call
    local response=$(rpc_call "eth_call" "[{\"to\":\"$TIMESTAMP_CONTRACT\",\"data\":\"$call_data\"},\"latest\"]")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Extract result
    local result=$(echo "$response" | jq -r '.result')
    
    if [ -z "$result" ] || [ "$result" == "null" ] || [ "$result" == "0x" ]; then
        log_error "No result returned from contract call"
        return 1
    fi
    
    # Decode the result
    # getTimeInfo() returns: (uint64 currentMicroseconds, uint64 currentSeconds, uint256 blockTimestamp)
    # Each uint64 is 32 bytes (64 hex chars) in ABI encoding, uint256 is also 32 bytes
    
    # Extract each value (skip 0x prefix, then take 64 chars for each uint64/uint256)
    local hex_result="${result#0x}"
    
    # currentMicroseconds (offset 0, 64 hex chars = 32 bytes)
    local micro_hex="0x${hex_result:0:64}"
    # currentSeconds (offset 64, 64 hex chars = 32 bytes)
    local sec_hex="0x${hex_result:64:64}"
    # blockTimestamp (offset 128, 64 hex chars = 32 bytes)
    local block_ts_hex="0x${hex_result:128:64}"
    
    # Convert to decimal (remove leading zeros from hex)
    local microseconds=$(hex_to_dec "$micro_hex")
    local seconds=$(hex_to_dec "$sec_hex")
    local block_timestamp=$(hex_to_dec "$block_ts_hex")
    
    # Display results
    echo "=========================================="
    echo "      Timestamp Contract Info"
    echo "=========================================="
    echo ""
    echo -e "${CYAN}Current Microseconds:${NC} $microseconds"
    echo -e "${CYAN}Current Seconds:${NC} $seconds"
    echo -e "${CYAN}Block Timestamp:${NC} $block_timestamp"
    echo ""
    
    # Try to format as readable date
    local readable_date=$(format_microseconds "$microseconds")
    if [ "$readable_date" != "N/A" ]; then
        echo -e "${CYAN}Readable Date:${NC} $readable_date"
        echo ""
    fi
    
    # Calculate difference between contract time and block timestamp
    local diff=$((microseconds / 1000000 - block_timestamp))
    if [ $diff -ne 0 ]; then
        echo -e "${YELLOW}Time Difference:${NC} Contract time is $diff seconds ${diff#-} than block.timestamp"
    else
        echo -e "${GREEN}Time Sync:${NC} Contract time matches block.timestamp"
    fi
    
    echo "=========================================="
    
    return 0
}

# Main execution
main() {
    check_prerequisites
    call_get_time_info
}

# Run main function
main

