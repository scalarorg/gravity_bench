use alloy_rpc_types_eth::TransactionRequest;
use greth::{
    gravity_storage::block_view_storage::BlockViewStorage,
    reth_db::DatabaseEnv,
    reth_node_api::NodeTypesWithDBAdapter,
    reth_node_ethereum::EthereumNode,
    reth_pipe_exec_layer_ext_v2::PipeExecLayerApi,
    reth_provider::providers::BlockchainProvider,
    reth_rpc_api::eth::{helpers::EthCall, RpcTypes},
};
use std::sync::Arc;
use tracing::info;

pub type RethBlockChainProvider =
    BlockchainProvider<NodeTypesWithDBAdapter<EthereumNode, Arc<DatabaseEnv>>>;

pub trait RethEthCall:
    EthCall<NetworkTypes: RpcTypes<TransactionRequest = TransactionRequest>>
{
}

impl<T> RethEthCall for T where
    T: EthCall<NetworkTypes: RpcTypes<TransactionRequest = TransactionRequest>>
{
}

pub type RethPipeExecLayerApi<EthApi> =
    PipeExecLayerApi<BlockViewStorage<RethBlockChainProvider>, EthApi>;

/// Coordinator that verifies executed blocks and sends results back to PipeExecLayer
/// Simplified version for gravity_bench - directly verifies and commits blocks
pub struct GravityBenchCoordinator<EthApi: RethEthCall> {
    pipe_api: Arc<RethPipeExecLayerApi<EthApi>>,
    provider: RethBlockChainProvider,
    chain_id: u64,
}

impl<EthApi: RethEthCall> GravityBenchCoordinator<EthApi> {
    pub fn new(
        pipe_api: Arc<RethPipeExecLayerApi<EthApi>>,
        provider: RethBlockChainProvider,
        chain_id: u64,
    ) -> Self {
        Self {
            pipe_api,
            provider,
            chain_id,
        }
    }

    // Removed methods that used BlockBufferManager - no longer needed

    /// Start commit vote loop: Receive execution results from PipeExecLayer, verify, and send back
    /// This completes the verify_executed_block_hash flow
    pub async fn start_commit_vote(&self) -> Result<(), String> {
        loop {
            let execution_result = self
                .pipe_api
                .pull_executed_block_hash()
                .await
                .expect("failed to recv compute res in recv_compute_res");

            // Verify the executed block hash and immediately send back
            // This completes the verify_executed_block_hash flow:
            // 1. Receive execution result from pipe exec layer
            // 2. Verify the block hash (in a real system, would re-seal and verify)
            // 3. Send verified hash back to pipe exec layer

            let block_id = execution_result.block_id;
            let block_hash = execution_result.block_hash;
            let block_number = execution_result.block_number;

            info!(
                "Verifying executed block: id={:?}, number={}, hash={:?}",
                block_id, block_number, block_hash
            );

            // Verify the block hash - in a real system this would involve re-sealing
            // For now, we trust the execution result and send it back
            // Send verified block hash back to pipe exec layer
            // This completes the verify_executed_block_hash flow
            self.pipe_api
                .commit_executed_block_hash(block_id, Some(block_hash))
                .ok_or_else(|| "Failed to commit executed block hash".to_string())?;

            info!(
                "Block verified and committed: id={:?}, number={}, hash={:?}",
                block_id, block_number, block_hash
            );
        }
    }

    /// Start commit loop: No longer needed - commit is handled directly in start_commit_vote
    /// This method is kept for compatibility but does nothing
    pub async fn start_commit(&self) -> Result<(), String> {
        // Commit is now handled directly in start_commit_vote
        // This loop is kept for future use but currently does nothing
        loop {
            tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
        }
    }

    /// Run all coordinator tasks
    pub fn run(&self) {
        // Spawn commit vote task - verifies blocks and sends results back
        let pipe_api = self.pipe_api.clone();
        let provider = self.provider.clone();
        let chain_id = self.chain_id;
        tokio::spawn(async move {
            let coordinator = GravityBenchCoordinator {
                pipe_api,
                provider,
                chain_id,
            };
            coordinator.start_commit_vote().await.unwrap();
        });

        // Spawn commit task (kept for compatibility, does nothing)
        let pipe_api = self.pipe_api.clone();
        let provider = self.provider.clone();
        let chain_id = self.chain_id;
        tokio::spawn(async move {
            let coordinator = GravityBenchCoordinator {
                pipe_api,
                provider,
                chain_id,
            };
            coordinator.start_commit().await.unwrap();
        });
    }
}
