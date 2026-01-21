use alloy::{
    network::Ethereum,
    primitives::{Address, TxHash},
    providers::{Provider, ProviderBuilder, RootProvider},
};
use anyhow::{Context, Result};
use async_trait::async_trait;
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Instant;
use tokio::time::Duration;
use tracing::{debug, info, warn};
use url::Url;

use crate::eth::tx_client::TransactionClient;

// Note: rawtx_sendRawTransactionAsync and rawtx_sendRawTransactionsAsync return RpcResult<()>
// So we compute transaction hashes from the RLP-encoded transaction bytes

/// FastEVM client that uses custom rawtx RPC endpoints
#[derive(Clone)]
pub struct FastEvmCli {
    inner: Vec<Arc<RootProvider<Ethereum>>>,
    chain_id: u64,
    rpc: Arc<String>,
}

impl FastEvmCli {
    /// Create new FastEvmCli instance
    pub fn new(rpc_url: &str, chain_id: u64) -> Result<Self> {
        debug!(
            "Creating FastEvmCli for URL: {}, Chain ID: {}",
            rpc_url, chain_id
        );

        let url =
            Url::parse(rpc_url).with_context(|| format!("Failed to parse RPC URL: {}", rpc_url))?;
        let mut inner = Vec::new();
        for _ in 0..1 {
            let provider: RootProvider<Ethereum> =
                ProviderBuilder::default().connect_http(url.clone());
            inner.push(Arc::new(provider));
        }

        let client = Self {
            inner,
            chain_id,
            rpc: Arc::new(rpc_url.to_string()),
        };

        debug!("FastEvmCli created successfully");
        Ok(client)
    }

    pub fn rpc(&self) -> Arc<String> {
        self.rpc.clone()
    }

    #[allow(unused)]
    pub fn chain_id(&self) -> u64 {
        self.chain_id
    }

    /// Get transaction count (nonce) for an address using standard eth_getTransactionCount
    pub async fn get_txn_count(&self, address: Address) -> Result<u64> {
        tokio::time::timeout(Duration::from_secs(10), async {
            let nonce = self.inner[0].get_transaction_count(address).await?;
            Ok(nonce)
        })
        .await?
    }

    /// Send a single raw transaction using rawtx_sendRawTransactionAsync
    /// Note: The RPC method returns RpcResult<()>, so we compute the hash from the RLP-encoded bytes
    pub async fn send_raw_tx(&self, tx_bytes: Vec<u8>) -> Result<TxHash> {
        let idx = rand::thread_rng().gen_range(0..self.inner.len());

        // Compute transaction hash from RLP-encoded bytes before sending
        // The bytes are already RLP-encoded, so we can hash them directly
        let tx_hash = alloy::primitives::keccak256(&tx_bytes);

        let op = async {
            // Send Vec<u8> directly - jsonrpsee will serialize it as an array of integers
            // The server expects Bytes = Vec<u8>, which serializes as [249, 14, 216, 128, ...]
            // NOT as a hex string "0xf90ed880..."

            debug!(
                "FastEvmCli: Calling rawtx_sendRawTransactionAsync, rpc={}",
                self.rpc
            );

            // Call rawtx_sendRawTransactionAsync (returns RpcResult<()>)
            // Pass Vec<u8> directly so it serializes as an array of integers
            let _: () = self.inner[idx]
                .raw_request::<(Vec<u8>,), ()>(
                    "rawtx_sendRawTransactionAsync".into(),
                    (tx_bytes.clone(),),
                )
                .await
                .map_err(|e| anyhow::anyhow!("rawtx_sendRawTransactionAsync failed: {}", e))?;

            anyhow::Ok(tx_hash)
        };

        let result = tokio::time::timeout(Duration::from_secs(10), op).await;

        let final_result = match result {
            Ok(Ok(hash)) => Ok(hash),
            Ok(Err(e)) => Err(anyhow::Error::from(e)),
            Err(e) => Err(anyhow::Error::from(e)),
        };

        if final_result.is_ok() {
            debug!(
                "FastEvmCli: Transaction sent via rawtx_sendRawTransactionAsync, hash={:?}, rpc={}",
                tx_hash, self.rpc
            );
        } else {
            warn!(
                "FastEvmCli: Failed to send transaction via rawtx_sendRawTransactionAsync, rpc={}, error={:?}",
                self.rpc,
                final_result.as_ref().err()
            );
        }

        final_result
    }

    /// Send multiple raw transactions using rawtx_sendRawTransactionsAsync
    /// Note: The RPC method returns RpcResult<()>, so we compute hashes from the RLP-encoded bytes
    pub async fn send_raw_txs(&self, tx_bytes_vec: Vec<Vec<u8>>) -> Result<Vec<TxHash>> {
        if tx_bytes_vec.is_empty() {
            return Ok(Vec::new());
        }

        let batch_size = tx_bytes_vec.len();
        let idx = rand::thread_rng().gen_range(0..self.inner.len());
        let rpc_url = self.rpc.as_str();
        let start = Instant::now();

        // Compute transaction hashes from RLP-encoded bytes before sending
        let tx_hashes: Vec<TxHash> = tx_bytes_vec
            .iter()
            .map(|bytes| alloy::primitives::keccak256(bytes))
            .collect();

        // Keep as Vec<Vec<u8>> - jsonrpsee will serialize Vec<u8> as an array of integers
        // The server expects Vec<Bytes> where Bytes = Vec<u8>, which serializes as [[249, 14, ...], [250, 15, ...], ...]
        // NOT as an array of hex strings ["0xf90e...", "0xfa0f...", ...]

        let op = async {
            debug!(
                "FastEvmCli: Calling rawtx_sendRawTransactionsAsync with {} transactions, rpc={}",
                tx_bytes_vec.len(),
                self.rpc
            );

            // Call rawtx_sendRawTransactionsAsync (returns RpcResult<()>)
            // Pass Vec<Vec<u8>> directly so each Vec<u8> serializes as an array of integers
            let _: () = self.inner[idx]
                .raw_request::<(Vec<Vec<u8>>,), ()>(
                    "rawtx_sendRawTransactionsAsync".into(),
                    (tx_bytes_vec.clone(),),
                )
                .await
                .map_err(|e| anyhow::anyhow!("rawtx_sendRawTransactionsAsync failed: {:?}:", e))?;

            anyhow::Ok(tx_hashes)
        };

        let result = tokio::time::timeout(Duration::from_secs(30), op).await;

        match result {
            Ok(Ok(hashes)) => {
                let elapsed = start.elapsed();
                info!(
                    "✅ FastEvmCli: Batch RPC call succeeded: {} transactions sent in {:?} via rawtx_sendRawTransactionsAsync to {}",
                    hashes.len(),
                    elapsed,
                    rpc_url
                );
                Ok(hashes)
            }
            Ok(Err(e)) => {
                let elapsed = start.elapsed();
                warn!(
                    "❌ FastEvmCli: Batch RPC call failed: {} transactions failed after {:?}, rpc={}, error={:?}",
                    batch_size,
                    elapsed,
                    rpc_url,
                    e
                );
                Err(anyhow::Error::from(e))
            }
            Err(e) => {
                warn!(
                    "❌ FastEvmCli: Batch RPC call timed out after 30s, rpc={}, error={:?}",
                    rpc_url, e
                );
                Err(anyhow::Error::from(e))
            }
        }
    }
}

#[async_trait]
impl TransactionClient for FastEvmCli {
    fn rpc(&self) -> Arc<String> {
        FastEvmCli::rpc(self)
    }

    async fn get_txn_count(&self, address: Address) -> Result<u64> {
        FastEvmCli::get_txn_count(self, address).await
    }

    async fn send_raw_tx(&self, tx_bytes: Vec<u8>) -> Result<TxHash> {
        FastEvmCli::send_raw_tx(self, tx_bytes).await
    }

    async fn send_raw_txs(&self, tx_bytes_vec: Vec<Vec<u8>>) -> Result<Vec<TxHash>> {
        FastEvmCli::send_raw_txs(self, tx_bytes_vec).await
    }
}
