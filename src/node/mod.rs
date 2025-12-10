pub mod buffer;
pub mod coordinator;
pub mod epoch;
pub mod setup;

pub use buffer::{BufferStatus, TransactionBuffer};
pub use epoch::get_current_epoch;
pub use setup::{GravityBenchNode, PipeExecLayerApiTrait};

/// Validator 1 address as a hex string (for proposer field in OrderedBlock)
pub const PROPOSER_ADDRESS1: &str =
    "0x2d86b40a1d692c0749a0a0426e2021ee24e2430da0f5bb9c2ae6c586bf3e0a0f";

// Validator [0]: "0x2d86b40a1d692c0749a0a0426e2021ee24e2430da0f5bb9c2ae6c586bf3e0a0f"
// Validator [1]: "0xcaafc5b658f0590d7e31de91edde7f05ae91961d0804ec634d7535969b7d171f"
// Validator [2]: "0x99d1c7709b14777edbdbe0c602eb0186ea845ed75b01740726e581215de8625b"
// Validator [3]: "0x7682dbbb2efe6a3e005b7fa13872e99f21165874b20cb9c8c877f8a0a0c5b779"
/// Convert a hex string (with or without "0x" prefix) to a 32-byte array.
///
/// # Arguments
/// * `hex_str` - Hex string representing 32 bytes (64 hex characters)
///
/// # Panics
/// Panics if the hex string is invalid or not exactly 32 bytes.
pub fn hex_to_32_bytes(hex_str: &str) -> [u8; 32] {
    hex::decode(hex_str.strip_prefix("0x").unwrap_or(hex_str))
        .expect("Invalid hex string")
        .try_into()
        .expect("Hex string must be exactly 32 bytes")
}
