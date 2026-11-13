//! Functions the Flutter UI calls. Keep them synchronous and simple:
//! all heavy state lives in `config` / `process`.

use crate::config::{self, CoreSettings};
use serde_json::Value;

/// Validate raw sing-box config JSON. Empty result means valid.
pub fn validate_config(text: String) -> Vec<String> {
    config::validate_config(&text)
}

/// Build a full sing-box config around one outbound JSON object.
pub fn build_config(outbound_json: String, mixed_port: u16, enable_tun: bool) -> Result<String, String> {
    let outbound: Value =
        serde_json::from_str(&outbound_json).map_err(|e| format!("invalid outbound JSON: {e}"))?;
    let settings = CoreSettings { mixed_port, enable_tun, ..CoreSettings::default() };
    config::build_config(&outbound, &settings)
}

/// Version of the Rust middle layer (not of sing-box).
pub fn bridge_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
