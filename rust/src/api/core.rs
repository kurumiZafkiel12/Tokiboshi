//! Functions the Flutter UI calls. Keep them synchronous and simple:
//! all heavy state lives in `config` / `process`.

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

use crate::config::{self, CoreSettings, NodeSpec};

/// Validate raw sing-box config JSON. Empty result means valid.
pub fn validate_config(text: String) -> Vec<String> {
    config::validate_config(&text)
}

/// Build the full GUI-shell sing-box config for all nodes: selector
/// + urltest groups, route rule template, Clash API with the
/// zashboard UI, cache file persistence.
pub fn build_config(
    nodes: Vec<NodeSpec>,
    mixed_port: u16,
    clash_api_port: u16,
    enable_tun: bool,
    data_dir: String,
    selected_name: Option<String>,
) -> Result<String, String> {
    let settings = CoreSettings {
        mixed_port,
        clash_api_port,
        enable_tun,
        data_dir,
        ..CoreSettings::default()
    };
    config::build_config_multi(&nodes, &settings, selected_name.as_deref())
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
        Ok(slot) => match slot.as_ref() {
            Some(core) => core.state() == CoreState::Running,
            None => false,
        },
        Err(_) => false,
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct CoreStatus {
    pub running: bool,
    pub restart_count: u32,
    pub last_exit: Option<String>,
}

/// Supervision status of the managed core process.
pub fn core_status() -> CoreStatus {
    match CORE.lock() {
        Ok(slot) => match slot.as_ref() {
            Some(core) => CoreStatus {
                running: core.state() == CoreState::Running,
                restart_count: core.restart_count(),
                last_exit: core.last_exit(),
            },
            None => CoreStatus {
                running: false,
                restart_count: 0,
                last_exit: None,
            },
        },
        Err(_) => CoreStatus {
            running: false,
            restart_count: 0,
            last_exit: Some("core lock poisoned".to_string()),
        },
    }
}

/// Recent core log lines (bounded ring buffer, oldest first).
pub fn core_logs() -> Vec<String> {
    match CORE.lock() {
        Ok(slot) => slot.as_ref().map(|c| c.logs()).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

/// `sing-box version` first line for the binary at `binary_path`.
pub fn core_version(binary_path: String) -> Result<String, String> {
    CoreProcess::new(PathBuf::from(binary_path)).version()
}

// ---- managed core download (pinned sing-box stable) ----

use crate::core_download;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct EnsureState {
    /// idle | downloading | done | error
    pub phase: String,
    pub version: Option<String>,
    pub error: Option<String>,
}

static ENSURE: Mutex<Option<EnsureState>> = Mutex::new(None);
static ENSURE_RUNNING: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

fn set_ensure(state: EnsureState) {
    if let Ok(mut slot) = ENSURE.lock() {
        *slot = Some(state);
    }
}

/// Path of the managed sing-box binary under `data_dir`.
pub fn managed_core_path(data_dir: String) -> String {
    core_download::core_binary_path(std::path::Path::new(&data_dir))
        .to_string_lossy()
        .into_owned()
}

/// Kick off (in the background) downloading the pinned sing-box
/// release into `data_dir`, unless it is already up to date. Poll
/// `ensure_core_state` for progress.
pub fn start_ensure_core(data_dir: String) {
    if ENSURE_RUNNING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return; // a download is already in flight
    }
    let dir = PathBuf::from(&data_dir);
    if core_download::is_up_to_date(&dir) {
        set_ensure(EnsureState {
            phase: "done".to_string(),
            version: core_download::installed_version(&dir),
            error: None,
        });
        ENSURE_RUNNING.store(false, std::sync::atomic::Ordering::SeqCst);
        return;
    }
    set_ensure(EnsureState {
        phase: "downloading".to_string(),
        version: None,
        error: None,
    });
    std::thread::spawn(move || {
        let result = core_download::download_and_install(&dir);
        match result {
            Ok(version) => set_ensure(EnsureState {
                phase: "done".to_string(),
                version: Some(version),
                error: None,
            }),
            Err(e) => set_ensure(EnsureState {
                phase: "error".to_string(),
                version: None,
                error: Some(e),
            }),
        }
        ENSURE_RUNNING.store(false, std::sync::atomic::Ordering::SeqCst);
    });
}

pub fn ensure_core_state() -> EnsureState {
    match ENSURE.lock() {
        Ok(slot) => slot.clone().unwrap_or(EnsureState {
            phase: "idle".to_string(),
            version: None,
            error: None,
        }),
        Err(_) => EnsureState {
            phase: "error".to_string(),
            version: None,
            error: Some("ensure lock poisoned".to_string()),
        },
    }
}

/// Parse subscription content (links, base64 blob, Clash YAML, or
/// sing-box JSON config) into nodes plus skipped-entry notes.
pub fn parse_subscription(text: String) -> Result<crate::links::ParseOutcome, String> {
    crate::links::parse_subscription(&text)
}
