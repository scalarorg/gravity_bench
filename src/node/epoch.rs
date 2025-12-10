//! Utility functions for fetching epoch information from the EpochManager contract

use alloy::primitives::{Bytes, TxKind};
use alloy_eips::BlockId;
use alloy_rpc_types_eth::{state::EvmOverrides, TransactionInput, TransactionRequest};
use alloy_sol_macro::sol;
use alloy_sol_types::SolCall;
use reth_pipe_exec_layer_ext_v2::onchain_config::{EPOCH_MANAGER_ADDR, SYSTEM_CALLER};
use reth_rpc_api::eth::helpers::EthCall;
use reth_rpc_eth_api::RpcTypes;
// Solidity interface for EpochManager contract
sol! {
    #[allow(missing_docs)]
    contract EpochManager {
        function getCurrentEpochInfo() external view returns (uint256 epoch, uint256 lastTransitionTime, uint256 interval);
    }
}

/// Fetch the current epoch from the EpochManager contract
///
/// # Arguments
/// * `eth_api` - The Eth API for making contract calls
/// * `block_number` - The block number to query the epoch at
///
/// # Returns
/// The current epoch number, or 1 as a fallback if the fetch fails
pub async fn get_current_epoch<EthApi>(eth_api: &EthApi, block_number: u64) -> u64
where
    EthApi: EthCall + Send + Sync,
    EthApi::NetworkTypes: RpcTypes<TransactionRequest = TransactionRequest>,
{
    let call = EpochManager::getCurrentEpochInfoCall {};
    let input: Bytes = call.abi_encode().into();

    let result = eth_api
        .call(
            TransactionRequest {
                from: Some(SYSTEM_CALLER),
                to: Some(TxKind::Call(EPOCH_MANAGER_ADDR)),
                input: TransactionInput::new(input),
                ..Default::default()
            },
            Some(BlockId::from(block_number)),
            EvmOverrides::new(None, None),
        )
        .await;

    match result {
        Ok(output) => {
            let epoch_info = EpochManager::getCurrentEpochInfoCall::abi_decode_returns(&output)
                .expect("Failed to decode getCurrentEpochInfo return value");
            let epoch: u64 = epoch_info.epoch.to::<u64>();
            epoch
        }
        Err(_) => {
            1 // Fallback to epoch 1 if fetch fails
        }
    }
}
