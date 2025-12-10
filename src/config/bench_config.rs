use alloy::primitives::U256;
use anyhow::{Context, Result};
use serde::{Deserialize, Deserializer, Serialize};
use std::path::Path;

/// Complete configuration structure
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct BenchConfig {
    pub nodes: Vec<NodeConfig>,
    pub faucet: FaucetConfig,
    pub accounts: AccountConfig,
    pub performance: PerformanceConfig,
    pub contract_config_path: String,
    pub num_tokens: usize,
    pub target_tps: u64,
    pub enable_swap_token: bool,
}

/// Node and chain configuration
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct NodeConfig {
    pub rpc_url: String,
    pub chain_id: u64,
}

fn from_str_to_u256<'de, D>(deserializer: D) -> Result<U256, D::Error>
where
    D: Deserializer<'de>,
{
    let s = String::deserialize(deserializer)?;
    Ok(U256::from_str_radix(&s, 10).map_err(serde::de::Error::custom)?)
}

/// Faucet and deployer account configuration
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct FaucetConfig {
    pub private_key: String,
    pub faucet_level: u32,
    pub wait_duration_secs: u64,
    #[serde(deserialize_with = "from_str_to_u256")]
    pub fauce_eth_balance: U256,
}

/// Load testing account configuration
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AccountConfig {
    pub num_accounts: usize,
}

/// Performance and stress configuration
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PerformanceConfig {
    /// Number of concurrent transaction sending tasks inside TxnConsumer
    pub num_senders: usize,
    /// Maximum capacity of the transaction pool inside Consumer
    pub max_pool_size: usize,
    /// Duration of the benchmark in seconds
    pub duration_secs: u64,
    /// Batch size for batch transaction sending (0 = disabled, use individual sending)
    /// Recommended: 100-1000 for optimal performance
    #[serde(default = "default_batch_size")]
    pub batch_size: usize,
    /// Batch timeout in milliseconds - send batch even if not full after this timeout
    /// Recommended: 50-200ms for low latency, 200-500ms for higher throughput
    #[serde(default = "default_batch_timeout_ms")]
    pub batch_timeout_ms: u64,
}

fn default_batch_size() -> usize {
    // Default batch size
    100
}

fn default_batch_timeout_ms() -> u64 {
    // Default 100ms timeout
    100
}

impl BenchConfig {
    /// Load configuration from TOML file
    pub fn load<P: AsRef<Path>>(path: P) -> Result<Self> {
        let content = std::fs::read_to_string(path.as_ref())
            .with_context(|| format!("Failed to read config file: {:?}", path.as_ref()))?;

        let config: BenchConfig =
            toml::from_str(&content).with_context(|| "Failed to parse config file as TOML")?;

        Ok(config)
    }
}
