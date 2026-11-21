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
///
/// T069: the subscription-carried profile reaches this through
/// ParseOutcome.profile_json (stored per subscription and injected by
/// the Dart layer after FRB regen — see handoff doc).
pub fn build_config(
    nodes: Vec<NodeSpec>,
    mixed_port: u16,
    clash_api_port: u16,
    enable_tun: bool,
    block_ads: bool,
    bypass_cn: bool,
    data_dir: String,
    selected_name: Option<String>,
    profile_json: String,
) -> Result<String, String> {
    let settings = CoreSettings {
        mixed_port,
        clash_api_port,
        enable_tun,
        block_ads,
        bypass_cn,
        data_dir,
        ..CoreSettings::default()
    };
    let profile: Option<crate::profile::ParsedProfile> = if profile_json.trim().is_empty() {
        None
    } else {
        let parsed: crate::profile::ParsedProfile = serde_json::from_str(&profile_json)
            .map_err(|_| "订阅 profile 数据无效，拒绝回退内置规则".to_string())?;
        if !parsed.unsupported.is_empty() {
            return Err(format!("订阅规则不兼容，未应用：{}", parsed.unsupported.join("；")));
        }
        Some(parsed)
    };
    config::build_config_multi(&nodes, &settings, selected_name.as_deref(), profile.as_ref())
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

use crate::process::{is_elevated, CoreProcess, CoreState};
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
    let config: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&config_path).map_err(|e| e.to_string())?
    ).map_err(|e| e.to_string())?;
    let mut listeners = Vec::new();
    if let Some(inbounds) = config["inbounds"].as_array() {
        for inbound in inbounds {
            if inbound["type"] == "mixed" {
                if let Some(port) = inbound["listen_port"].as_u64() {
                    let host = inbound["listen"].as_str().unwrap_or("127.0.0.1");
                    let address = host.parse::<std::net::IpAddr>()
                        .map(|ip| std::net::SocketAddr::new(ip, port as u16).to_string())
                        .unwrap_or_else(|_| format!("{host}:{port}"));
                    listeners.push(address);
                }
            }
        }
    }
    // TUN preflight: without admin the core would FATAL on interface
    // setup immediately after listening. Refuse with a clear message
    // instead of looping a kernel that can never come up.
    let wants_tun = config["inbounds"].as_array().is_some_and(|list| {
        list.iter().any(|inbound| inbound["type"] == "tun")
    });
    if wants_tun && !is_elevated() {
        return Err(
            "虚拟网卡（TUN）需要管理员权限：请在仪表盘关闭虚拟网卡开关，或以管理员身份重新运行 Tokiboshi"
                .to_string(),
        );
    }
    if let Some(addr) = config["experimental"]["clash_api"]["external_controller"].as_str() {
        listeners.push(addr.to_string());
    }
    // A config check doesn't bind sockets. Detect occupied ports before spawn,
    // then wait for actual listeners before the UI enables the system proxy.
    for addr in &listeners {
        std::net::TcpListener::bind(addr).map_err(|_| format!(
            "本地端口 {addr} 被占用或不可用，请修改设置中的端口或关闭占用该端口的软件"))?;
    }
    if let Some(ui) = config["experimental"]["clash_api"]["external_ui"].as_str().filter(|p| !p.is_empty()) {
        crate::core_download::prepare_dashboard(std::path::Path::new(ui))?;
    }
    core.start(std::path::Path::new(&config_path))?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut ready = vec![false; listeners.len()];
    loop {
        std::thread::sleep(std::time::Duration::from_millis(100));
        if core.state() == CoreState::Stopped || std::time::Instant::now() >= deadline {
            let lines = core.logs();
            let details = lines.iter().rev().filter(|line| !line.contains("inbound connection from"))
                .take(12).cloned().collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");
            let pending = listeners.iter().zip(&ready).filter(|(_, ready)| !**ready)
                .map(|(addr, _)| addr.as_str()).collect::<Vec<_>>().join(", ");
            let _ = core.stop();
            *slot = Some(core); // Keep fatal output available on the Logs page.
            return Err(format!("内核启动失败，监听端口未就绪 ({pending})：{details}"));
        }
        for (i, addr) in listeners.iter().enumerate() {
            if !ready[i] {
                ready[i] = readiness_address(addr).is_some_and(|address|
                    std::net::TcpStream::connect_timeout(&address, std::time::Duration::from_millis(100)).is_ok());
            }
        }
        if ready.iter().all(|ready| *ready) { break; }
    }
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

/// Recent core log lines (bounded ring buffer, oldest first), with
/// background-work diagnostics (rule-set downloads) prepended.
pub fn core_logs() -> Vec<String> {
    let mut out = crate::core_download::extra_logs();
    match CORE.lock() {
        Ok(slot) => {
            if let Some(core) = slot.as_ref() {
                out.extend(core.logs());
            }
        }
        Err(_) => {}
    }
    out
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
    start_ensure_core_with_rule_urls(data_dir, "{}".into());
}

pub fn update_rule_resource(data_dir: String, tag: String, url: String, core_path: String) -> Result<(), String> {
    core_download::refresh_rule_resource(
        std::path::Path::new(&data_dir), &tag, &url,
        Some(std::path::Path::new(&core_path)), false,
    ).map(|_| ())
}

pub fn start_ensure_core_with_rule_urls(data_dir: String, urls_json: String) {
    let urls = serde_json::from_str(&urls_json).unwrap_or_default();
    if ENSURE_RUNNING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return; // a download is already in flight
    }
    let dir = PathBuf::from(&data_dir);
    set_ensure(EnsureState {
        phase: "downloading".to_string(),
        version: None,
        error: None,
    });
    std::thread::spawn(move || {
        // The managed install and the rule maintenance are
        // independent: a failed install (occupied path, bad network)
        // must not skip rule upkeep when the bundled core is usable
        // (HF053-02 remainder).
        let mut download_error: Option<String> = None;
        if !core_download::is_up_to_date(&dir) {
            if let Err(e) = core_download::download_and_install(&dir) {
                download_error = Some(e);
            }
        }
        if download_error.is_none() {
            let version = core_download::installed_version(&dir).unwrap_or_default();
            set_ensure(EnsureState {
                phase: "done".to_string(),
                version: Some(version),
                error: None,
            });
        }
        // Rule downloads are optional and may take minutes on a blocked
        // network. Report binary readiness first so startup never waits for them.
        let rules = core_download::ensure_rule_sets(&dir, &urls);
        // Only claim "restart to apply" when this round actually
        // changed something or left gaps — a fully fresh set with no
        // updates needs no restart hint (HF053-02: no false-ready).
        if core_running()
            && (rules.updated > 0 || rules.ready < rules.total || !rules.dir_ok)
        {
            core_download::log_extra(
                "[rules] 运行中的配置未包含本轮规则变化，重启内核后应用".into(),
            );
        }
        if let Some(e) = download_error {
            set_ensure(EnsureState {
                phase: "error".to_string(),
                version: None,
                error: Some(e),
            });
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

/// Convert a downloaded Clash rule-provider payload; never emit raw YAML as JSON source.
pub fn convert_rule_provider(text: String, behavior: String, format: String) -> Result<String,String> {
    crate::profile::convert_provider(&text,&behavior,&format).map(|v|v.to_string())
}

// Wildcard addresses describe a bind, not a portable destination to connect to.
fn readiness_address(bind: &str) -> Option<std::net::SocketAddr> {
    let mut address = bind.parse::<std::net::SocketAddr>().ok()?;
    if address.ip().is_unspecified() {
        address.set_ip(if address.is_ipv4() {
            std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST)
        } else { std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST) });
    }
    Some(address)
}
#[cfg(test)]
mod readiness_tests {
    use super::readiness_address;
    #[test]
    fn wildcard_probes_use_matching_loopback_family() {
        assert_eq!(readiness_address("0.0.0.0:7890").unwrap().to_string(), "127.0.0.1:7890");
        assert_eq!(readiness_address("[::]:9090").unwrap().to_string(), "[::1]:9090");
        assert_eq!(readiness_address("192.0.2.1:7890").unwrap().to_string(), "192.0.2.1:7890");
        assert!(readiness_address("bad-address").is_none());
    }
}
