use alloy::primitives::{Address, B256, U256};
use alloy_consensus::BlockHeader;
use alloy_rpc_types_eth::TransactionRequest;
use anyhow::Result;
use futures::StreamExt;
use greth::reth_node_api::ConsensusEngineEvent;
use greth::reth_pipe_exec_layer_ext_v2::{OrderedBlock, PipeExecLayerApi};
use greth::reth_provider::{BlockHashReader, BlockNumReader, HeaderProvider};
use reth_primitives::NodePrimitives;
use reth_rpc_api::eth::helpers::EthCall;
use reth_rpc_eth_api::RpcTypes;
use reth_tokio_util::EventStream;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Mutex, RwLock};
use tracing::{debug, info, warn};

use crate::node::buffer::TransactionBuffer;
use crate::node::{get_current_epoch, hex_to_32_bytes, PROPOSER_ADDRESS1};

const ALLOWED_FUTURE_BLOCK_TIME_SECONDS: u64 = 15;
/// Gravity node setup for benchmarking
pub struct GravityBenchNode {
    pipe_api: Arc<Mutex<Option<Arc<dyn PipeExecLayerApiTrait>>>>,
    buffer: Arc<TransactionBuffer>,
    batch_size: usize,
    block_interval_ms: u64,
    /// Base timestamp in seconds (from genesis or latest block)
    /// Timestamps will increment from this base value
    base_timestamp: Arc<std::sync::atomic::AtomicU64>,
    #[allow(dead_code)] // Reserved for future use when connecting to node handle
    node_handle: Option<Arc<dyn std::any::Any + Send + Sync>>,
}

// Trait to abstract over the pipe API
pub trait PipeExecLayerApiTrait: Send + Sync {
    fn push_ordered_block(&self, block: OrderedBlock) -> Option<()>;
}

impl GravityBenchNode {
    pub async fn new(
        batch_size: usize,
        block_interval_ms: u64,
        buffer: Arc<TransactionBuffer>,
        genesis_timestamp: u64,
    ) -> Result<Self> {
        info!("GravityBenchNode initialized");
        info!("Note: Pipe API will be set when gravity node is started");
        info!("Please start gravity_node separately with MOCK_CONSENSUS=true");

        Ok(Self {
            pipe_api: Arc::new(Mutex::new(None)),
            buffer,
            batch_size,
            block_interval_ms,
            base_timestamp: Arc::new(std::sync::atomic::AtomicU64::new(genesis_timestamp)),
            node_handle: None,
        })
    }

    /// Initialize pipe API from an existing gravity node
    /// This should be called after the gravity node is started
    /// TODO: Implement when pipe API is available from node context
    #[allow(dead_code)] // Reserved for future use when pipe API is available from node context
    pub async fn init_pipe_api<Storage, EthApi>(
        &mut self,
        pipe_api: Arc<PipeExecLayerApi<Storage, EthApi>>,
    ) -> Result<()>
    where
        Storage: greth::gravity_storage::GravityStorage + 'static,
        EthApi: reth_rpc_api::eth::helpers::EthCall + 'static,
        EthApi::NetworkTypes: reth_rpc_eth_api::RpcTypes<
            TransactionRequest = alloy_rpc_types_eth::TransactionRequest,
        >,
    {
        let wrapped = Arc::new(PipeApiWrapper { inner: pipe_api });
        let mut api = self.pipe_api.lock().await;
        *api = Some(wrapped);
        info!("Pipe API initialized for OrderedBlock injection");
        Ok(())
    }

    pub fn get_pipe_api(&self) -> Arc<Mutex<Option<Arc<dyn PipeExecLayerApiTrait>>>> {
        self.pipe_api.clone()
    }

    /// Run the injection loop that creates OrderedBlocks from TransactionBuffer
    ///
    /// This function uses a simpler pattern:
    /// 1. Event handler sub-task: Listens for canonical block events and updates shared state
    /// 2. Main task: Periodically creates blocks, ensuring the last created block is committed
    ///
    /// # Arguments
    /// * `pipe_api` - Pipe API for injecting OrderedBlocks
    /// * `eth_api` - Eth API for fetching epoch from contract
    /// * `provider` - Provider for syncing with canonical chain (LocalMiner blocks)
    /// * `engine_events` - Stream of consensus engine events to listen for canonical block events
    pub async fn run_injection_loop<Provider, EthApi, N>(
        &self,
        pipe_api: Arc<Mutex<Option<Arc<dyn PipeExecLayerApiTrait>>>>,
        eth_api: EthApi,
        provider: Arc<Provider>,
        mut engine_events: EventStream<ConsensusEngineEvent<N>>,
    ) where
        Provider: BlockNumReader + BlockHashReader + HeaderProvider + Send + Sync + 'static,
        Provider::Header: alloy::consensus::BlockHeader,
        EthApi: EthCall + reth_rpc_api::eth::helpers::EthState + Send + Sync + 'static,
        EthApi::NetworkTypes: RpcTypes<TransactionRequest = TransactionRequest>,
        N: NodePrimitives,
    {
        info!(
            "🚀 [GravityBenchNode] Starting OrderedBlock injection loop: batch_size={}, block_interval_ms={}ms",
            self.batch_size,
            self.block_interval_ms
        );

        // Shared state: only canonical block (one-way: event handler writes, main task reads)
        let latest_canonical_block = Arc::new(RwLock::new(None));

        // Spawn event handler sub-task (background task)
        let event_state = latest_canonical_block.clone();
        tokio::spawn(async move {
            info!("[GravityBenchNode] Event handler task started");
            while let Some(event) = engine_events.next().await {
                match event {
                    ConsensusEngineEvent::CanonicalChainCommitted(head, _) => {
                        let canonical_block_number = (*head).number();
                        *event_state.write().await = Some(canonical_block_number);
                    }
                    ConsensusEngineEvent::CanonicalBlockAdded(executed_block, elapsed) => {
                        let block = executed_block.sealed_block();
                        let block_number = block.header().number();
                        debug!(
                            "✓ [GravityBenchNode] Canonical block added: block #{} (hash: {:?}) in {:?}",
                            block_number,
                            block.hash(),
                            elapsed
                        );
                    }
                    _ => {
                        // Ignore other events
                    }
                }
            }
            warn!("[GravityBenchNode] Event handler task ended unexpectedly");
        });

        // Main task: periodic block creation loop
        // Local state for tracking creation (no need to share with event handler)
        let mut last_created_block_number: Option<u64> = None;
        let mut last_created_block_time: Option<u64> = None;

        let mut interval = tokio::time::interval(Duration::from_millis(self.block_interval_ms));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            interval.tick().await;

            // Read canonical state (simple read from shared state)
            let latest_canonical = *latest_canonical_block.read().await;

            // Check if we can create the next block
            // We can create if:
            // 1. We have a canonical block to build on
            // 2. Either we haven't created any block yet, OR the last block we created is now canonical
            let can_create = if let Some(canonical_block) = latest_canonical {
                if let Some(last_created_num) = last_created_block_number {
                    // Check if the last block we created is now canonical
                    if canonical_block >= last_created_num {
                        true
                    } else {
                        debug!(
                            "⏳ [GravityBenchNode] Waiting for block #{} to become canonical (current canonical: #{})",
                            last_created_num,
                            canonical_block
                        );
                        false
                    }
                } else {
                    // No block created yet, we can create one
                    true
                }
            } else {
                debug!("⏳ [GravityBenchNode] No canonical block available yet, skipping");
                false
            };

            if can_create {
                if let Some(canonical_block) = latest_canonical {
                    // Create the next block
                    let result = Self::try_create_next_block(
                        &pipe_api,
                        &eth_api,
                        &provider,
                        canonical_block,
                        last_created_block_time,
                        &self.buffer,
                        self.batch_size,
                        self.block_interval_ms,
                        &self.base_timestamp,
                    )
                    .await;

                    if let Some((block_number, block_timestamp)) = result {
                        // Update local state (no need to share with event handler)
                        last_created_block_number = Some(block_number);
                        last_created_block_time = Some(block_timestamp);
                    }
                }
            }
        }
    }

    /// Static helper function to try creating the next block if transactions are available
    ///
    /// This function checks if enough time has passed since the last block creation
    /// (based on block_interval_ms) and waits if necessary before creating the next block.
    async fn try_create_next_block<Provider, EthApi>(
        pipe_api: &Arc<Mutex<Option<Arc<dyn PipeExecLayerApiTrait>>>>,
        eth_api: &EthApi,
        provider: &Arc<Provider>,
        latest_canonical_block_number: u64,
        last_created_block_time: Option<u64>,
        buffer: &Arc<TransactionBuffer>,
        batch_size: usize,
        block_interval_ms: u64,
        base_timestamp: &Arc<std::sync::atomic::AtomicU64>,
    ) -> Option<(u64, u64)>
    // Returns (block_number, block_timestamp)
    where
        Provider: BlockNumReader + BlockHashReader + HeaderProvider + Send + Sync + 'static,
        Provider::Header: alloy::consensus::BlockHeader,
        EthApi: EthCall + Send + Sync + 'static,
        EthApi::NetworkTypes: RpcTypes<TransactionRequest = TransactionRequest>,
    {
        // Check if we need to wait for block_interval_ms before creating the next block
        if let Some(last_time) = last_created_block_time {
            let current_time = std::time::SystemTime::now()
                .duration_since(std::time::SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_secs();

            // Calculate how much time has passed since the last block
            let time_since_last_block = current_time.saturating_sub(last_time);
            let interval_seconds = block_interval_ms / 1000;

            if time_since_last_block < interval_seconds {
                let wait_time = interval_seconds - time_since_last_block;
                info!(
                    "⏳ [GravityBenchNode] Waiting {} seconds before creating next block (block_interval_ms={}ms, time_since_last={}s)",
                    wait_time,
                    block_interval_ms,
                    time_since_last_block
                );
                tokio::time::sleep(Duration::from_secs(wait_time)).await;
            }
        }

        // Get transactions from simple transaction buffer
        let txn_buffer_len = buffer.len().await;

        // Only create OrderedBlocks when we have transactions in the buffer
        // Empty blocks should be handled by the dev mode miner for normal RPC transactions
        if txn_buffer_len == 0 {
            debug!(
                "⏳ [GravityBenchNode] Transaction buffer empty, skipping block creation - dev mode miner will handle RPC transactions from transaction pool"
            );
            return None;
        }

        info!(
            "📦 [GravityBenchNode] Transaction buffer has {} transactions, creating OrderedBlock after canonical block #{}",
            txn_buffer_len,
            latest_canonical_block_number
        );

        // Take batch of transactions from buffer
        let batch = buffer.take_batch(batch_size).await;

        // Use the latest canonical block number as the base
        // The new block will be latest_canonical_block_number + 1
        let new_block_number = latest_canonical_block_number + 1;

        // Get the latest canonical block hash to use as parent_id for the new OrderedBlock
        let latest_block_hash = provider
            .block_hash(latest_canonical_block_number)
            .ok()
            .flatten()
            .unwrap_or(B256::ZERO);

        info!(
            "Creating block #{} on top of canonical block #{} (hash: {:?})",
            new_block_number, latest_canonical_block_number, latest_block_hash
        );
        // Calculate timestamp: base + (block_number - 1) * block_interval_ms / 1000
        // This ensures timestamps advance properly and match the stored timestamp contract
        // For the first block (block_number=1), we use base_timestamp
        // For subsequent blocks, we increment by block_interval_ms seconds
        let base_ts = base_timestamp.load(std::sync::atomic::Ordering::SeqCst);
        let calculated_timestamp = base_ts + ((new_block_number - 1) * block_interval_ms / 1000);

        // Ensure timestamp is not too far in the future compared to system clock
        // Ethereum allows blocks to be up to 15 seconds in the future
        let current_time = std::time::SystemTime::now()
            .duration_since(std::time::SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();

        let max_allowed_timestamp = current_time + ALLOWED_FUTURE_BLOCK_TIME_SECONDS;

        // Use the minimum of calculated timestamp and max allowed to prevent future timestamp errors
        let timestamp = calculated_timestamp.min(max_allowed_timestamp);

        if timestamp != calculated_timestamp {
            warn!(
                    "⚠️ [GravityBenchNode] Clamped block timestamp from {} to {} (current time: {}) to prevent future timestamp error",
                    calculated_timestamp, timestamp, current_time
                );
            // Update base_timestamp to current time to prevent future blocks from hitting this limit
            // This ensures timestamps stay synchronized with system clock
            let new_base = current_time.saturating_sub(ALLOWED_FUTURE_BLOCK_TIME_SECONDS);
            base_timestamp.store(new_base, std::sync::atomic::Ordering::SeqCst);
            info!(
                "🔄 [GravityBenchNode] Updated base_timestamp from {} to {} to sync with system clock",
                base_ts, new_base
            );
        }

        // Generate block ID
        let block_id = {
            use alloy::primitives::keccak256;
            let mut input = Vec::with_capacity(16);
            input.extend_from_slice(&new_block_number.to_be_bytes());
            input.extend_from_slice(&timestamp.to_be_bytes());
            keccak256(input)
        };
        // Use the latest canonical block hash as parent_id
        // For genesis block (block_number=0), parent_id will be B256::ZERO
        let parent_id = latest_block_hash;

        let (txs, senders): (Vec<_>, Vec<_>) = batch.into_iter().unzip();
        let tx_count = txs.len();
        // for (idx, tx) in txs.iter().enumerate() {
        //     // Print transaction hash as hex string
        //     debug!("[GravityBenchNode] Transaction {}: 0x{:x}", idx, tx.hash());
        // }
        // Fetch current epoch from the EpochManager contract
        let current_epoch = get_current_epoch(eth_api, latest_canonical_block_number).await;
        let ordered_block = OrderedBlock {
            epoch: current_epoch,
            parent_id,
            id: block_id,
            number: new_block_number,
            timestamp,
            coinbase: Address::ZERO,
            prev_randao: B256::ZERO,
            withdrawals: Default::default(),
            transactions: txs,
            senders: senders.clone(),
            proposer: Some(hex_to_32_bytes(PROPOSER_ADDRESS1)),
            extra_data: vec![],
            randomness: U256::ZERO,
            enable_randomness: false,
        };
        info!(
            "🔨 [GravityBenchNode] Creating OrderedBlock #{}: epoch={}, {} transactions from gravity_bench_submitBatch, parent_id={:?}, block_id={:?}",
            new_block_number,
            current_epoch,
            tx_count,
            parent_id,
            block_id
        );

        let start_time = std::time::Instant::now();
        let pipe_api_guard = pipe_api.lock().await;
        let result = if let Some(api) = pipe_api_guard.as_ref() {
            api.push_ordered_block(ordered_block)
        } else {
            None
        };
        let duration = start_time.elapsed();

        if result.is_some() {
            info!(
                "✅ [GravityBenchNode] Successfully injected OrderedBlock #{} into pipe exec layer: epoch={}, {} transactions, duration={:?}, block_id={:?}, timestamp={}",
                new_block_number,
                current_epoch,
                tx_count,
                duration,
                block_id,
                timestamp
            );
            Some((new_block_number, timestamp))
        } else {
            warn!(
                "❌ [GravityBenchNode] Failed to inject OrderedBlock #{} into pipe exec layer: pipe API not available",
                new_block_number
            );
            None
        }
    }
}

// Wrapper to make PipeExecLayerApi work with trait objects
struct PipeApiWrapper<Storage, EthApi> {
    inner: Arc<PipeExecLayerApi<Storage, EthApi>>,
}

impl<
        Storage: greth::gravity_storage::GravityStorage,
        EthApi: reth_rpc_api::eth::helpers::EthCall,
    > PipeExecLayerApiTrait for PipeApiWrapper<Storage, EthApi>
where
    EthApi::NetworkTypes:
        reth_rpc_eth_api::RpcTypes<TransactionRequest = alloy_rpc_types_eth::TransactionRequest>,
{
    fn push_ordered_block(&self, block: OrderedBlock) -> Option<()> {
        self.inner.push_ordered_block(block)
    }
}
