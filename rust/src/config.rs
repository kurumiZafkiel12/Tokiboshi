//! sing-box configuration: minimal model, validation and generation.
//!
//! The middle layer accepts a user supplied outbound (from a share link
//! already decoded to JSON, or a full sing-box config), validates it, and
//! wraps it into a complete runnable sing-box configuration with a local
//! mixed (SOCKS/HTTP) inbound and a direct fallback.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Settings the Flutter UI can change without editing raw JSON.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CoreSettings {
    /// Port of the local mixed inbound.
    pub mixed_port: u16,
    /// Whether to enable the TUN inbound (requires platform support).
    pub enable_tun: bool,
    /// Log level passed to sing-box: trace/debug/info/warn/error/fatal/panic.
    pub log_level: String,
}

impl Default for CoreSettings {
    fn default() -> Self {
        Self {
            mixed_port: 7890,
            enable_tun: false,
            log_level: "info".to_string(),
        }
    }
}

const LOG_LEVELS: [&str; 7] = ["trace", "debug", "info", "warn", "error", "fatal", "panic"];

/// Validate a complete sing-box configuration document.
///
/// Returns a list of human readable problems; an empty list means valid.
/// This checks structure only — `sing-box check` remains the authority,
/// and the process layer runs it before start when a binary is available.
pub fn validate_config(text: &str) -> Vec<String> {
    let mut problems = Vec::new();
    let value: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(e) => return vec![format!("invalid JSON: {e}")],
    };
    let Some(obj) = value.as_object() else {
        return vec!["top level must be a JSON object".to_string()];
    };
    match obj.get("outbounds") {
        None => problems.push("missing \"outbounds\"".to_string()),
        Some(Value::Array(list)) => {
            if list.is_empty() {
                problems.push("\"outbounds\" must not be empty".to_string());
            }
            for (i, ob) in list.iter().enumerate() {
                match ob.get("type").and_then(Value::as_str) {
                    None => problems.push(format!("outbounds[{i}] missing \"type\"")),
                    Some("") => problems.push(format!("outbounds[{i}] has empty \"type\"")),
                    _ => {}
                }
            }
        }
        Some(_) => problems.push("\"outbounds\" must be an array".to_string()),
    }
    if let Some(inbounds) = obj.get("inbounds") {
        if !inbounds.is_array() {
            problems.push("\"inbounds\" must be an array".to_string());
        }
    }
    problems
}

/// Build a complete sing-box configuration around a single outbound.
///
/// `outbound` is one sing-box outbound object (e.g. a vless/hysteria2
/// node). The generated config routes everything through that outbound,
/// with a direct outbound available under the tag `direct`.
pub fn build_config(outbound: &Value, settings: &CoreSettings) -> Result<String, String> {
    let outbound_type = outbound
        .get("type")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "outbound missing \"type\"".to_string())?;
    if !LOG_LEVELS.contains(&settings.log_level.as_str()) {
        return Err(format!("unknown log level: {}", settings.log_level));
    }
    if settings.mixed_port == 0 {
        return Err("mixed_port must not be 0".to_string());
    }

    let mut node = outbound.clone();
    let obj = node
        .as_object_mut()
        .ok_or_else(|| "outbound must be a JSON object".to_string())?;
    obj.entry("tag".to_string())
        .or_insert_with(|| Value::String("proxy".to_string()));

    let mut inbounds = vec![json!({
        "type": "mixed",
        "tag": "mixed-in",
        "listen": "127.0.0.1",
        "listen_port": settings.mixed_port
    })];
    if settings.enable_tun {
        inbounds.push(json!({
            "type": "tun",
            "tag": "tun-in",
            "address": ["172.19.0.1/30"],
            "auto_route": true,
            "strict_route": true,
            "stack": "mixed"
        }));
    }

    let _ = outbound_type;
    let config = json!({
        "log": { "level": settings.log_level, "timestamp": true },
        "inbounds": inbounds,
        "outbounds": [
            node,
            { "type": "direct", "tag": "direct" }
        ],
        "route": { "final": "proxy", "auto_detect_interface": true }
    });
    serde_json::to_string_pretty(&config).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_json() {
        assert_eq!(validate_config("{nope").len(), 1);
    }

    #[test]
    fn rejects_missing_outbounds() {
        let problems = validate_config("{}");
        assert!(problems.iter().any(|p| p.contains("outbounds")));
    }

    #[test]
    fn accepts_minimal_config() {
        let text = r#"{"outbounds":[{"type":"direct"}]}"#;
        assert!(validate_config(text).is_empty());
    }

    #[test]
    fn builds_config_with_proxy_and_direct() {
        let outbound = json!({"type": "hysteria2", "server": "example.com", "server_port": 443, "password": "secret"});
        let text = build_config(&outbound, &CoreSettings::default()).unwrap();
        assert!(validate_config(&text).is_empty());
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["outbounds"][0]["tag"], "proxy");
        assert_eq!(v["outbounds"][1]["type"], "direct");
        assert_eq!(v["inbounds"][0]["listen_port"], 7890);
        assert_eq!(v["route"]["final"], "proxy");
    }

    #[test]
    fn build_rejects_bad_settings() {
        let outbound = json!({"type": "direct"});
        let bad_level = CoreSettings { log_level: "loud".into(), ..Default::default() };
        assert!(build_config(&outbound, &bad_level).is_err());
        let bad_port = CoreSettings { mixed_port: 0, ..Default::default() };
        assert!(build_config(&outbound, &bad_port).is_err());
        let no_type = json!({"server": "x"});
        assert!(build_config(&no_type, &CoreSettings::default()).is_err());
    }

    #[test]
    fn tun_inbound_only_when_enabled() {
        let outbound = json!({"type": "direct"});
        let off = build_config(&outbound, &CoreSettings::default()).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&off).unwrap()["inbounds"].as_array().unwrap().len(), 1);
        let on = build_config(&outbound, &CoreSettings { enable_tun: true, ..Default::default() }).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&on).unwrap()["inbounds"].as_array().unwrap().len(), 2);
    }
}
