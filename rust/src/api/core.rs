//! Functions the Flutter UI calls. Keep them synchronous and simple:
//! all heavy state lives in `config` / `process`.

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

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

/// Parse one share link (vless/vmess/trojan/hysteria2/ss) into a node.
pub fn parse_share_link(link: String) -> Result<crate::links::NodeInfo, String> {
    crate::links::parse_share_link(&link)
}

// ---- sing-box core process (global, owned by the middle layer) ----

use crate::process::{CoreProcess, CoreState};
use std::path::PathBuf;
use std::sync::Mutex;

static CORE: Mutex<Option<CoreProcess>> = Mutex::new(None);

/// Validate the config with the real binary (`sing-box check`), then
/// start sing-box with it.
pub fn start_core(binary_path: String, config_path: String) -> Result<(), String> {
    let mut slot = CORE.lock().map_err(|_| "core lock poisoned".to_string())?;
    if let Some(core) = slot.as_mut() {
        if core.state() == CoreState::Running {
            return Err("sing-box is already running".to_string());
        }
    }
    let mut core = CoreProcess::new(PathBuf::from(&binary_path));
    core.check_config(std::path::Path::new(&config_path))?;
    core.start(std::path::Path::new(&config_path))?;
    *slot = Some(core);
    Ok(())
}

pub fn stop_core() -> Result<(), String> {
    let mut slot = CORE.lock().map_err(|_| "core lock poisoned".to_string())?;
    match slot.as_mut() {
        Some(core) => core.stop(),
        None => Ok(()),
    }
}

pub fn core_running() -> bool {
    match CORE.lock() {
        Ok(mut slot) => match slot.as_mut() {
            Some(core) => core.state() == CoreState::Running,
            None => false,
        },
        Err(_) => false,
    }
}

/// Parse subscription content (plain links, base64 blob, or sing-box
/// JSON config) into nodes.
pub fn parse_subscription(text: String) -> Result<Vec<crate::links::NodeInfo>, String> {
    crate::links::parse_subscription(&text)
}
