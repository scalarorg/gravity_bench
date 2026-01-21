use alloy::primitives::Address;
use alloy_rpc_types_eth::TransactionTrait;
use reth_primitives::TransactionSigned;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::{debug, info};

/// Buffer for storing transactions before OrderedBlock creation
pub struct TransactionBuffer {
    transactions: Arc<Mutex<VecDeque<(TransactionSigned, Address)>>>,
    max_size: usize,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct BufferStatus {
    pub queued: usize,
    pub max_size: usize,
}

impl TransactionBuffer {
    pub fn new() -> Self {
        Self {
            transactions: Arc::new(Mutex::new(VecDeque::new())),
            max_size: 1_000_000, // Default max size
        }
    }

    pub fn with_max_size(max_size: usize) -> Self {
        Self {
            transactions: Arc::new(Mutex::new(VecDeque::new())),
            max_size,
        }
    }

    /// Add a transaction to the buffer
    /// Returns true if added, false if buffer is full
    pub async fn add_transaction(&self, tx: TransactionSigned, sender: Address) -> bool {
        let mut txs = self.transactions.lock().await;
        let current_len = txs.len();

        if current_len >= self.max_size {
            debug!(
                "⚠️ [Buffer] Transaction rejected: buffer full (size={}/{})",
                current_len, self.max_size
            );
            return false;
        }

        txs.push_back((tx.clone(), sender));
        let new_len = txs.len();

        debug!(
            "📥 [Buffer] Transaction added: hash={:?}, sender={}, buffer_size={}/{}",
            tx.hash(),
            sender,
            new_len,
            self.max_size
        );

        // Log when buffer reaches certain thresholds
        if new_len % 1000 == 0 || new_len == 1 {
            info!(
                "📦 [Buffer] Buffer status: {} transactions queued (max: {})",
                new_len, self.max_size
            );
        }

        true
    }

    /// Add a batch of transactions to the buffer
    pub async fn add_transactions(&self, txs: Vec<(TransactionSigned, Address)>) -> bool {
        let mut buffer = self.transactions.lock().await;
        let current_len = buffer.len();
        let len: usize = txs.len();
        if current_len + len > self.max_size {
            debug!(
                "⚠️ [Buffer] Transaction rejected: buffer full (size={} + {} > {})",
                current_len, len, self.max_size,
            );
            return false;
        }
        buffer.extend(txs);
        debug!(
            "📥 [Buffer] Transactions added: buffer_size increased from {}  + {} = {}",
            current_len,
            len,
            buffer.len()
        );
        true
    }

    /// Take a batch of transactions from the buffer
    /// Transactions in batch are ordered by sender's nonce
    pub async fn take_batch(&self, size: usize) -> Vec<(TransactionSigned, Address)> {
        let mut txs = self.transactions.lock().await;
        let before_len = txs.len();
        let mut batch = Vec::new();
        // Store transaction indexes as in the original txs;
        let mut senders = Vec::new();
        let mut map_sender_txs = HashMap::new();
        for _ in 0..size {
            if let Some((tx, addr)) = txs.pop_front() {
                senders.push(addr.clone());
                map_sender_txs
                    .entry(addr)
                    .or_insert(BTreeMap::new())
                    .insert(tx.nonce(), tx);
            } else {
                break;
            }
        }
        for sender in senders {
            if let Some((_, tx)) = map_sender_txs.get_mut(&sender).unwrap().pop_first() {
                batch.push((tx, sender));
            }
        }
        let after_len = txs.len();
        let batch_size = batch.len();

        if batch_size > 0 {
            debug!(
                "📤 [Buffer] Batch taken: {} transactions (buffer: {} -> {})",
                batch_size, before_len, after_len
            );
        }

        batch
    }

    /// Get current buffer status
    pub async fn get_status(&self) -> BufferStatus {
        let txs = self.transactions.lock().await;
        BufferStatus {
            queued: txs.len(),
            max_size: self.max_size,
        }
    }

    /// Get current buffer size
    pub async fn len(&self) -> usize {
        let txs = self.transactions.lock().await;
        txs.len()
    }
}

impl Default for TransactionBuffer {
    fn default() -> Self {
        Self::new()
    }
}
