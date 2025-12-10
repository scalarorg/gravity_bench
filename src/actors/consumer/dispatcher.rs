use crate::eth::EthHttpCli;
use alloy::primitives::TxHash;
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

    async fn provider(&self, rpc: &str) -> Result<Arc<EthHttpCli>>;

    fn get_providers(&self) -> Vec<Arc<EthHttpCli>>;
}

/// Simple dispatcher that routes transactions based on txn_id modulo
#[derive(Clone)]
pub struct SimpleDispatcher {
    providers: Vec<Arc<EthHttpCli>>,
}

impl SimpleDispatcher {
    pub fn new(providers: Vec<EthHttpCli>) -> Self {
        let providers = providers.into_iter().map(Arc::new).collect();
        Self { providers }
    }

    /// Select provider based on txn_id hash
    fn select_provider(&self, txn_id: Uuid) -> &Arc<EthHttpCli> {
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

        debug!(
            "Batch dispatcher: selected provider rpc={}, batch_size={}, first_txn_id={:?}",
            rpc_url, batch_size, first_txn_id
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

    async fn provider(&self, rpc: &str) -> Result<Arc<EthHttpCli>> {
        let provider = self
            .providers
            .iter()
            .find(|p| p.rpc().as_str() == rpc)
            .ok_or(anyhow::anyhow!("Provider not found"))?;
        Ok(provider.clone())
    }

    fn get_providers(&self) -> Vec<Arc<EthHttpCli>> {
        self.providers.clone()
    }
}
