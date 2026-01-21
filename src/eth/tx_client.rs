use alloy::primitives::{Address, TxHash};
use anyhow::Result;
use async_trait::async_trait;
use std::sync::Arc;

/// Trait for transaction sending clients
/// Both EthHttpCli and FastEvmCli implement this trait
#[async_trait]
pub trait TransactionClient: Send + Sync {
    /// Get the RPC URL
    fn rpc(&self) -> Arc<String>;

    /// Get transaction count (nonce) for an address
    async fn get_txn_count(&self, address: Address) -> Result<u64>;

    /// Send a single raw transaction
    async fn send_raw_tx(&self, tx_bytes: Vec<u8>) -> Result<TxHash>;

    /// Send multiple raw transactions in a batch
    async fn send_raw_txs(&self, tx_bytes_vec: Vec<Vec<u8>>) -> Result<Vec<TxHash>>;
}

