#!/bin/bash

# Script to query validator information from the ValidatorManager system contract
# Usage: 
#   ./validator.sh [RPC_URL] [COMMAND] [ARGS]
# Commands:
#   by-proposer <proposer_hex>  - Get validator by proposer address (32-byte hex)
#   active                       - Get list of active validators
#   info <validator_address>    - Get validator info by address
# Examples: 
#   ./validator.sh http://localhost:8545 by-proposer 0x0147d29bd839289f6c92b391c863e8236f8f2bc8a8043f1542d612e782c1d524
#   ./validator.sh http://localhost:8545 active
#   ./validator.sh http://localhost:8545 info 0x1234567890123456789012345678901234567890

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
RPC_URL="http://localhost:8545"
COMMAND="${1:-active}"
ARG="${2:-}"

VALIDATOR_MANAGER_CONTRACT="0x0000000000000000000000000000000000002013"
SYSTEM_CALLER="0x0000000000000000000000000000000000002000"

# Function selectors
GET_VALIDATOR_BY_PROPOSER_SELECTOR="0xad598bad"
GET_ACTIVE_VALIDATORS_SELECTOR="0x9de70258"
GET_VALIDATOR_INFO_SELECTOR="0x8a11d7c9"

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

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
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
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":$id}" 2>&1)
    
    local curl_exit_code=$?
    
    if [ $curl_exit_code -ne 0 ]; then
        log_error "Failed to connect to RPC endpoint: $RPC_URL"
        log_error "curl error: $response"
        return 1
    fi
    
    # Check if response is empty
    if [ -z "$response" ]; then
        log_error "Empty response from RPC endpoint"
        return 1
    fi
    
    # Check if response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        log_error "Invalid JSON response from RPC endpoint"
        log_error "Response: $response"
        return 1
    fi
    
    # Check for RPC error
    local error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$error" ] && [ "$error" != "null" ] && [ "$error" != "" ]; then
        local error_msg=$(echo "$response" | jq -r '.error.message // .error' 2>/dev/null)
        local error_code=$(echo "$response" | jq -r '.error.code // empty' 2>/dev/null)
        
        # Check if it's an execution revert
        if [ "$error_code" == "3" ] || echo "$error_msg" | grep -q "execution reverted" 2>/dev/null; then
            log_error "Contract execution reverted"
            log_error "This usually means the proposer address is not found in the active validator set"
            log_error "Try running: ./validator.sh active"
            log_error "Or query validator info to see the registered proposer addresses"
        else
            log_error "RPC error: $error_msg"
        fi
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

# Pad hex string to 64 characters (32 bytes)
pad_hex() {
    local hex="$1"
    hex="${hex#0x}"
    # Pad to 64 characters
    printf "%064s" "$hex" | tr ' ' '0'
}

# Encode bytes parameter for ABI encoding
encode_bytes() {
    local hex_bytes="$1"
    # Remove 0x prefix if present
    hex_bytes="${hex_bytes#0x}"
    
    # Calculate length (in bytes, which is hex_length / 2)
    local hex_length=${#hex_bytes}
    local byte_length=$((hex_length / 2))
    
    # Pad hex_bytes to even length
    if [ $((hex_length % 2)) -ne 0 ]; then
        hex_bytes="0${hex_bytes}"
        byte_length=$((byte_length + 1))
    fi
    
    # Encode: offset (32 bytes) + length (32 bytes) + data (padded to 32-byte boundary)
    local offset="0000000000000000000000000000000000000000000000000000000000000020"
    local length=$(printf "%064x" "$byte_length")
    
    # Pad data to 32-byte boundary
    local data_padding=$((32 - (byte_length % 32)))
    if [ $data_padding -eq 32 ]; then
        data_padding=0
    fi
    local padded_length=$((byte_length + data_padding))
    local hex_padded_length=$((padded_length * 2))
    
    # Pad hex_bytes to the required length
    hex_bytes=$(printf "%-${hex_padded_length}s" "$hex_bytes" | tr ' ' '0')
    
    echo "${offset}${length}${hex_bytes}"
}

# Encode address parameter for ABI encoding
encode_address() {
    local addr="$1"
    # Remove 0x prefix if present
    addr="${addr#0x}"
    # Pad to 64 characters (32 bytes, address is 20 bytes, so pad left with zeros)
    printf "%064s" "$addr" | tr ' ' '0'
}

# Query validator by proposer address
query_by_proposer() {
    local proposer_hex="$1"
    
    if [ -z "$proposer_hex" ]; then
        log_error "Proposer address is required"
        echo "Usage: ./validator.sh [RPC_URL] by-proposer <proposer_hex>"
        exit 1
    fi
    
    log_info "Querying validator by proposer address..."
    log_info "Contract: $VALIDATOR_MANAGER_CONTRACT"
    log_info "RPC URL: $RPC_URL"
    log_info "Proposer: $proposer_hex"
    echo ""
    
    # Encode the function call
    local encoded_bytes=$(encode_bytes "$proposer_hex")
    local call_data="0x${GET_VALIDATOR_BY_PROPOSER_SELECTOR#0x}${encoded_bytes}"
    
    log_info "Call data: $call_data"
    
    # Make eth_call
    local response=$(rpc_call "eth_call" "[{\"to\":\"$VALIDATOR_MANAGER_CONTRACT\",\"data\":\"$call_data\",\"from\":\"$SYSTEM_CALLER\"},\"latest\"]")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Extract result
    local result=$(echo "$response" | jq -r '.result' 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$result" ] || [ "$result" == "null" ] || [ "$result" == "0x" ]; then
        log_error "No result returned from contract call"
        log_error "Full response: $response"
        return 1
    fi
    
    # Decode the result
    # getValidatorByProposer() returns: (address validatorAddress, uint64 validatorIndex)
    # address is 32 bytes (64 hex chars), uint64 is 32 bytes (64 hex chars)
    local hex_result="${result#0x}"
    
    # validatorAddress (offset 0, 64 hex chars = 32 bytes, but address is in last 20 bytes)
    local validator_addr_hex="0x${hex_result:24:40}"
    # validatorIndex (offset 64, 64 hex chars = 32 bytes, but uint64 is in last 16 hex chars)
    local validator_index_hex="0x${hex_result:112:16}"
    
    # Convert to decimal
    local validator_index=$(hex_to_dec "$validator_index_hex")
    
    # Display results
    echo "=========================================="
    echo "   Validator by Proposer Address"
    echo "=========================================="
    echo ""
    echo -e "${CYAN}Proposer Address:${NC} $proposer_hex"
    echo -e "${CYAN}Validator Address:${NC} $validator_addr_hex"
    echo -e "${CYAN}Validator Index:${NC} $validator_index"
    echo "=========================================="
    
    return 0
}

# Query active validators list
query_active_validators() {
    log_info "Querying active validators list..."
    log_info "Contract: $VALIDATOR_MANAGER_CONTRACT"
    log_info "RPC URL: $RPC_URL"
    echo ""
    
    # Prepare the call data (function selector only, no parameters)
    local call_data="0x${GET_ACTIVE_VALIDATORS_SELECTOR#0x}"
    
    # Make eth_call
    local response=$(rpc_call "eth_call" "[{\"to\":\"$VALIDATOR_MANAGER_CONTRACT\",\"data\":\"$call_data\",\"from\":\"$SYSTEM_CALLER\"},\"latest\"]")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Extract result
    local result=$(echo "$response" | jq -r '.result' 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$result" ] || [ "$result" == "null" ] || [ "$result" == "0x" ]; then
        log_error "No result returned from contract call"
        log_error "Full response: $response"
        return 1
    fi
    
    # Decode the result
    # getActiveValidators() returns: address[] memory validators
    # Array encoding: offset (32 bytes) + length (32 bytes) + data (address[] padded)
    local hex_result="${result#0x}"
    
    # Get offset (first 64 hex chars)
    local offset_hex="0x${hex_result:0:64}"
    local offset=$(hex_to_dec "$offset_hex")
    
    # Get length at offset position (offset is in bytes, convert to hex chars: offset * 2)
    local length_pos=$((offset * 2))
    local length_hex="0x${hex_result:${length_pos}:64}"
    local length=$(hex_to_dec "$length_hex")
    
    # Display results
    echo "=========================================="
    echo "      Active Validators List"
    echo "=========================================="
    echo ""
    echo -e "${CYAN}Total Active Validators:${NC} $length"
    echo ""
    
    if [ "$length" -eq 0 ]; then
        log_warning "No active validators found"
    else
        echo -e "${CYAN}Validator Addresses:${NC}"
        # Each address is 32 bytes (64 hex chars), starting after length
        local data_start=$((length_pos + 64))
        for ((i=0; i<length; i++)); do
            local addr_start=$((data_start + i * 64))
            # Address is in last 20 bytes (40 hex chars) of the 32-byte slot
            local addr_hex="0x${hex_result:$((addr_start + 24)):40}"
            echo "  [$i] $addr_hex"
        done
    fi
    
    echo "=========================================="
    
    return 0
}

# Decode bytes from hex (extract length and data)
# offset is relative to struct start, struct_start is the position in hex string
decode_bytes() {
    local hex_result="$1"
    local struct_start="$2"
    local offset_hex="$3"
    local offset=$(hex_to_dec "$offset_hex")
    local pos=$((struct_start + offset * 2))
    
    # Get length
    local length_hex="0x${hex_result:${pos}:64}"
    local length=$(hex_to_dec "$length_hex")
    
    # Get data (padded to 32-byte boundary)
    local data_start=$((pos + 64))
    local data_hex="${hex_result:${data_start}:$((length * 2))}"
    
    echo "$data_hex"
}

# Decode string from hex
decode_string() {
    local hex_result="$1"
    local struct_start="$2"
    local offset_hex="$3"
    local offset=$(hex_to_dec "$offset_hex")
    local pos=$((struct_start + offset * 2))
    
    # Get length
    local length_hex="0x${hex_result:${pos}:64}"
    local length=$(hex_to_dec "$length_hex")
    
    # Get data
    local data_start=$((pos + 64))
    local data_hex="${hex_result:${data_start}:$((length * 2))}"
    
    # Convert hex to ASCII
    local result=""
    for ((i=0; i<length*2; i+=2)); do
        local hex_char="${data_hex:$i:2}"
        local dec=$(printf "%d" 0x$hex_char 2>/dev/null)
        if [ $dec -ge 32 ] && [ $dec -le 126 ]; then
            result="${result}$(printf "\\$(printf "%03o" $dec)")"
        else
            result="${result}."
        fi
    done
    
    echo "$result"
}

# Decode ValidatorInfo struct
decode_validator_info() {
    local hex_result="$1"
    
    # Remove 0x prefix
    hex_result="${hex_result#0x}"
    
    # First 32 bytes is offset to struct data
    local struct_offset_hex="0x${hex_result:0:64}"
    local struct_offset=$(hex_to_dec "$struct_offset_hex")
    local struct_pos=$((struct_offset * 2))
    
    # Now decode each field
    local pos=$struct_pos
    local field_num=0
    
    # Field 1: consensusPublicKey (bytes) - dynamic, offset at pos
    local consensus_key_offset_hex="0x${hex_result:${pos}:64}"
    local consensus_key_offset=$(hex_to_dec "$consensus_key_offset_hex")
    pos=$((pos + 64))
    
    # Field 2: commission (struct) - static, 3 uint64s
    local commission_rate_hex="0x${hex_result:${pos}:64}"
    local commission_rate=$(hex_to_dec "$commission_rate_hex")
    pos=$((pos + 64))
    local commission_max_rate_hex="0x${hex_result:${pos}:64}"
    local commission_max_rate=$(hex_to_dec "$commission_max_rate_hex")
    pos=$((pos + 64))
    local commission_max_change_hex="0x${hex_result:${pos}:64}"
    local commission_max_change=$(hex_to_dec "$commission_max_change_hex")
    pos=$((pos + 64))
    
    # Field 3: moniker (string) - dynamic, offset at pos
    local moniker_offset_hex="0x${hex_result:${pos}:64}"
    local moniker_offset=$(hex_to_dec "$moniker_offset_hex")
    pos=$((pos + 64))
    
    # Field 4: registered (bool) - static
    local registered_hex="0x${hex_result:${pos}:64}"
    local registered=$(hex_to_dec "$registered_hex")
    pos=$((pos + 64))
    
    # Field 5: stakeCreditAddress (address) - static
    local stake_credit_hex="0x${hex_result:$((pos + 24)):40}"
    pos=$((pos + 64))
    
    # Field 6: status (enum) - static
    local status_hex="0x${hex_result:${pos}:64}"
    local status=$(hex_to_dec "$status_hex")
    pos=$((pos + 64))
    
    # Field 7: votingPower (uint256) - static
    local voting_power_hex="0x${hex_result:${pos}:64}"
    local voting_power=$(hex_to_dec "$voting_power_hex")
    pos=$((pos + 64))
    
    # Field 8: validatorIndex (uint256) - static
    local validator_index_hex="0x${hex_result:${pos}:64}"
    local validator_index=$(hex_to_dec "$validator_index_hex")
    pos=$((pos + 64))
    
    # Field 9: updateTime (uint256) - static
    local update_time_hex="0x${hex_result:${pos}:64}"
    local update_time=$(hex_to_dec "$update_time_hex")
    pos=$((pos + 64))
    
    # Field 10: operator (address) - static
    local operator_hex="0x${hex_result:$((pos + 24)):40}"
    pos=$((pos + 64))
    
    # Field 11: validatorNetworkAddresses (bytes) - dynamic, offset at pos
    local validator_net_offset_hex="0x${hex_result:${pos}:64}"
    local validator_net_offset=$(hex_to_dec "$validator_net_offset_hex")
    pos=$((pos + 64))
    
    # Field 12: fullnodeNetworkAddresses (bytes) - dynamic, offset at pos
    local fullnode_net_offset_hex="0x${hex_result:${pos}:64}"
    local fullnode_net_offset=$(hex_to_dec "$fullnode_net_offset_hex")
    pos=$((pos + 64))
    
    # Field 13: aptosAddress (bytes) - dynamic, offset at pos
    local aptos_addr_offset_hex="0x${hex_result:${pos}:64}"
    local aptos_addr_offset=$(hex_to_dec "$aptos_addr_offset_hex")
    
    # Now decode dynamic fields (offsets are relative to struct start)
    local consensus_key_hex=$(decode_bytes "$hex_result" "$struct_pos" "$consensus_key_offset_hex")
    local moniker=$(decode_string "$hex_result" "$struct_pos" "$moniker_offset_hex")
    local validator_net_hex=$(decode_bytes "$hex_result" "$struct_pos" "$validator_net_offset_hex")
    local fullnode_net_hex=$(decode_bytes "$hex_result" "$struct_pos" "$fullnode_net_offset_hex")
    local aptos_addr_hex=$(decode_bytes "$hex_result" "$struct_pos" "$aptos_addr_offset_hex")
    
    # Status names
    local status_name="UNKNOWN"
    case "$status" in
        0) status_name="PENDING_ACTIVE" ;;
        1) status_name="ACTIVE" ;;
        2) status_name="PENDING_INACTIVE" ;;
        3) status_name="INACTIVE" ;;
    esac
    
    # Display results
    echo "=========================================="
    echo "         Validator Information"
    echo "=========================================="
    echo ""
    echo -e "${CYAN}Consensus Public Key:${NC} 0x$consensus_key_hex"
    echo ""
    echo -e "${CYAN}Commission:${NC}"
    echo "  Rate: $commission_rate (10000 = 100%)"
    echo "  Max Rate: $commission_max_rate"
    echo "  Max Change Rate: $commission_max_change"
    echo ""
    echo -e "${CYAN}Moniker:${NC} $moniker"
    echo -e "${CYAN}Registered:${NC} $([ "$registered" -eq 1 ] && echo "true" || echo "false")"
    echo -e "${CYAN}Stake Credit Address:${NC} $stake_credit_hex"
    echo -e "${CYAN}Status:${NC} $status_name ($status)"
    echo -e "${CYAN}Voting Power:${NC} $voting_power"
    echo -e "${CYAN}Validator Index:${NC} $validator_index"
    echo -e "${CYAN}Update Time:${NC} $update_time"
    echo -e "${CYAN}Operator:${NC} $operator_hex"
    echo ""
    echo -e "${CYAN}Validator Network Addresses:${NC} 0x$validator_net_hex"
    echo -e "${CYAN}Fullnode Network Addresses:${NC} 0x$fullnode_net_hex"
    echo -e "${CYAN}Aptos Address (Proposer):${NC} 0x$aptos_addr_hex"
    echo ""
    echo "=========================================="
}

# Query validator info by address
query_validator_info() {
    local validator_addr="$1"
    
    if [ -z "$validator_addr" ]; then
        log_error "Validator address is required"
        echo "Usage: ./validator.sh info <validator_address>"
        exit 1
    fi
    
    log_info "Querying validator info..."
    log_info "Contract: $VALIDATOR_MANAGER_CONTRACT"
    log_info "RPC URL: $RPC_URL"
    log_info "Validator Address: $validator_addr"
    echo ""
    
    # Encode the function call
    local encoded_addr=$(encode_address "$validator_addr")
    local call_data="0x${GET_VALIDATOR_INFO_SELECTOR#0x}${encoded_addr}"
    
    # Make eth_call
    local response=$(rpc_call "eth_call" "[{\"to\":\"$VALIDATOR_MANAGER_CONTRACT\",\"data\":\"$call_data\",\"from\":\"$SYSTEM_CALLER\"},\"latest\"]")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Extract result
    local result=$(echo "$response" | jq -r '.result' 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$result" ] || [ "$result" == "null" ] || [ "$result" == "0x" ]; then
        log_error "No result returned from contract call"
        log_error "Full response: $response"
        return 1
    fi
    
    # Decode the ValidatorInfo struct
    decode_validator_info "$result"
    
    return 0
}

# List all validators with their proposer addresses
list_validators_with_proposers() {
    log_info "Fetching active validators and their proposer addresses..."
    log_info "Contract: $VALIDATOR_MANAGER_CONTRACT"
    log_info "RPC URL: $RPC_URL"
    echo ""
    
    # First get active validators
    local call_data="0x${GET_ACTIVE_VALIDATORS_SELECTOR#0x}"
    local response=$(rpc_call "eth_call" "[{\"to\":\"$VALIDATOR_MANAGER_CONTRACT\",\"data\":\"$call_data\",\"from\":\"$SYSTEM_CALLER\"},\"latest\"]")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    local result=$(echo "$response" | jq -r '.result' 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$result" ] || [ "$result" == "null" ] || [ "$result" == "0x" ]; then
        log_error "Failed to get active validators"
        return 1
    fi
    
    # Decode active validators list
    local hex_result="${result#0x}"
    local offset_hex="0x${hex_result:0:64}"
    local offset=$(hex_to_dec "$offset_hex")
    local length_pos=$((offset * 2))
    local length_hex="0x${hex_result:${length_pos}:64}"
    local length=$(hex_to_dec "$length_hex")
    
    echo "=========================================="
    echo "  Validators with Proposer Addresses"
    echo "=========================================="
    echo ""
    echo -e "${CYAN}Total Active Validators:${NC} $length"
    echo ""
    
    if [ "$length" -eq 0 ]; then
        log_warning "No active validators found"
    else
        local data_start=$((length_pos + 64))
        for ((i=0; i<length; i++)); do
            local addr_start=$((data_start + i * 64))
            local validator_addr_hex="0x${hex_result:$((addr_start + 24)):40}"
            
            echo -e "${CYAN}Validator [$i]:${NC} $validator_addr_hex"
            
            # Query validator info to get proposer address
            local encoded_addr=$(encode_address "$validator_addr_hex")
            local info_call_data="0x${GET_VALIDATOR_INFO_SELECTOR#0x}${encoded_addr}"
            local info_response=$(rpc_call "eth_call" "[{\"to\":\"$VALIDATOR_MANAGER_CONTRACT\",\"data\":\"$info_call_data\",\"from\":\"$SYSTEM_CALLER\"},\"latest\"]" 2>/dev/null)
            
            if [ $? -eq 0 ]; then
                local info_result=$(echo "$info_response" | jq -r '.result' 2>/dev/null)
                if [ -n "$info_result" ] && [ "$info_result" != "null" ] && [ "$info_result" != "0x" ]; then
                    # The aptosAddress is in the ValidatorInfo struct, but decoding it fully is complex
                    # For now, just show that we can query it
                    echo "  (Use 'info $validator_addr_hex' to see full details including proposer address)"
                fi
            fi
            echo ""
        done
    fi
    
    echo "=========================================="
    echo ""
    log_info "Note: To see proposer addresses, query each validator's info:"
    log_info "  ./validator.sh info <validator_address>"
    
    return 0
}

# Show usage
show_usage() {
    echo "Usage: ./validator.sh [COMMAND] [ARGS]"
    echo ""
    echo "Commands:"
    echo "  by-proposer <proposer_hex>  Get validator by proposer address (32-byte hex)"
    echo "  active                       Get list of active validators"
    echo "  list                         List validators with their proposer addresses"
    echo "  info <validator_address>    Get validator info by address"
    echo ""
    echo "Examples:"
    echo "  ./validator.sh by-proposer 0x0147d29bd839289f6c92b391c863e8236f8f2bc8a8043f1542d612e782c1d524"
    echo "  ./validator.sh active"
    echo "  ./validator.sh list"
    echo "  ./validator.sh info 0x1234567890123456789012345678901234567890"
}

# Main execution
main() {
    check_prerequisites
    
    case "$COMMAND" in
        by-proposer)
            query_by_proposer "$ARG"
            ;;
        active)
            query_active_validators
            ;;
        list)
            list_validators_with_proposers
            ;;
        info)
            query_validator_info "$ARG"
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main

