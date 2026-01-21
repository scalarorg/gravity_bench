use crate::eth::{EthHttpCli, FastEvmCli};
use alloy::primitives::{Address, TxHash};
use anyhow::Result;
use async_trait::async_trait;
use std::sync::Arc;
use tracing::{debug, info};
use uuid::Uuid;

/// Provider dispatcher trait for routing transactions to different providers
#[async_trait]
pub trait Dispatcher: Send + Sync {
    /// Send a transaction envelope to a provider selected by the dispatcher
    /// Returns (TxHash, RPC URL) on success
    async fn send_tx(
        &self,
        tx_bytes: Vec<u8>,
        txn_id: Uuid,
    ) -> std::result::Result<(TxHash, String), (anyhow::Error, String)>;
    /// Send multiple transactions in a batch to a provider
    /// Returns Vec<(TxHash, RPC URL)> on success
    /// This is more efficient than calling send_tx multiple times
    async fn send_txs(
        &self,
        tx_bytes_vec: Vec<(Vec<u8>, Uuid)>,
    ) -> std::result::Result<Vec<(TxHash, String)>, (anyhow::Error, String)>;

    /// Get a provider by RPC URL for querying transaction count
    async fn get_txn_count(&self, rpc: &str, address: Address) -> Result<u64>;

    /// Get all provider RPC URLs
    fn get_provider_urls(&self) -> Vec<String>;
}

/// Enum to hold either EthHttpCli or FastEvmCli
#[derive(Clone)]
pub enum TxClient {
    Eth(Arc<EthHttpCli>),
    FastEvm(Arc<FastEvmCli>),
}

impl TxClient {
    fn rpc(&self) -> Arc<String> {
        match self {
            TxClient::Eth(client) => client.rpc(),
            TxClient::FastEvm(client) => client.rpc(),
        }
    }

    async fn send_raw_tx(&self, tx_bytes: Vec<u8>) -> Result<TxHash> {
        match self {
            TxClient::Eth(client) => client.send_raw_tx(tx_bytes).await,
            TxClient::FastEvm(client) => client.send_raw_tx(tx_bytes).await,
        }
    }

    async fn send_raw_txs(&self, tx_bytes_vec: Vec<Vec<u8>>) -> Result<Vec<TxHash>> {
        match self {
            TxClient::Eth(client) => client.send_raw_txs(tx_bytes_vec).await,
            TxClient::FastEvm(client) => client.send_raw_txs(tx_bytes_vec).await,
        }
    }

    async fn get_txn_count(&self, address: Address) -> Result<u64> {
        match self {
            TxClient::Eth(client) => client.get_txn_count(address).await,
            TxClient::FastEvm(client) => client.get_txn_count(address).await,
        }
    }
}

/// Simple dispatcher that routes transactions based on txn_id modulo
#[derive(Clone)]
pub struct SimpleDispatcher {
    providers: Vec<TxClient>,
}

impl SimpleDispatcher {
    pub fn new_eth(providers: Vec<EthHttpCli>) -> Self {
        let len = providers.len();
        let providers = providers
            .into_iter()
            .map(|p| TxClient::Eth(Arc::new(p)))
            .collect();
        tracing::info!("SimpleDispatcher: Created with {} ETH providers", len);
        Self { providers }
    }

    pub fn new_fastevm(providers: Vec<FastEvmCli>) -> Self {
        let len = providers.len();
        let providers = providers
            .into_iter()
            .map(|p| TxClient::FastEvm(Arc::new(p)))
            .collect();
        tracing::info!("SimpleDispatcher: Created with {} FastEVM providers", len);
        Self { providers }
    }

    /// Select provider based on txn_id hash
    fn select_provider(&self, txn_id: Uuid) -> &TxClient {
        let hash = txn_id.as_u128();
        let index = (hash % self.providers.len() as u128) as usize;
        &self.providers[index]
    }
}

#[async_trait]
impl Dispatcher for SimpleDispatcher {
    async fn send_tx(
        &self,
        bytes: Vec<u8>,
        txn_id: Uuid,
    ) -> std::result::Result<(TxHash, String), (anyhow::Error, String)> {
        let provider = self.select_provider(txn_id);
        let rpc_url = provider.rpc().as_ref().clone();
        let tx_hash = provider
            .send_raw_tx(bytes)
            .await
            .map_err(|e| (e, provider.rpc().as_ref().clone()))?;

        Ok((tx_hash, rpc_url))
    }

    async fn send_txs(
        &self,
        tx_bytes_vec: Vec<(Vec<u8>, Uuid)>,
    ) -> std::result::Result<Vec<(TxHash, String)>, (anyhow::Error, String)> {
        if tx_bytes_vec.is_empty() {
            return Ok(Vec::new());
        }

        let batch_size = tx_bytes_vec.len();

        // Group transactions by provider (using first transaction's provider selection)
        // For simplicity, we'll use the first transaction's provider for the entire batch
        // In a more sophisticated implementation, we could group by provider
        let first_txn_id = tx_bytes_vec[0].1;
        let provider = self.select_provider(first_txn_id);
        let rpc_url = provider.rpc().as_ref().clone();

        // Log which client type is being used
        let client_type = match provider {
            TxClient::Eth(_) => "ETH (gravity_submitBatch)",
            TxClient::FastEvm(_) => "FastEVM (rawtx_sendRawTransactionsAsync)",
        };

        debug!(
            "Batch dispatcher: selected provider rpc={}, batch_size={}, first_txn_id={:?}, client_type={}",
            rpc_url, batch_size, first_txn_id, client_type
        );

        // Extract just the transaction bytes
        let tx_bytes_only: Vec<Vec<u8>> =
            tx_bytes_vec.into_iter().map(|(bytes, _)| bytes).collect();

        match provider.send_raw_txs(tx_bytes_only).await {
            Ok(hashes) => {
                // Map hashes to (hash, rpc_url) tuples
                Ok(hashes
                    .into_iter()
                    .map(|hash| (hash, rpc_url.clone()))
                    .collect())
            }
            Err(e) => {
                info!(
                    "❌ Dispatcher: Batch send failed: {} transactions failed, rpc={}, error={}",
                    batch_size, rpc_url, e
                );
                Err((e, rpc_url))
            }
        }
    }

    async fn get_txn_count(&self, rpc: &str, address: Address) -> Result<u64> {
        let provider = self
            .providers
            .iter()
            .find(|p| p.rpc().as_str() == rpc)
            .ok_or(anyhow::anyhow!("Provider not found"))?;
        provider.get_txn_count(address).await
    }

    fn get_provider_urls(&self) -> Vec<String> {
        self.providers
            .iter()
            .map(|p| p.rpc().as_str().to_string())
            .collect()
    }
}
