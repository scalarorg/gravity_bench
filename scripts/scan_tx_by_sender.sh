#!/bin/bash

# Transaction Scanner by Sender Address
# Scans blocks and lists all transactions from a given sender address
# Usage: ./scan_tx_by_sender.sh <SENDER_ADDRESS> [OPTIONS]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Default configuration
RPC_URL="${RPC_URL:-http://localhost:8545}"
SENDER_ADDRESS="${SENDER_ADDRESS:-}"
START_BLOCK="${START_BLOCK:-0}"
END_BLOCK="${END_BLOCK:-}"
DELAY_MS="${DELAY_MS:-0}"
VERBOSE="${VERBOSE:-false}"
SHOW_RECEIPT="${SHOW_RECEIPT:-false}"
CHECK_NONCE="${CHECK_NONCE:-false}"
RPC_TIMEOUT="${RPC_TIMEOUT:-10}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_tx() {
    echo -e "${CYAN}$1${NC}"
}

log_block() {
    echo -e "${MAGENTA}$1${NC}"
}


# Normalize address (convert to lowercase)
normalize_address() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
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
}

# Make JSON-RPC call
rpc_call() {
    local method="$1"
    local params="$2"
    local id="${3:-1}"
    
    # Use timeout to prevent hanging on slow/unresponsive RPC endpoints
    local response=$(curl -s --max-time "$RPC_TIMEOUT" -X POST "$RPC_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":$id}" 2>/dev/null)
    
    local curl_exit=$?
    
    if [ $curl_exit -eq 28 ] || [ $curl_exit -eq 7 ]; then
        # Timeout or connection error
        [ "$VERBOSE" = "true" ] && log_warning "RPC call timeout or connection error (curl exit: $curl_exit)"
        return 1
    elif [ $curl_exit -ne 0 ]; then
        [ "$VERBOSE" = "true" ] && log_warning "Failed to connect to RPC endpoint: $RPC_URL (curl exit: $curl_exit)"
        return 1
    fi
    
    if [ -z "$response" ]; then
        [ "$VERBOSE" = "true" ] && log_warning "Empty response from RPC endpoint"
        return 1
    fi
    
    local error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$error" ] && [ "$error" != "null" ]; then
        [ "$VERBOSE" = "true" ] && log_warning "RPC error: $(echo "$response" | jq -r '.error.message' 2>/dev/null)"
        return 1
    fi
    
    echo "$response"
}

# Get latest block number
get_latest_block_number() {
    local response=$(rpc_call "eth_blockNumber" "[]")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    local hex_block=$(echo "$response" | jq -r '.result')
    if [ -z "$hex_block" ] || [ "$hex_block" = "null" ]; then
        return 1
    fi
    
    local clean_hex=$(echo "$hex_block" | sed 's/^0x//' | tr '[:lower:]' '[:upper:]')
    
    if command -v bc &> /dev/null; then
        echo "ibase=16; $clean_hex" | bc 2>/dev/null
    else
        echo $((0x$clean_hex)) 2>/dev/null || echo "$hex_block"
    fi
}

# Get block by number (with full transaction details)
get_block_with_txs() {
    local block_number="$1"
    local hex_block=$(printf "0x%x" "$block_number")
    
    local response=$(rpc_call "eth_getBlockByNumber" "[\"$hex_block\", true]")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    local block_data=$(echo "$response" | jq -r '.result')
    if [ "$block_data" = "null" ] || [ -z "$block_data" ]; then
        return 1
    fi
    
    echo "$block_data"
}

# Get transaction receipt by hash
get_transaction_receipt() {
    local tx_hash="$1"
    
    if [ -z "$tx_hash" ] || [ "$tx_hash" = "null" ]; then
        return 1
    fi
    
    local response=$(rpc_call "eth_getTransactionReceipt" "[\"$tx_hash\"]")
    if [ $? -ne 0 ]; then
        return 1
    fi

    local receipt_data=$(echo "$response" | jq -r '.result')
    if [ "$receipt_data" = "null" ] || [ -z "$receipt_data" ]; then
        return 1
    fi
    
    echo "$receipt_data"
}

# Get account nonce at a specific block
get_account_nonce() {
    local address="$1"
    local block_number="$2"
    local hex_block=$(printf "0x%x" "$block_number")
    
    local response=$(rpc_call "eth_getTransactionCount" "[\"$address\", \"$hex_block\"]")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    local nonce_hex=$(echo "$response" | jq -r '.result')
    if [ -z "$nonce_hex" ] || [ "$nonce_hex" = "null" ]; then
        return 1
    fi
    
    hex_to_dec "$nonce_hex"
}

# Convert hex to decimal
hex_to_dec() {
    local hex="$1"
    if [ -z "$hex" ] || [ "$hex" = "null" ]; then
        echo "0"
        return
    fi
    
    local clean_hex=$(echo "$hex" | sed 's/^0x//' | tr '[:lower:]' '[:upper:]')
    
    if command -v bc &> /dev/null; then
        echo "ibase=16; $clean_hex" | bc 2>/dev/null || echo "0"
    else
        echo $((0x$clean_hex)) 2>/dev/null || echo "0"
    fi
}

# Convert Wei to Ether
wei_to_eth() {
    local wei_hex="$1"
    if [ -z "$wei_hex" ] || [ "$wei_hex" = "null" ]; then
        echo "0.0"
        return
    fi
    
    local wei_dec=$(hex_to_dec "$wei_hex")
    if command -v bc &> /dev/null; then
        echo "scale=18; $wei_dec / 1000000000000000000" | bc -l 2>/dev/null || echo "0.0"
    else
        # Fallback calculation (less precise)
        echo "scale=18; $wei_dec / 1000000000000000000" | awk '{printf "%.18f\n", $1}' 2>/dev/null || echo "0.0"
    fi
}

# Convert Unix timestamp to readable format
format_timestamp() {
    local timestamp="$1"
    if command -v date &> /dev/null; then
        date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
        date -r "$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || \
        echo "$timestamp"
    else
        echo "$timestamp"
    fi
}

# Display usage
usage() {
    cat << EOF
Usage: $0 <SENDER_ADDRESS> [OPTIONS]

Scans blocks and lists all transactions from a given sender address.

ARGUMENTS:
    SENDER_ADDRESS           Ethereum address to scan for (required)

OPTIONS:
    -u, --rpc-url URL       RPC endpoint URL (default: http://localhost:8545)
    -s, --start-block NUM   Starting block number (default: 0)
    -e, --end-block NUM     Ending block number (default: latest block)
    -d, --delay MS          Delay between requests in milliseconds (default: 0)
    -t, --timeout SEC       RPC request timeout in seconds (default: 10)
    -r, --show-receipt      Show transaction receipt details (default: false)
    -n, --check-nonce       Check nonce sequence and detect mismatches (default: false)
    -v, --verbose           Verbose output
    -h, --help              Show this help message

ENVIRONMENT VARIABLES:
    RPC_URL                 RPC endpoint URL (default: http://localhost:8545)
    START_BLOCK             Starting block number
    END_BLOCK               Ending block number
    DELAY_MS                Delay between requests in milliseconds (default: 0)
    RPC_TIMEOUT             RPC request timeout in seconds (default: 10)
    SHOW_RECEIPT            Set to 'true' to show transaction receipts (default: false)
    CHECK_NONCE             Set to 'true' to check nonce sequence and detect mismatches (default: false)
    VERBOSE                 Set to 'true' for verbose output

EXAMPLES:
    $0 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb
    $0 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb --rpc-url http://localhost:8545
    $0 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb -s 100 -e 200
    $0 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb --show-receipt -s 0 -e 1000
    $0 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb --check-nonce -s 0 -e 1000
    SENDER_ADDRESS=0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb RPC_URL=http://localhost:8545 $0

EOF
}

# Parse command line arguments
parse_args() {
    # First argument should be sender address if it doesn't start with -
    if [ $# -gt 0 ] && [[ ! "$1" =~ ^- ]]; then
        SENDER_ADDRESS="$1"
        shift
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--rpc-url)
                RPC_URL="$2"
                shift 2
                ;;
            -s|--start-block)
                START_BLOCK="$2"
                shift 2
                ;;
            -e|--end-block)
                END_BLOCK="$2"
                shift 2
                ;;
            -d|--delay)
                DELAY_MS="$2"
                shift 2
                ;;
            -t|--timeout)
                RPC_TIMEOUT="$2"
                shift 2
                ;;
            -r|--show-receipt)
                SHOW_RECEIPT=true
                shift
                ;;
            -n|--check-nonce)
                CHECK_NONCE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Main scanning function
scan_transactions() {
    if [ -z "$SENDER_ADDRESS" ]; then
        log_error "Sender address is required"
        usage
        exit 1
    fi
    
    # Normalize sender address to lowercase for comparison
    SENDER_ADDRESS=$(normalize_address "$SENDER_ADDRESS")
    
    log_info "Starting transaction scan for sender: $SENDER_ADDRESS"
    log_info "RPC URL: $RPC_URL"
    log_info "Start block: $START_BLOCK"
    
    # Get latest block number if not specified
    if [ -z "$END_BLOCK" ]; then
        log_info "Getting latest block number..."
        END_BLOCK=$(get_latest_block_number)
        if [ $? -ne 0 ]; then
            log_error "Failed to get latest block number"
            exit 1
        fi
    fi
    
    log_info "End block: $END_BLOCK"
    log_info "Delay: ${DELAY_MS}ms"
    log_info "RPC timeout: ${RPC_TIMEOUT}s"
    log_info "Show receipt: ${SHOW_RECEIPT}"
    log_info "Check nonce: ${CHECK_NONCE}"
    echo ""
    
    if [ "$START_BLOCK" -gt "$END_BLOCK" ]; then
        log_error "Start block ($START_BLOCK) is greater than end block ($END_BLOCK)"
        exit 1
    fi
    
    local total_blocks=0
    local blocks_with_tx=0
    local total_transactions=0
    local first_tx_block=""
    local last_tx_block=""
    
    # Nonce tracking for debugging
    local expected_nonce=0
    local nonce_gaps=0
    local nonce_out_of_order=0
    local nonce_seen=""  # Track seen nonces to detect duplicates (space-separated list)
    
    # Calculate total blocks to scan
    local total_blocks_to_scan=$((END_BLOCK - START_BLOCK + 1))
    
    # Record start time for progress calculation
    local start_time=$(date +%s)
    
    log_info "Scanning blocks from $START_BLOCK to $END_BLOCK (total: $total_blocks_to_scan blocks)..."
    echo ""
    
    # Scan blocks
    for ((block_num=$START_BLOCK; block_num<=$END_BLOCK; block_num++)); do
        # Add delay between requests (except for first block)
        if [ $block_num -gt $START_BLOCK ] && [ "$DELAY_MS" -gt 0 ]; then
            local sleep_seconds=$(echo "scale=3; $DELAY_MS / 1000" | bc 2>/dev/null)
            if [ -n "$sleep_seconds" ] && [ "$sleep_seconds" != "0" ]; then
                sleep "$sleep_seconds"
            fi
        fi
        
        # Get block info with full transaction details
        local block_data=$(get_block_with_txs "$block_num")
        if [ $? -ne 0 ] || [ -z "$block_data" ] || [ "$block_data" = "null" ]; then
            [ "$VERBOSE" = "true" ] && log_warning "Block $block_num not found or error retrieving"
            continue
        fi
        
        total_blocks=$((total_blocks + 1))
        
        # Calculate and display progress
        local current_block_progress=$((block_num - START_BLOCK + 1))
        local progress_percentage=0
        if [ $total_blocks_to_scan -gt 0 ]; then
            progress_percentage=$(echo "scale=1; $current_block_progress * 100 / $total_blocks_to_scan" | bc 2>/dev/null || echo "0")
        fi
        
        # Show progress every 10 blocks or at start/end
        if [ $((current_block_progress % 10)) -eq 0 ] || [ $current_block_progress -eq 1 ] || [ $block_num -eq $END_BLOCK ]; then
            local current_time=$(date +%s)
            local elapsed_time=$((current_time - start_time))
            local blocks_per_sec=0
            local estimated_remaining=0
            
            if [ $elapsed_time -gt 0 ]; then
                blocks_per_sec=$(echo "scale=2; $current_block_progress / $elapsed_time" | bc 2>/dev/null || echo "0")
            fi
            
            if [ "$blocks_per_sec" != "0" ] && [ "$blocks_per_sec" != "0.00" ]; then
                local remaining_blocks=$((total_blocks_to_scan - current_block_progress))
                estimated_remaining=$(echo "scale=0; $remaining_blocks / $blocks_per_sec" | bc 2>/dev/null || echo "0")
            fi
            
            # Format estimated time
            local estimated_str=""
            if [ $estimated_remaining -gt 0 ]; then
                local hours=$((estimated_remaining / 3600))
                local minutes=$(((estimated_remaining % 3600) / 60))
                local seconds=$((estimated_remaining % 60))
                
                if [ $hours -gt 0 ]; then
                    estimated_str="${hours}h ${minutes}m ${seconds}s"
                elif [ $minutes -gt 0 ]; then
                    estimated_str="${minutes}m ${seconds}s"
                else
                    estimated_str="${seconds}s"
                fi
            fi
            
            # Display progress
            local progress_line="Progress: Block $block_num/$END_BLOCK (${progress_percentage}%)"
            progress_line="${progress_line} | Scanned: $total_blocks | Found: $blocks_with_tx blocks, $total_transactions tx"
            
            if [ "$blocks_per_sec" != "0" ] && [ "$blocks_per_sec" != "0.00" ]; then
                progress_line="${progress_line} | Rate: ${blocks_per_sec} blocks/sec"
            fi
            
            if [ -n "$estimated_str" ]; then
                progress_line="${progress_line} | ETA: ${estimated_str}"
            fi
            
            # Use carriage return to overwrite the same line (for cleaner output)
            if [ "$VERBOSE" != "true" ] && [ $current_block_progress -gt 10 ]; then
                echo -ne "\r\033[K${BLUE}[INFO]${NC} $progress_line"
            else
                log_info "$progress_line"
            fi
        fi
        
        # Get block details
        local block_hash=$(echo "$block_data" | jq -r '.hash')
        local timestamp_hex=$(echo "$block_data" | jq -r '.timestamp')
        local timestamp_dec=$(hex_to_dec "$timestamp_hex")
        local timestamp_str=$(format_timestamp "$timestamp_dec")
        
        # Extract transactions and filter by sender
        local transactions=$(echo "$block_data" | jq -r '.transactions // []')
        local tx_count=$(echo "$transactions" | jq 'length')
        
        local found_in_block=false
        
        # Process each transaction
        for ((i=0; i<tx_count; i++)); do
            local tx=$(echo "$transactions" | jq -r ".[$i]")
            local tx_from=$(echo "$tx" | jq -r '.from // empty' | tr '[:upper:]' '[:lower:]')
            
            # Check if transaction is from the sender address
            if [ "$tx_from" = "$SENDER_ADDRESS" ]; then
                if [ "$found_in_block" = false ]; then
                    found_in_block=true
                    blocks_with_tx=$((blocks_with_tx + 1))
                    
                    if [ -z "$first_tx_block" ]; then
                        first_tx_block=$block_num
                    fi
                    last_tx_block=$block_num
                    
                    # Add newline before displaying transactions to avoid overwriting progress line
                    if [ "$VERBOSE" != "true" ] && [ $total_blocks_to_scan -gt 10 ]; then
                        echo ""
                    fi
                    
                    # Display block header
                    log_block "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    log_block "Block #$block_num | $timestamp_str | Hash: $block_hash"
                    log_block "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                fi
                
                # Extract transaction details
                local tx_hash=$(echo "$tx" | jq -r '.hash')
                local tx_to=$(echo "$tx" | jq -r '.to // "Contract Creation"')
                local tx_value=$(echo "$tx" | jq -r '.value // "0x0"')
                local tx_value_eth=$(wei_to_eth "$tx_value")
                local tx_gas=$(echo "$tx" | jq -r '.gas // "0x0"')
                local tx_gas_dec=$(hex_to_dec "$tx_gas")
                local tx_gas_price=$(echo "$tx" | jq -r '.gasPrice // "0x0"')
                local tx_gas_price_dec=$(hex_to_dec "$tx_gas_price")
                local tx_nonce=$(echo "$tx" | jq -r '.nonce // "0x0"')
                local tx_nonce_dec=$(hex_to_dec "$tx_nonce")
                local tx_input=$(echo "$tx" | jq -r '.input // "0x"')
                local tx_input_length=${#tx_input}
                
                # Nonce checking and debugging
                local nonce_warning=""
                local account_nonce_at_tx=""
                
                if [ "$CHECK_NONCE" = "true" ]; then
                    # Get account nonce at the previous block (before this transaction)
                    local prev_block=$((block_num - 1))
                    if [ $prev_block -ge 0 ]; then
                        account_nonce_at_tx=$(get_account_nonce "$SENDER_ADDRESS" "$prev_block")
                    fi
                    
                    # Check for nonce issues
                    if [ -n "$account_nonce_at_tx" ]; then
                        if [ "$tx_nonce_dec" -lt "$account_nonce_at_tx" ]; then
                            nonce_warning="${RED}⚠ NONCE TOO LOW: tx_nonce=$tx_nonce_dec < account_nonce=$account_nonce_at_tx${NC}"
                            nonce_out_of_order=$((nonce_out_of_order + 1))
                        elif [ "$tx_nonce_dec" -gt "$account_nonce_at_tx" ]; then
                            local gap=$((tx_nonce_dec - account_nonce_at_tx))
                            nonce_warning="${YELLOW}⚠ NONCE GAP: tx_nonce=$tx_nonce_dec, account_nonce=$account_nonce_at_tx (gap=$gap)${NC}"
                            nonce_gaps=$((nonce_gaps + 1))
                        fi
                    fi
                    
                    # Check for duplicate nonces (bash 3.x compatible)
                    # Use simple pattern matching to check if nonce was seen before
                    local nonce_pattern=" n${tx_nonce_dec}:b"
                    if echo "$nonce_seen" | grep -q "$nonce_pattern" 2>/dev/null; then
                        # Extract the block number where this nonce was first seen
                        local seen_block=$(echo "$nonce_seen" | sed -n "s/.*n${tx_nonce_dec}:b\([0-9]*\).*/\1/p" | head -1)
                        if [ -n "$seen_block" ]; then
                            nonce_warning="${RED}⚠ DUPLICATE NONCE: nonce=$tx_nonce_dec already seen in block $seen_block${NC}"
                        else
                            nonce_warning="${RED}⚠ DUPLICATE NONCE: nonce=$tx_nonce_dec already seen${NC}"
                        fi
                    else
                        # Store nonce with block number: format " n<nonce>:b<block>"
                        nonce_seen="$nonce_seen n${tx_nonce_dec}:b${block_num}"
                    fi
                    
                    # Update expected nonce
                    if [ "$tx_nonce_dec" -ge "$expected_nonce" ]; then
                        expected_nonce=$((tx_nonce_dec + 1))
                    fi
                fi
                
                # Display transaction
                log_tx "  Transaction: $tx_hash"
                echo "    From:      $tx_from"
                echo "    To:        $tx_to"
                echo "    Value:     $tx_value_eth ETH ($tx_value)"
                echo "    Gas:       $tx_gas_dec"
                echo "    Gas Price: $tx_gas_price_dec wei"
                if [ "$CHECK_NONCE" = "true" ] && [ -n "$account_nonce_at_tx" ]; then
                    echo -e "    Nonce:     $tx_nonce_dec ${YELLOW}(account nonce before tx: $account_nonce_at_tx)${NC}"
                    if [ -n "$nonce_warning" ]; then
                        echo -e "    $nonce_warning"
                    fi
                else
                    echo "    Nonce:     $tx_nonce_dec"
                fi
                if [ "$tx_input_length" -gt 2 ] && [ "$tx_input" != "0x" ]; then
                    echo "    Input:     ${tx_input:0:66}${tx_input_length:66:+...} ($tx_input_length chars)"
                else
                    echo "    Input:     $tx_input"
                fi
                
                # Show receipt if requested
                if [ "$SHOW_RECEIPT" = "true" ]; then
                    local receipt=$(get_transaction_receipt "$tx_hash")
                    if [ $? -eq 0 ] && [ -n "$receipt" ] && [ "$receipt" != "null" ]; then
                        echo ""
                        echo -e "${YELLOW}    Receipt:${NC}"
                        local receipt_status=$(echo "$receipt" | jq -r '.status // "unknown"')
                        local receipt_gas_used=$(echo "$receipt" | jq -r '.gasUsed // "0x0"')
                        local receipt_gas_used_dec=$(hex_to_dec "$receipt_gas_used")
                        local receipt_contract_address=$(echo "$receipt" | jq -r '.contractAddress // "null"')
                        local receipt_logs_count=$(echo "$receipt" | jq -r '.logs | length')
                        local receipt_cumulative_gas=$(echo "$receipt" | jq -r '.cumulativeGasUsed // "0x0"')
                        local receipt_cumulative_gas_dec=$(hex_to_dec "$receipt_cumulative_gas")
                        
                        if [ "$receipt_status" = "0x1" ]; then
                            echo -e "      Status: ${GREEN}Success${NC}"
                        elif [ "$receipt_status" = "0x0" ]; then
                            echo -e "      Status: ${RED}Failed${NC}"
                        else
                            echo "      Status: $receipt_status"
                        fi
                        echo "      Gas Used: $receipt_gas_used_dec"
                        echo "      Cumulative Gas Used: $receipt_cumulative_gas_dec"
                        if [ "$receipt_contract_address" != "null" ]; then
                            echo "      Contract Created: $receipt_contract_address"
                        fi
                        echo "      Logs: $receipt_logs_count"
                        
                        if [ "$VERBOSE" = "true" ]; then
                            echo ""
                            echo "$receipt" | jq '.'
                        fi
                    else
                        [ "$VERBOSE" = "true" ] && log_warning "      Failed to get receipt for transaction: $tx_hash"
                    fi
                fi
                
                echo ""
                total_transactions=$((total_transactions + 1))
            fi
        done
        
    done
    
    # Clear progress line and add newline
    if [ "$VERBOSE" != "true" ] && [ $total_blocks_to_scan -gt 10 ]; then
        echo ""
    fi
    
    # Calculate total elapsed time
    local end_time=$(date +%s)
    local total_elapsed=$((end_time - start_time))
    local elapsed_hours=$((total_elapsed / 3600))
    local elapsed_minutes=$(((total_elapsed % 3600) / 60))
    local elapsed_seconds=$((total_elapsed % 60))
    local elapsed_str=""
    
    if [ $elapsed_hours -gt 0 ]; then
        elapsed_str="${elapsed_hours}h ${elapsed_minutes}m ${elapsed_seconds}s"
    elif [ $elapsed_minutes -gt 0 ]; then
        elapsed_str="${elapsed_minutes}m ${elapsed_seconds}s"
    else
        elapsed_str="${elapsed_seconds}s"
    fi
    
    local avg_blocks_per_sec=0
    if [ $total_elapsed -gt 0 ]; then
        avg_blocks_per_sec=$(echo "scale=2; $total_blocks / $total_elapsed" | bc 2>/dev/null || echo "0")
    fi
    
    echo ""
    log_success "Transaction scan completed!"
    echo ""
    echo "📊 Scan Summary"
    echo "=============="
    echo "Sender Address: $SENDER_ADDRESS"
    echo "Total blocks scanned: $total_blocks"
    echo "Blocks with transactions from sender: $blocks_with_tx"
    echo "Total transactions found: $total_transactions"
    echo "Time elapsed: $elapsed_str"
    if [ "$avg_blocks_per_sec" != "0" ] && [ "$avg_blocks_per_sec" != "0.00" ]; then
        echo "Average scanning rate: ${avg_blocks_per_sec} blocks/sec"
    fi
    
    if [ -n "$first_tx_block" ]; then
        echo "First transaction in block: $first_tx_block"
        echo "Last transaction in block: $last_tx_block"
    else
        echo "No transactions found from this sender address in the scanned range."
    fi
    
    if [ $total_blocks -gt 0 ] && [ $blocks_with_tx -gt 0 ]; then
        local tx_percentage=$(echo "scale=2; $blocks_with_tx * 100 / $total_blocks" | bc 2>/dev/null || echo "0")
        local avg_tx=$(echo "scale=2; $total_transactions / $blocks_with_tx" | bc 2>/dev/null || echo "0")
        echo "Percentage of blocks with transactions: ${tx_percentage}%"
        echo "Average transactions per block (with tx): $avg_tx"
    fi
    
    # Nonce debugging summary
    if [ "$CHECK_NONCE" = "true" ] && [ $total_transactions -gt 0 ]; then
        echo ""
        echo "🔍 Nonce Analysis"
        echo "================"
        echo "Expected next nonce: $expected_nonce"
        if [ $nonce_gaps -gt 0 ]; then
            echo -e "${YELLOW}Nonce gaps detected: $nonce_gaps${NC}"
        fi
        if [ $nonce_out_of_order -gt 0 ]; then
            echo -e "${RED}Out-of-order nonces detected: $nonce_out_of_order${NC}"
        fi
        if [ $nonce_gaps -eq 0 ] && [ $nonce_out_of_order -eq 0 ]; then
            echo -e "${GREEN}✓ Nonce sequence is correct${NC}"
        fi
    fi
}

# Main execution
main() {
    parse_args "$@"
    check_prerequisites
    
    # Test RPC connection
    log_info "Testing RPC connection..."
    local test_response=$(rpc_call "eth_blockNumber" "[]")
    if [ $? -ne 0 ]; then
        log_error "Cannot connect to RPC endpoint: $RPC_URL"
        log_error "Please ensure the node is running and the RPC URL is correct."
        exit 1
    fi
    log_success "RPC connection successful"
    echo ""
    
    scan_transactions
}

# Run main function
main "$@"

