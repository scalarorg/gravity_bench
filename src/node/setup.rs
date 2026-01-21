use alloy::primitives::{Address, B256, U256};
use alloy_rpc_types_eth::TransactionRequest;
use anyhow::Result;
use greth::reth_pipe_exec_layer_ext_v2::{OrderedBlock, PipeExecLayerApi};
use reth_rpc_api::eth::helpers::EthCall;
use reth_rpc_eth_api::RpcTypes;
use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::{mpsc, Mutex, RwLock};
use tracing::{debug, info, warn};

use crate::node::buffer::TransactionBuffer;
use crate::node::get_current_epoch;
/// Gravity node setup for benchmarking
pub struct GravityBenchNode {
    epoch: Arc<RwLock<u64>>,
    pipe_api: Arc<Mutex<Option<Arc<dyn PipeExecLayerApiTrait>>>>,
    buffer: Arc<TransactionBuffer>,
    batch_size: usize,
    block_interval_ms: u64,
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
    ) -> Result<Self> {
        info!("GravityBenchNode initialized");
        info!("Note: Pipe API will be set when gravity node is started");
        info!("Please start gravity_node separately with MOCK_CONSENSUS=true");

        Ok(Self {
            epoch: Arc::new(RwLock::new(0)),
            pipe_api: Arc::new(Mutex::new(None)),
            buffer,
            batch_size,
            block_interval_ms,
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
    /// This function uses a queue-based pattern:
    /// 1. Interval task: Periodically creates OrderedBlocks and adds them to a queue
    /// 2. Event handler: Listens for block execution completion signals from coordinator,
    ///    and sends blocks from the queue to pipe_api when signals are received
    ///
    /// # Arguments
    /// * `pipe_api` - Pipe API for injecting OrderedBlocks
    /// * `eth_api` - Eth API for fetching epoch from contract
    /// * `block_executed_rx` - Channel receiver for block execution completion signals from coordinator
    /// * `proposer` - Proposer address for OrderedBlock
    /// * `last_created_block_number` - Last created block number
    /// * `last_created_block_id` - Last created block ID
    pub async fn run_injection_loop<EthApi>(
        &self,
        pipe_api: Arc<Mutex<Option<Arc<dyn PipeExecLayerApiTrait>>>>,
        eth_api: EthApi,
        mut block_executed_rx: mpsc::UnboundedReceiver<(u64, Option<u64>)>,
        proposer: Option<[u8; 32]>,
        last_created_block_number: u64,
        last_created_block_id: B256,
    ) where
        EthApi: EthCall + reth_rpc_api::eth::helpers::EthState + Send + Sync + 'static,
        EthApi::NetworkTypes: RpcTypes<TransactionRequest = TransactionRequest>,
    {
        info!(
            "🚀 [GravityBenchNode] Starting OrderedBlock injection loop: batch_size={}, block_interval_ms={}ms",
            self.batch_size,
            self.block_interval_ms
        );
        let mut lastest_block_number = last_created_block_number;
        let mut lastest_block_time: Option<u64> = None;
        let mut lastest_block_id = last_created_block_id;
        // OrderedBlock queue: stores blocks waiting to be sent to pipe_api
        let block_queue: Arc<Mutex<VecDeque<OrderedBlock>>> = Arc::new(Mutex::new(VecDeque::new()));
        // Channel to signal when a new OrderedBlock is created
        let (block_created_tx, mut block_created_rx) = mpsc::unbounded_channel::<()>();
        // Shared state for last sent time
        let last_sent_time = Arc::new(Mutex::new(0u128));
        // Shared state: latest executed block number (from coordinator signals)
        let latest_executed_block = Arc::new(RwLock::new(last_created_block_number));
        // Shared state: latest sent block number (to track what we've sent to pipe)
        let latest_sent_block = Arc::new(RwLock::new(last_created_block_number));
        let current_epoch = get_current_epoch(&eth_api, last_created_block_number).await;
        *self.epoch.write().await = current_epoch;
        // Create empty NIL OrderedBlock
        if let Some(empty_nil_block) = Self::create_ordered_block(
            current_epoch,
            last_created_block_number,
            last_created_block_id,
            None,
            &self.buffer,
            self.batch_size,
            self.block_interval_ms,
            proposer.clone(),
        )
        .await
        {
            block_queue.lock().await.push_back(empty_nil_block);
            let _ = block_created_tx.send(());
        }
        // Spawn event handler task: listens to block execution completion signals from coordinator
        let event_pipe_api = pipe_api.clone();
        let event_block_queue = block_queue.clone();
        let event_eth_api = eth_api.clone();
        let event_last_sent_time = last_sent_time.clone();
        let event_latest_executed_block = latest_executed_block.clone();
        let event_latest_sent_block = latest_sent_block.clone();
        let current_epoch_arc = self.epoch.clone();
        tokio::spawn(async move {
            info!(
                "[GravityBenchNode] Event handler task started - listening to block execution completion signals from coordinator and block creation events"
            );
            loop {
                tokio::select! {
                    // Listen for block execution completion signal from coordinator
                    executed_block_number = block_executed_rx.recv() => {
                        match executed_block_number {
                            Some((executed_block_number, new_epoch)) => {
                                // Update epoch
                                if let Some(epoch) = new_epoch {
                                    *current_epoch_arc.write().await = epoch;
                                }
                                // Update latest executed block number
                                *event_latest_executed_block.write().await = executed_block_number;
                                
                                // Try to send block from queue to pipe_api
                                let latest_executed = *event_latest_executed_block.read().await;
                                let latest_sent = *event_latest_sent_block.read().await;
                                let (sent_time, block_number, block_timestamp, tx_count, queue_size) = Self::try_send_block_from_queue(&event_pipe_api, &event_block_queue, latest_executed, &event_latest_sent_block, &current_epoch_arc).await;
                                if sent_time > 0 {
                                    let prev_sent_time = *event_last_sent_time.lock().await;
                                    info!("✅ [GravityBenchNode] Successfully sent block to pipe exec layer. [BlockExecuted] Elapsed time={} milliseconds, block number={} with {} transactions, time in queue {} ms, block queue size={}, latest_sent={}, latest_executed={}",
                                        sent_time - prev_sent_time,
                                        block_number,
                                        tx_count,
                                        sent_time - block_timestamp as u128 * 1000,
                                        queue_size,
                                        latest_sent,
                                        latest_executed
                                    );
                                    *event_last_sent_time.lock().await = sent_time;
                                } else {
                                    let queue_info = {
                                        let queue = event_block_queue.lock().await;
                                        if queue.is_empty() {
                                            "empty".to_string()
                                        } else {
                                            let first = queue.front().map(|b| b.number).unwrap_or(0);
                                            let last = queue.back().map(|b| b.number).unwrap_or(0);
                                            format!("blocks {}-{}", first, last)
                                        }
                                    };
                                    info!("⏳ [GravityBenchNode] No block available in queue to send. Queue: {}, latest_sent={}, latest_executed={}", queue_info, latest_sent, latest_executed);
                                }
                            }
                            None => {
                                warn!("[GravityBenchNode] Block execution signal channel closed");
                                break;
                            }
                        }
                    }
                    // Listen for new block creation events and try to send to pipe_api
                    _ = block_created_rx.recv() => {
                        // Try to send block from queue using latest executed block number
                        let latest_executed = *event_latest_executed_block.read().await;
                        let latest_sent = *event_latest_sent_block.read().await;
                        let (sent_time, block_number, block_timestamp, tx_count, queue_size) 
                            = Self::try_send_block_from_queue(
                                &event_pipe_api, 
                                &event_block_queue, 
                                latest_executed, 
                                &event_latest_sent_block, 
                                &current_epoch_arc).await;
                        if sent_time > 0 {
                            let prev_sent_time = *event_last_sent_time.lock().await;
                            info!("✅ [GravityBenchNode] Successfully sent block to pipe exec layer. [BlockCreated] Elapsed time={} milliseconds, block number={} with {} transactions, time in queue {} ms, block queue size={}, latest_sent={}, latest_executed={}",
                                sent_time - prev_sent_time,
                                block_number,
                                tx_count,
                                sent_time - block_timestamp as u128 * 1000,
                                queue_size,
                                latest_sent,
                                latest_executed
                            );
                            *event_last_sent_time.lock().await = sent_time;
                        } else {
                            let queue_info = {
                                let queue = event_block_queue.lock().await;
                                if queue.is_empty() {
                                    "empty".to_string()
                                } else {
                                    let first = queue.front().map(|b| b.number).unwrap_or(0);
                                    let last = queue.back().map(|b| b.number).unwrap_or(0);
                                    format!("blocks {}-{}", first, last)
                                }
                            };
                            debug!("⏳ [GravityBenchNode] Block created but not ready to send yet. Queue: {}, latest_sent={}, latest_executed={}", queue_info, latest_sent, latest_executed);
                        }
                    }
                }
            }
            warn!("[GravityBenchNode] Event handler task ended");
        });

        // Main thread: interval task creates OrderedBlocks and adds them to the queue
        info!("[GravityBenchNode] Interval task started - creating OrderedBlocks");
        let mut interval = tokio::time::interval(Duration::from_millis(self.block_interval_ms));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            interval.tick().await;
            // Create the next block and add to queue
            if let Some(ordered_block) = Self::create_ordered_block(
                *self.epoch.read().await,
                lastest_block_number, //
                lastest_block_id,
                lastest_block_time,
                &self.buffer,
                self.batch_size,
                self.block_interval_ms,
                proposer.clone(),
            )
            .await
            {
                // Update local state
                lastest_block_number = ordered_block.number;
                lastest_block_time = Some(ordered_block.timestamp_us);
                lastest_block_id = ordered_block.id;
                // Add block to queue
                {
                    let mut queue = block_queue.lock().await;
                    queue.push_back(ordered_block);
                }
                // Signal that a new block was created
                let _ = block_created_tx.send(());
            }
        }
    }

    /// Helper function to create an OrderedBlock without sending it to pipe_api
    /// Returns (block_number, block_timestamp, ordered_block) if successful
    async fn create_ordered_block(
        epoch: u64,
        latest_block_number: u64,
        parent_id: B256,
        last_created_block_time: Option<u64>,
        buffer: &Arc<TransactionBuffer>,
        batch_size: usize,
        block_interval_ms: u64,
        proposer: Option<[u8; 32]>,
    ) -> Option<OrderedBlock> {
        let current_time = std::time::SystemTime::now()
            .duration_since(std::time::SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        // Check if we need to wait for block_interval_ms before creating the next block
        if let Some(last_time) = last_created_block_time {
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
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        // Get transactions from simple transaction buffer
        let txn_buffer_len = buffer.len().await;
        let new_block_number = latest_block_number + 1;

        let batch = {
            if txn_buffer_len == 0 || latest_block_number == 0 {
                Vec::new()
            } else {
                buffer.take_batch(batch_size).await
            }
        };
        info!("🔨 [GravityBenchNode] Creating OrderedBlock #{} with {} transactions. Remaining transactions in buffer: {}", 
            new_block_number,
            batch.len(),
            txn_buffer_len - batch.len()
        );
        // for (i, tx) in batch.iter().enumerate() {
        //     info!("🔨 [GravityBenchNode] Transaction {}: {:?}", i + 1, tx.0.hash());
        // }
        // // Get the latest canonical block hash to use as parent_id for the new OrderedBlock
        // let latest_block_hash = provider
        //     .block_hash(latest_block_number)
        //     .ok()
        //     .flatten()
        //     .unwrap_or(B256::ZERO);

        // Generate block ID
        let block_id = {
            let mut input = Vec::with_capacity(16);
            input.extend_from_slice(&new_block_number.to_be_bytes());
            input.extend_from_slice(&timestamp.to_be_bytes());
            alloy::primitives::keccak256(input)
        };
        // Use the latest canonical block hash as parent_id
        // For genesis block (block_number=0), parent_id will be B256::ZERO
        // let parent_id = latest_block_hash;

        let (txs, senders): (Vec<_>, Vec<_>) = batch.into_iter().unzip();
        let tx_count = txs.len();
        // Fetch current epoch from the EpochManager contract
        let ordered_block = OrderedBlock {
            epoch,
            parent_id,
            id: block_id,
            number: new_block_number,
            timestamp_us: timestamp,
            coinbase: Address::ZERO,
            prev_randao: B256::ZERO,
            withdrawals: Default::default(),
            transactions: txs,
            senders: senders.clone(),
            proposer,
            extra_data: vec![],
            randomness: U256::ZERO,
            enable_randomness: false,
        };
        info!(
            "🔨 [GravityBenchNode] Creating OrderedBlock #{}, {} transactions from buffer, parent_id={:?}, block_id={:?}",
            new_block_number,
            tx_count,
            parent_id,
            block_id
        );
        Some(ordered_block)
    }

    /// Helper function to send a block from the queue to pipe_api
    /// Returns (elapsed time in milliseconds, block_number, block_timestamp, transactions count, queue size)
    async fn try_send_block_from_queue(
        pipe_api: &Arc<Mutex<Option<Arc<dyn PipeExecLayerApiTrait>>>>,
        block_queue: &Arc<Mutex<VecDeque<OrderedBlock>>>,
        latest_executed_block_number: u64,
        latest_sent_block: &Arc<RwLock<u64>>,
        current_epoch: &Arc<RwLock<u64>>,
    ) -> (u128, u64, u64, usize, usize)
    {
        let first_block_number = {
            let queue = block_queue.lock().await;
            queue.front().map(|block| block.number)
        };
        if first_block_number.is_none() {
            info!("⏳ [GravityBenchNode] No block available in queue to send");
            return (0, 0, 0, 0, 0);
        }
        let first_block_number = first_block_number.unwrap();
        
        // Check if we can send the next block
        // The block number should be exactly latest_executed_block_number + 1
        // We can only send if the first block in queue is the next block after the latest executed block
        let expected_block_number = latest_executed_block_number + 1;
        if first_block_number != expected_block_number {
            if first_block_number > expected_block_number {
                info!("⏳ [GravityBenchNode] Try to send block for execution but block number {} is ahead of expected block {} (latest executed: {}), continue to wait", first_block_number, expected_block_number, latest_executed_block_number);
            } else {
                debug!("⏳ [GravityBenchNode] Block number {} is behind expected block {} (latest executed: {}), skipping", first_block_number, expected_block_number, latest_executed_block_number);
            }
            return (0, 0, 0, 0, block_queue.lock().await.len());
        }
        // Try to pop a block from the queue
        let (ordered_block, queue_size) = {
            let mut queue = block_queue.lock().await;
            let block = queue.pop_front();
            (block, queue.len())
        };

        // Fetch current epoch from the EpochManager contract
        // let current_epoch = get_current_epoch(eth_api, latest_executed_block_number).await;
        let current_epoch = *current_epoch.read().await;
        let mut ordered_block = ordered_block.unwrap();
        ordered_block.epoch = current_epoch;
        let block_number = ordered_block.number;
        let block_timestamp = ordered_block.timestamp_us;
        let tx_count = ordered_block.transactions.len();
        let block_id = ordered_block.id;
        info!(
            "📦 [GravityBenchNode] Sending block to pipe exec layer: block_number={}, block_timestamp={}, block_id={}",
            block_number,
            block_timestamp,
            block_id
        );
        let pipe_api_guard = pipe_api.lock().await;
        if let Some(api) = pipe_api_guard.as_ref() {
            api.push_ordered_block(ordered_block);
            // Update latest sent block number
            *latest_sent_block.write().await = block_number;
            info!(
                "✅ [GravityBenchNode] Successfully injected OrderedBlock #{} into pipe exec layer:
                    epoch={}, latest executed block number={}, {} transactions, block_id={:?}, timestamp={}. Block queue size={}",
                    block_number,
                    current_epoch,
                    latest_executed_block_number,                   
                    tx_count,
                    block_id,
                    block_timestamp,
                    queue_size,
            );
            let current_time = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_millis() as u128;
            (current_time, block_number, block_timestamp, tx_count, queue_size)
        } else {
            info!("⏳ [GravityBenchNode] No pipe API available, skipping block sending");
            return (0, 0, 0, 0, 0);
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
