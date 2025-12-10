#!/bin/bash

# Block Scanner Script
# Scans blocks and lists all blocks with number of transactions greater than 0
# Usage: ./scan-blocks.sh [OPTIONS]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default configuration
RPC_URL="${RPC_URL:-}"
START_BLOCK="${START_BLOCK:-0}"
END_BLOCK="${END_BLOCK:-}"
DELAY_MS="${DELAY_MS:-100}"
VERBOSE="${VERBOSE:-false}"
HTTP_PORT="${HTTP_PORT:-8545}"
GET_RECEIPTS="${GET_RECEIPTS:-false}"

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

log_block() {
    echo -e "${CYAN}$1${NC}"
}

# Get execution node public IP from Terraform
get_execution_node_ip() {
    # Try to find terraform directory
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local terraform_dir=""
    
    # Check if we're in a terraform directory or scripts subdirectory
    if [ -f "$script_dir/../main.tf" ] || [ -f "$script_dir/../../main.tf" ]; then
        # Try parent directory first (scripts/ -> terraform/)
        if [ -f "$script_dir/../main.tf" ]; then
            terraform_dir="$(cd "$script_dir/.." && pwd)"
        # Try grandparent (scripts/ -> terraform/ -> bench/)
        elif [ -f "$script_dir/../../main.tf" ]; then
            terraform_dir="$(cd "$script_dir/../.." && pwd)"
        fi
    fi
    
    # Also check current directory
    if [ -z "$terraform_dir" ] && [ -f "./main.tf" ]; then
        terraform_dir="$(pwd)"
    fi
    
    # If no terraform directory found, return empty
    if [ -z "$terraform_dir" ]; then
        return 1
    fi
    
    # Check if terraform command is available
    if ! command -v terraform &> /dev/null; then
        return 1
    fi
    
    # Try to get execution node info from terraform output
    local output=$(cd "$terraform_dir" && terraform output -json execution_node_info 2>/dev/null || echo "")
    
    if [ -z "$output" ] || [ "$output" = "null" ] || [ "$output" = "" ]; then
        return 1
    fi
    
    # Extract external_ip using jq
    local external_ip=$(echo "$output" | jq -r '.external_ip // empty' 2>/dev/null)
    
    if [ -z "$external_ip" ] || [ "$external_ip" = "null" ] || [ "$external_ip" = "" ]; then
        return 1
    fi
    
    echo "$external_ip"
    return 0
}

# Auto-detect RPC URL from execution node if not provided
auto_detect_rpc_url() {
    # If RPC_URL is already set, use it
    if [ -n "$RPC_URL" ]; then
        return 0
    fi
    
    # Try to get execution node IP
    local execution_ip=$(get_execution_node_ip)
    
    if [ -n "$execution_ip" ]; then
        RPC_URL="http://${execution_ip}:${HTTP_PORT}"
        log_info "Auto-detected execution node IP: $execution_ip"
        return 0
    fi
    
    # Fallback to localhost
    RPC_URL="http://localhost:${HTTP_PORT}"
    log_info "Using default RPC URL: $RPC_URL"
    return 0
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

# Get latest block number
get_latest_block_number() {
    local response=$(rpc_call "eth_blockNumber" "[]")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Extract hex string and convert to decimal
    local hex_block=$(echo "$response" | jq -r '.result')
    if [ -z "$hex_block" ] || [ "$hex_block" = "null" ]; then
        return 1
    fi
    
    # Remove 0x prefix if present and convert hex to decimal
    local clean_hex=$(echo "$hex_block" | sed 's/^0x//' | tr '[:lower:]' '[:upper:]')
    
    # Use bc for hex to decimal conversion (most reliable)
    if command -v bc &> /dev/null; then
        echo "ibase=16; $clean_hex" | bc 2>/dev/null
    else
        # Fallback: use bash arithmetic expansion (works for hex strings)
        echo $((0x$clean_hex)) 2>/dev/null || echo "$hex_block"
    fi
}

# Get block by number (with transaction count)
get_block_info() {
    local block_number="$1"
    local hex_block=$(printf "0x%x" "$block_number")
    
    local response=$(rpc_call "eth_getBlockByNumber" "[\"$hex_block\", false]")
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

# Convert hex to decimal
hex_to_dec() {
    local hex="$1"
    if [ -z "$hex" ] || [ "$hex" = "null" ]; then
        echo "0"
        return
    fi
    
    # Remove 0x prefix if present and convert hex to decimal
    local clean_hex=$(echo "$hex" | sed 's/^0x//' | tr '[:lower:]' '[:upper:]')
    
    # Use bc for hex to decimal conversion (most reliable)
    if command -v bc &> /dev/null; then
        echo "ibase=16; $clean_hex" | bc 2>/dev/null || echo "0"
    else
        # Fallback: use bash arithmetic expansion (works for hex strings)
        echo $((0x$clean_hex)) 2>/dev/null || echo "0"
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
Usage: $0 [OPTIONS]

Scans blocks and lists all blocks with number of transactions greater than 0.

OPTIONS:
    -u, --rpc-url URL       RPC endpoint URL (default: auto-detect from terraform or http://localhost:8545)
    -p, --http-port PORT    HTTP RPC port (default: 8545)
    -s, --start-block NUM   Starting block number (default: 0)
    -e, --end-block NUM     Ending block number (default: latest block)
    -d, --delay MS          Delay between requests in milliseconds (default: 100)
    -r, --get-receipts      Get transaction receipts for all transactions (default: false)
    -v, --verbose           Verbose output
    -h, --help              Show this help message

ENVIRONMENT VARIABLES:
    RPC_URL                 RPC endpoint URL (if not set, auto-detects from terraform)
    HTTP_PORT               HTTP RPC port (default: 8545)
    START_BLOCK             Starting block number
    END_BLOCK               Ending block number
    DELAY_MS                Delay between requests in milliseconds
    GET_RECEIPTS            Set to 'true' to get transaction receipts (default: false)
    VERBOSE                 Set to 'true' for verbose output

EXAMPLES:
    $0
    $0 --rpc-url http://localhost:8545 --start-block 0
    $0 -u http://localhost:8545 -s 100 -e 200
    $0 --get-receipts -s 0 -e 100
    RPC_URL=http://localhost:8545 START_BLOCK=0 GET_RECEIPTS=true $0

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--rpc-url)
                RPC_URL="$2"
                shift 2
                ;;
            -p|--http-port)
                HTTP_PORT="$2"
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
            -r|--get-receipts)
                GET_RECEIPTS=true
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
scan_blocks() {
    log_info "Starting block scan..."
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
    log_info "Get receipts: ${GET_RECEIPTS}"
    echo ""
    
    if [ "$START_BLOCK" -gt "$END_BLOCK" ]; then
        log_error "Start block ($START_BLOCK) is greater than end block ($END_BLOCK)"
        exit 1
    fi
    
    local total_blocks=0
    local blocks_with_tx=0
    local total_transactions=0
    local first_block_with_tx=""
    local last_block_with_tx=""
    
    log_info "Scanning blocks from $START_BLOCK to $END_BLOCK..."
    echo ""
    
    # Scan blocks
    for ((block_num=$START_BLOCK; block_num<=$END_BLOCK; block_num++)); do
        # Add delay between requests (except for first block)
        # if [ $block_num -gt $START_BLOCK ] && [ "$DELAY_MS" -gt 0 ]; then
        #     # Convert milliseconds to seconds for sleep
        #     local sleep_seconds=$(echo "scale=3; $DELAY_MS / 1000" | bc 2>/dev/null)
        #     if [ -z "$sleep_seconds" ] || [ "$sleep_seconds" = "0" ]; then
        #         # Fallback: if bc not available or delay < 1ms, use 0.1s default
        #         sleep 0.1
        #     else
        #         sleep "$sleep_seconds"
        #     fi
        # fi
        
        # Get block info
        local block_data=$(get_block_info "$block_num")
        if [ $? -ne 0 ] || [ -z "$block_data" ] || [ "$block_data" = "null" ]; then
            [ "$VERBOSE" = "true" ] && log_warning "Block $block_num not found or error retrieving"
            continue
        fi
        # echo "$block_data"
        total_blocks=$((total_blocks + 1))
        # Get transaction count
        local tx_count=$(echo "$block_data" | jq -r '.transactions | length')
        local tx_count_dec=$tx_count
        
        if [ "$tx_count_dec" -gt 0 ]; then
            blocks_with_tx=$((blocks_with_tx + 1))
            total_transactions=$((total_transactions + tx_count_dec))
            
            if [ -z "$first_block_with_tx" ]; then
                first_block_with_tx=$block_num
            fi
            last_block_with_tx=$block_num
            
            # Get block details
            local block_hash=$(echo "$block_data" | jq -r '.hash')
            local timestamp_hex=$(echo "$block_data" | jq -r '.timestamp')
            local timestamp_dec=$(hex_to_dec "$timestamp_hex")
            local timestamp_str=$(format_timestamp "$timestamp_dec")
            
            # Display block information
            log_block "Block #$block_num | $timestamp_str | $tx_count_dec transaction(s) | Hash: $block_hash"
            
            # Get and display transaction receipts if requested
            if [ "$GET_RECEIPTS" = "true" ]; then
                # Extract transaction hashes from block data
                local tx_hashes=$(echo "$block_data" | jq -r '.transactions[]')
                
                # Process each transaction hash
                while IFS= read -r tx_hash; do
                    if [ -n "$tx_hash" ] && [ "$tx_hash" != "null" ]; then
                        local receipt=$(get_transaction_receipt "$tx_hash")
                        if [ $? -eq 0 ] && [ -n "$receipt" ] && [ "$receipt" != "null" ]; then
                            echo ""
                            echo -e "${YELLOW}Transaction Receipt: $tx_hash${NC}"
                            if [ "$VERBOSE" = "true" ]; then
                                echo "$receipt" | jq '.'
                            else
                                # Display key receipt fields
                                local status=$(echo "$receipt" | jq -r '.status // "unknown"')
                                local gas_used=$(echo "$receipt" | jq -r '.gasUsed // "0"')
                                local gas_used_dec=$(hex_to_dec "$gas_used")
                                local contract_address=$(echo "$receipt" | jq -r '.contractAddress // "null"')
                                local logs_count=$(echo "$receipt" | jq -r '.logs | length')
                                
                                echo "  Status: $status"
                                echo "  Gas Used: $gas_used_dec"
                                echo "  Contract Address: $contract_address"
                                echo "  Logs: $logs_count"
                            fi
                        else
                            [ "$VERBOSE" = "true" ] && log_warning "Failed to get receipt for transaction: $tx_hash"
                        fi
                    fi
                done <<< "$tx_hashes"
            fi
            
            [ "$VERBOSE" = "true" ] && echo "$block_data" | jq '.'
        fi
        
        # Progress indicator every 100 blocks
        if [ $((block_num % 100)) -eq 0 ] && [ $block_num -gt 0 ]; then
            log_info "Progress: Scanned $total_blocks blocks | Found $blocks_with_tx blocks with transactions | Total transactions: $total_transactions"
        fi
    done
    
    echo ""
    log_success "Block scan completed!"
    echo ""
    echo "📊 Scan Summary"
    echo "=============="
    echo "Total blocks scanned: $total_blocks"
    echo "Blocks with transactions: $blocks_with_tx"
    echo "Total transactions found: $total_transactions"
    
    if [ -n "$first_block_with_tx" ]; then
        echo "First block with transactions: $first_block_with_tx"
        echo "Last block with transactions: $last_block_with_tx"
    else
        echo "No blocks with transactions found in the scanned range."
    fi
    
    if [ $total_blocks -gt 0 ]; then
        local tx_percentage=$(echo "scale=2; $blocks_with_tx * 100 / $total_blocks" | bc 2>/dev/null || echo "0")
        local avg_tx=$(echo "scale=2; $total_transactions / $total_blocks" | bc 2>/dev/null || echo "0")
        echo "Percentage of blocks with transactions: ${tx_percentage}%"
        echo "Average transactions per block: $avg_tx"
    fi
}

# Main execution
main() {
    parse_args "$@"
    check_prerequisites
    
    # Auto-detect RPC URL if not explicitly provided
    auto_detect_rpc_url
    
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
    
    scan_blocks
}

# Run main function
main "$@"

