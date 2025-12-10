//! Custom gravity node for benchmarking with batch transaction injection
//!
//! This node provides a custom RPC endpoint `gravity_bench_submitBatch` that accepts
//! batches of transactions and buffers them. A background task periodically creates
//! OrderedBlocks from the buffer and injects them directly into the execution pipeline.
//!
//! This follows the node-custom-rpc pattern for extending RPC modules.

// Allow unused crate dependencies since this binary shares dependencies with the main binary
#![allow(unused_crate_dependencies)]

use alloy::primitives::B256;
use alloy_eips::{eip2718::Decodable2718, BlockHashOrNumber};
use alloy_rpc_types_eth::{TransactionTrait, TransactionRequest};
use async_trait::async_trait;
use clap::Parser;
use jsonrpsee::{core::RpcResult, types::ErrorObjectOwned};
use jsonrpsee::proc_macros::rpc;
use reth_ethereum::{
    cli::{chainspec::EthereumChainSpecParser, interface::Cli},
    node::EthereumNode,
    primitives::SignerRecoverable,
};
use std::sync::Arc;
use tracing::{debug, info, warn};
use greth::{
    gravity_storage::{GravityStorage, block_view_storage::BlockViewStorage},
    reth_provider::{BlockHashReader, BlockNumReader, BlockReader},    
    reth_pipe_exec_layer_ext_v2::{self, ExecutionArgs, PipeExecLayerApi}
};
use tokio::sync::oneshot;
use reth_primitives::TransactionSigned;
use node::PipeExecLayerApiTrait;
use reth_rpc_api::eth::helpers::EthCall;
use reth_rpc_eth_api::RpcTypes;
mod node;
use node::GravityBenchNode;

use crate::node::{PROPOSER_ADDRESS1, hex_to_32_bytes};
/// Custom CLI args for gravity bench
#[derive(Debug, Clone, Copy, Default, clap::Args)]
pub struct GravityBenchArgs {
    /// Enable gravity bench batch transaction injection
    #[arg(long)]
    pub enable_gravity_bench: bool,

    /// Batch size for OrderedBlock creation
    #[arg(long, default_value_t = 1000)]
    pub batch_size: usize,

    /// Interval between OrderedBlock creation (milliseconds)
    #[arg(long, default_value_t = 100)]
    pub block_interval_ms: u64,
}

/// Batch injection mode
#[derive(Debug, Clone, Copy, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BatchMode {
    Pool,
    Pipe,
}

/// RPC API trait for gravity bench namespace
#[rpc(server, namespace = "gravity")]
pub trait GravityBenchApi {
    /// Submit a batch of transactions
    ///
    /// # Arguments
    /// * `transactions` - Array of raw transaction bytes
    /// * `mode` - Optional injection mode: "pool" (transaction pool) or "pipe" (OrderedBlock injection). Defaults to "pipe"
    ///
    /// # Returns
    /// Array of transaction hashes
    #[method(name = "submitBatch")]
    async fn submit_batch(
        &self,
        transactions: Vec<alloy::primitives::Bytes>,
        mode: Option<BatchMode>,
    ) -> RpcResult<Vec<B256>>;

    /// Get buffer status
    #[method(name = "getBufferStatus")]
    async fn get_buffer_status(&self) -> RpcResult<node::BufferStatus>;
}

/// Implementation of the gravity bench RPC API
pub struct GravityBenchRpc {
    buffer: Arc<node::TransactionBuffer>,
}

impl GravityBenchRpc {
    pub fn new(buffer: Arc<node::TransactionBuffer>) -> Self {
        Self { buffer }
    }
}

#[async_trait]
impl GravityBenchApiServer for GravityBenchRpc {
    async fn submit_batch(
        &self,
        transactions: Vec<alloy::primitives::Bytes>,
        mode: Option<BatchMode>,
    ) -> RpcResult<Vec<B256>> {

        let injection_mode = mode.unwrap_or(BatchMode::Pipe);
        let batch_size = transactions.len();

        match injection_mode {
            BatchMode::Pool => {
                info!(
                    "📡 [RPC] gravity_submitBatch: Received batch of {} transactions via POOL mode (transaction pool)",
                    batch_size
                );

                // For pool mode, we need to use the standard eth_sendRawTransaction RPC
                // which is already available. This mode is mainly for compatibility.
                // In practice, users should use eth_sendRawTransaction for pool mode.
                warn!(
                    "⚠️ [RPC] Pool mode via gravity_submitBatch is not fully implemented. Use eth_sendRawTransaction for pool mode."
                );
                
                // For now, fall back to pipe mode
                // TODO: Implement proper pool mode support
                Ok(Vec::new())
            }
            BatchMode::Pipe => {
                let mut hashes = Vec::new();
                let mut accepted = 0;
                let mut txs = Vec::new();
                for (idx, tx_bytes) in transactions.iter().enumerate() {
                    let mut bytes = tx_bytes.as_ref();
                    match TransactionSigned::decode_2718(&mut bytes) {
                        Ok(tx) => {
                            let hash: B256 = *tx.hash();
                            let nonce = tx.nonce();
                            if let Ok(sender) = tx.recover_signer() {                                
                                // Get buffer status before adding
                                txs.push((tx, sender));
                                hashes.push(hash);
                                accepted += 1;
                                debug!(
                                    "✅ [RPC] Transaction {} accepted: sender={}, hash={:?}, nonce={}",
                                    idx + 1, sender, hash, nonce
                                );
                            } else {
                                warn!(
                                    "❌ [RPC] Transaction {} rejected: Failed to recover sender, hash={:?}",
                                    idx + 1, hash
                                );
                                return Err(ErrorObjectOwned::owned(
                                    -32000,
                                    format!("Transaction {} rejected: Failed to recover sender", idx + 1),
                                    None::<()>,
                                ));
                            }
                        }
                        Err(e) => {
                            warn!(
                                "❌ [RPC] Transaction {} rejected: Failed to decode transaction: {}",
                                idx + 1, e
                            );
                            return Err(ErrorObjectOwned::owned(
                                -32602,
                                format!("Transaction {} rejected: Failed to decode transaction: {}", idx + 1, e),
                                None::<()>,
                            ));
                        }
                    }
                }

                // Get buffer status after adding transactions
                let buffer_status_before = self.buffer.get_status().await;
                // Add transaction to simple transaction buffer
                if !self.buffer.add_transactions(txs).await {
                    return Err(ErrorObjectOwned::owned(
                        -32000,
                        format!("Buffer full {} + {} > {}", buffer_status_before.queued, batch_size, buffer_status_before.max_size),
                        None::<()>,
                    ));
                }
                let buffer_status_after = self.buffer.get_status().await;
                info!(
                    "📊 [RPC] Pipe batch processing complete: accepted={}, buffer_before={}, buffer_after={}",
                    accepted,
                    buffer_status_before.queued,
                    buffer_status_after.queued
                );

                Ok(hashes)
            }
        }
    }

    async fn get_buffer_status(&self) -> RpcResult<node::BufferStatus> {
        Ok(self.buffer.get_status().await)
    }
}

fn main() {
    Cli::<EthereumChainSpecParser, GravityBenchArgs>::parse()
        .run(|builder, args| async move {
            info!("🚀 [GravityBench] Initializing gravity_node with dual-mode support");
            info!("   Mode 1: Dev mode miner - mines transactions from transaction pool");
            info!("   Mode 2: OrderedBlock injection - handles gravity_bench_submitBatch transactions");
            
            // Create simple transaction buffer for RPC
            let buffer = Arc::new(node::TransactionBuffer::new());
            // Create gravity bench node for OrderedBlock injection
            // let genesis_timestamp = builder.config().chain.genesis_header().timestamp;
            let base_timestamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
            let bench_node = Arc::new(
                GravityBenchNode::new(args.batch_size, args.block_interval_ms, buffer.clone(), base_timestamp)
                    .await
                    .expect("Failed to create GravityBenchNode"),
            );
   
            // Create execution args channel for pipe execution layer
            let (execution_args_tx, execution_args_rx) = oneshot::channel::<ExecutionArgs>();

            let handle = builder
                // Configure default ethereum node
                .node(EthereumNode::default())
                // Extend the RPC modules with our custom gravity_bench endpoints
                .extend_rpc_modules(move |ctx| {
                    if !args.enable_gravity_bench {
                        return Ok(());
                    }

                    // Create the RPC extension with transaction buffer
                    // Note: Pool mode support requires accessing the pool from RPC context,
                    // which is complex. For now, we only support pipe mode.
                    let rpc_ext = GravityBenchRpc::new(buffer);

                    // Merge gravity_bench namespace
                    ctx.modules
                        .merge_configured(GravityBenchApiServer::into_rpc(rpc_ext))?;

                    info!("✅ [GravityBench] RPC extension enabled");
                    info!("  - gravity_submitBatch(transactions: Vec<Bytes>, mode?: \"pool\"|\"pipe\") -> Vec<B256>");
                    info!("  - gravity_getBufferStatus() -> BufferStatus");
                    info!(
                        "⚙️ [GravityBench] Configuration: batch_size={}, block_interval_ms={}",
                        args.batch_size, args.block_interval_ms
                    );

                    Ok(())
                })
                .on_node_started(move |full_node| {
                    info!("✅ [GravityBench] Node started");
                    
                    if !args.enable_gravity_bench {
                        return Ok(());
                    }
                    
                    let execution_args_rx_clone = execution_args_rx;
                    
                    // Get required components from full node
                    let provider = full_node.provider.clone();
                    let chain_spec = full_node.chain_spec();
                    let eth_api = full_node.rpc_registry.eth_api().clone();
                    
                    // Get latest block information
                    let latest_block_number = match provider.last_block_number() {
                        Ok(num) => num,
                        Err(e) => {
                            warn!("❌ [GravityBench] Failed to get latest block number: {}", e);
                            return Ok(());
                        }
                    };
                    
                    let latest_block_hash = match provider.block_hash(latest_block_number) {
                        Ok(Some(hash)) => hash,
                        Ok(None) => {
                            warn!("❌ [GravityBench] Latest block hash not found");
                            return Ok(());
                        }
                        Err(e) => {
                            warn!("❌ [GravityBench] Failed to get latest block hash: {}", e);
                            return Ok(());
                        }
                    };
                    
                    let latest_block = match provider.block(BlockHashOrNumber::Number(latest_block_number)) {
                        Ok(Some(block)) => block,
                        Ok(None) => {
                            info!("ℹ️ [GravityBench] No blocks found, skipping setup (will sync on first block)");
                            return Ok(());
                        }
                        Err(e) => {
                            warn!("❌ [GravityBench] Failed to get latest block: {}", e);
                            return Ok(());
                        }
                    };
                    
                    info!("📦 [GravityBench] Creating pipe execution layer API");
                    info!("   Latest block: number={}, hash={:?}", latest_block_number, latest_block_hash);
                    
                    // Create storage wrapper
                    let storage = BlockViewStorage::new(provider.clone());
                    // Get chain_id from chain_spec
                    let chain_id = match chain_spec.chain.into_kind() {
                        greth::reth_chainspec::ChainKind::Named(n) => n as u64,
                        greth::reth_chainspec::ChainKind::Id(id) => id,
                    };
                    // Create pipe execution layer API
                    let pipeline_api = reth_pipe_exec_layer_ext_v2::new_pipe_exec_layer_api(
                        chain_spec,
                        storage,
                        latest_block.header,
                        latest_block_hash,
                        execution_args_rx_clone,
                        eth_api.clone(),
                    );
                    
                    info!("✅ [GravityBench] Pipe execution layer API created");
                    
                    // Create coordinator (similar to RethCoordinator in gravity_sdk)
                    use crate::node::coordinator::GravityBenchCoordinator;
                    let pipeline_api_arc = Arc::new(pipeline_api);
                    let coordinator = GravityBenchCoordinator::new(
                        pipeline_api_arc.clone(),
                        provider.clone(),
                        chain_id,
                    );
                    
                    // Start coordinator tasks (start_execution, start_commit_vote, start_commit)
                    coordinator.run();
                    info!("✅ [GravityBench] Coordinator started (execution, commit_vote, commit tasks)");
                    
                    // Initialize pipe API in bench node
                    // Wrap it using the same pattern as init_pipe_api
                    let pipe_api_arc = pipeline_api_arc.clone();
                    let bench_node_clone = bench_node.clone();
                    tokio::spawn(async move {
                        // Create wrapper that implements the trait (same as in setup.rs)
                        struct PipeApiWrapper<Storage, EthApi> {
                            inner: Arc<PipeExecLayerApi<Storage, EthApi>>,
                        }
                        
                        impl<Storage, EthApi> PipeExecLayerApiTrait for PipeApiWrapper<Storage, EthApi>
                        where
                            Storage: GravityStorage,
                            EthApi: EthCall,
                            EthApi::NetworkTypes: RpcTypes<TransactionRequest = TransactionRequest>,
                        {
                            fn push_ordered_block(&self, block: greth::reth_pipe_exec_layer_ext_v2::OrderedBlock) -> Option<()> {
                                self.inner.push_ordered_block(block)
                            }
                        }
                        
                        // Wrap the pipe API
                        let wrapped: Arc<dyn PipeExecLayerApiTrait> = Arc::new(PipeApiWrapper {
                            inner: pipe_api_arc,
                        });
                        
                        // Set it in the bench node's pipe_api mutex
                        let pipe_api_mutex = bench_node_clone.get_pipe_api();
                        let mut api_guard = pipe_api_mutex.lock().await;
                        *api_guard = Some(wrapped);
                        info!("✅ [GravityBench] Pipe API initialized for OrderedBlock injection");
                    });
                    
                    // Send execution args
                    let _ = execution_args_tx.send(ExecutionArgs {
                        block_number_to_block_id: std::collections::BTreeMap::new(),
                    });
                    
                    // Create and push empty NIL block to sync GlobalSystemTimestamp
                    let provider_clone = provider.clone();
                    let pipe_api_for_nil = pipeline_api_arc.clone();
                    let eth_api_for_contract_call = eth_api.clone();
                    
                    tokio::spawn(async move {
                        use alloy::primitives::{Address, keccak256};
                        use alloy_eips::eip4895::Withdrawals;
                        use greth::reth_pipe_exec_layer_ext_v2::OrderedBlock;
                        use node::epoch::get_current_epoch;
                        info!("🔄 [GravityBench] Creating empty NIL block for GlobalSystemTimestamp synchronization");
                        
                        // Get latest block information
                        let latest_block_number = match provider_clone.last_block_number() {
                            Ok(num) => num,
                            Err(e) => {
                                warn!("❌ [GravityBench] Failed to get last block number: {}, using 0", e);
                                0
                            }
                        };
                        
                        let latest_block_hash = provider_clone
                            .block_hash(latest_block_number)
                            .ok()
                            .flatten()
                            .unwrap_or(B256::ZERO);
                         
                        // Fetch current epoch from the EpochManager contract
                        let current_epoch = get_current_epoch(&eth_api_for_contract_call, latest_block_number).await;
                        
                        // Generate unique block ID
                        let block_id = {
                            let mut input = Vec::with_capacity(32);
                            input.extend_from_slice(&latest_block_number.to_be_bytes());
                            input.extend_from_slice(&base_timestamp.to_be_bytes());
                            input.extend_from_slice(b"nil_sync_startup");
                            input.extend_from_slice(&std::process::id().to_be_bytes());
                            keccak256(input)
                        };
                        
                        // Create empty NIL OrderedBlock
                        let empty_nil_block = OrderedBlock {
                            epoch: current_epoch,
                            parent_id: latest_block_hash,
                            id: block_id,
                            number: latest_block_number + 1,
                            timestamp: base_timestamp,
                            coinbase: Address::ZERO,
                            prev_randao: B256::ZERO,
                            withdrawals: Withdrawals::new(Vec::new()),
                            transactions: Vec::new(), // Empty - no transactions
                            senders: Vec::new(),      // Empty - no senders
                            proposer: Some(hex_to_32_bytes(PROPOSER_ADDRESS1)),
                            extra_data: Vec::new(),
                            randomness: alloy::primitives::U256::ZERO,
                            enable_randomness: false,
                        };
                        
                        info!(
                            "📤 [GravityBench] Pushing empty NIL block for GlobalSystemTimestamp sync: number={}, epoch={}, placeholder_timestamp={}, parent_id={:?}, block_id={:?}",
                            empty_nil_block.number,
                            empty_nil_block.epoch,
                            empty_nil_block.timestamp,
                            empty_nil_block.parent_id,
                            empty_nil_block.id
                        );
                        // Push to execution layer
                        pipe_api_for_nil.push_ordered_block(empty_nil_block);
                        
                        info!("✅ [GravityBench] Empty NIL block pushed successfully for GlobalSystemTimestamp synchronization");
                    });
                    
                    // Start the OrderedBlock injection loop
                    // This runs in parallel with dev mode miner:
                    // - Dev mode miner: Mines transactions from pool (setup transactions)
                    // - OrderedBlock injection: Handles transactions from BlockBufferManager (test transactions)
                    // Pass provider so OrderedBlock injection can sync with LocalMiner blocks
                    let pipe_api = bench_node.get_pipe_api();
                    let provider_for_sync = Arc::new(provider.clone());
                    let engine_events = full_node.add_ons_handle.engine_events.new_listener();
                    tokio::spawn(async move {
                        info!("🔄 [GravityBench] Starting OrderedBlock injection background task");
                        info!("   This will handle transactions from gravity_bench_submitBatch");
                        info!("   Dev mode miner will continue to mine transactions from transaction pool");
                        info!("   OrderedBlock injection will sync with LocalMiner blocks automatically");
                        bench_node
                            .run_injection_loop(pipe_api, eth_api, provider_for_sync, engine_events)
                            .await;
                    });
                    
                    Ok(())
                })
                // Launch the node with debug capabilities (includes LocalMiner for dev mode)
                // The LocalMiner will mine transactions from the transaction pool
                // OrderedBlock injection will handle transactions from gravity_bench_submitBatch
                // Both can work simultaneously:
                // - Setup transactions (deploy, faucet) → transaction pool → LocalMiner mines them
                // - Test transactions (benchmark) → gravity_bench_submitBatch → OrderedBlock injection
                .launch_with_debug_capabilities()
                .await?;
            
            info!("🚀 [GravityBench] Node launched successfully!");
            info!("📋 [GravityBench] Dual-mode operation enabled:");
            info!("   ✅ Dev mode miner: Active - mines transactions from transaction pool");
            info!("   ✅ OrderedBlock injection: Active - handles gravity_bench_submitBatch transactions");
            info!("");
            info!("📊 [GravityBench] Transaction routing:");
            info!("   🔵 Setup phase: eth_sendRawTransaction → Transaction Pool → Dev Mode Miner → Block");
            info!("   🟢 Test phase: gravity_bench_submitBatch → Buffer → OrderedBlock Injection → Block");
            info!("");
            info!("💡 [GravityBench] Both systems run in parallel - no conflicts expected");

            handle.wait_for_node_exit().await
        })
        .unwrap();
}

