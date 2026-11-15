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
    /// Port of the Clash API controller (127.0.0.1:<port>).
    pub clash_api_port: u16,
    /// Whether to enable the TUN inbound (requires platform support).
    pub enable_tun: bool,
    /// Route rule option: reject advertising domains (rule-set).
    pub block_ads: bool,
    /// Route rule option: CN sites/IPs go direct (rule-sets), and CN
    /// DNS lookups use the local resolver.
    pub bypass_cn: bool,
    /// Log level passed to sing-box: trace/debug/info/warn/error/fatal/panic.
    pub log_level: String,
    /// App data directory; the cache file lives here so the selector
    /// choice survives restarts. Empty means a relative "cache.db".
    pub data_dir: String,
}

impl Default for CoreSettings {
    fn default() -> Self {
        Self {
            mixed_port: 7890,
            clash_api_port: 9090,
            enable_tun: false,
            block_ads: true,
            bypass_cn: true,
            log_level: "info".to_string(),
            data_dir: String::new(),
        }
    }
}

/// One node for the multi-node generator: display name + outbound JSON.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NodeSpec {
    pub name: String,
    pub outbound_json: String,
}

/// Where the external UI (zashboard) is downloaded from by sing-box.
/// Pinned release: the archive digest below is the official sha-256
/// published on the GitHub release API, so a swapped/tampered dist.zip
/// is rejected both by the app's own downloader and by sing-box's
/// external-ui fetch path (which shares this URL). Bump version and
/// digest together.
pub const ZASHBOARD_DOWNLOAD_URL: &str =
    "https://github.com/Zephyruso/zashboard/releases/download/v3.30.0/dist.zip";
pub const ZASHBOARD_SHA256: &str =
    "1f91c014e61e768240a86ad0a9bd565b247ec5a0e26b125fb5d19076682905b7";

const RESERVED_TAGS: [&str; 8] = [
    "proxy", "auto", "direct", "mixed-in", "tun-in", "dns-remote", "dns-local", "__tokiboshi_reject",
];

/// Deterministic, collision-free outbound tags for node names.
/// The selector persists its choice by tag (cache_file), so the same
/// node list must always produce the same tags.
pub fn assign_tags(names: &[String]) -> Vec<String> {
    let mut used: Vec<String> = RESERVED_TAGS.iter().map(|s| s.to_string()).collect();
    let mut out = Vec::with_capacity(names.len());
    for (i, name) in names.iter().enumerate() {
        let base = {
            let t = name.trim();
            if t.is_empty() { format!("node-{}", i + 1) } else { t.to_string() }
        };
        let mut tag = base.clone();
        let mut n = 2;
        while used.contains(&tag) {
            tag = format!("{base}-{n}");
            n += 1;
        }
        used.push(tag.clone());
        out.push(tag);
    }
    out
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

/// Build a complete sing-box configuration around a single outbound
/// (kept for tests and one-node callers; delegates to the multi-node
/// generator).
pub fn build_config(outbound: &Value, settings: &CoreSettings) -> Result<String, String> {
    let spec = NodeSpec {
        name: outbound
            .get("tag")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        outbound_json: outbound.to_string(),
    };
    build_config_multi(std::slice::from_ref(&spec), settings, None)
}

/// Build a complete sing-box configuration for the GUI shell:
///
/// - one `mixed` inbound (plus TUN when enabled),
/// - a `proxy` selector over an `auto` urltest group and every node,
/// - route rules: private IPs direct, ads rejected, CN sites/IPs
///   direct (remote rule-sets), everything else to the selector,
/// - new-format DNS (remote through the proxy, CN via local),
/// - `experimental.clash_api` on 127.0.0.1 with the zashboard
///   external UI, and `experimental.cache_file` so the selector
///   choice survives restarts.
///
/// `selected_name` (a node display name) becomes the selector's
/// default when given. Pure function of its inputs.
pub fn build_config_multi(
    nodes: &[NodeSpec],
    settings: &CoreSettings,
    selected_name: Option<&str>,
) -> Result<String, String> {
    if nodes.is_empty() {
        return Err("no nodes to build a config from".to_string());
    }
    if !LOG_LEVELS.contains(&settings.log_level.as_str()) {
        return Err(format!("unknown log level: {}", settings.log_level));
    }
    if settings.mixed_port == 0 || settings.clash_api_port == 0 {
        return Err("ports must not be 0".to_string());
    }

    if settings.mixed_port == settings.clash_api_port {
        return Err("mixed and Clash API ports must be different".into());
    }

    let names: Vec<String> = nodes.iter().map(|n| n.name.clone()).collect();
    let tags = assign_tags(&names);

    let mut outbounds: Vec<Value> = Vec::new();
    let default_tag = selected_name
        .and_then(|sel| tags.iter().position(|tag| tag == sel)
            .or_else(|| names.iter().position(|n| n == sel)))
        .map(|i| tags[i].clone())
        .unwrap_or_else(|| "auto".to_string());
    let mut selector_members = vec![Value::String("auto".to_string())];
    selector_members.extend(tags.iter().cloned().map(Value::String));
    outbounds.push(json!({
        "type": "selector",
        "tag": "proxy",
        "outbounds": selector_members,
        "default": default_tag
    }));
    outbounds.push(json!({
        "type": "urltest",
        "tag": "auto",
        "outbounds": tags.iter().cloned().map(Value::String).collect::<Vec<_>>(),
        "url": "https://www.gstatic.com/generate_204",
        "interval": "3m",
        "tolerance": 50
    }));
    // Imported tags and display names can differ; resolve dependencies before
    // overwriting tags, especially names colliding with our reserved groups.
    let mut aliases = std::collections::HashMap::<String, String>::new();
    for (spec, tag) in nodes.iter().zip(tags.iter()) {
        let ob: Value = serde_json::from_str(&spec.outbound_json)
            .map_err(|e| format!("node '{}' has invalid outbound JSON: {e}", spec.name))?;
        for alias in [Some(spec.name.as_str()), ob.get("tag").and_then(Value::as_str)].into_iter().flatten() {
            aliases.entry(alias.into()).and_modify(|previous| {
                if previous != tag { previous.clear(); }
            }).or_insert_with(|| tag.clone());
        }
    }
    let mut dependencies = std::collections::HashMap::<String, Vec<String>>::new();
    for (spec, tag) in nodes.iter().zip(tags.iter()) {
        let mut ob: Value = serde_json::from_str(&spec.outbound_json)
            .map_err(|e| format!("node '{}' has invalid outbound JSON: {e}", spec.name))?;
        let obj = ob
            .as_object_mut()
            .ok_or_else(|| format!("node '{}' outbound must be an object", spec.name))?;
        match obj.get("type").and_then(Value::as_str) {
            Some(t) if !t.is_empty() => {}
            _ => return Err(format!("node '{}' outbound missing \"type\"", spec.name)),
        }
        if let Some(via) = obj.get("detour").and_then(Value::as_str) {
            let target = match aliases.get(via) {
                Some(target) if target.is_empty() => return Err(format!("node '{}' has ambiguous detour '{via}'", spec.name)),
                Some(target) => target.clone(),
                None if via == "direct" => "direct".to_string(),
                None => return Err(format!("node '{}' references missing detour '{via}'", spec.name)),
            };
            dependencies.entry(tag.clone()).or_default().push(target.clone());
            obj.insert("detour".into(), Value::String(target));
        }
        if let Some(members) = obj.get("outbounds").and_then(Value::as_array) {
            let mut resolved = Vec::new();
            for member in members {
                let name = member.as_str().ok_or("policy group member must be a name")?;
                let target = match name {
                    "DIRECT" => "direct".to_string(),
                    "REJECT" => "__tokiboshi_reject".to_string(),
                    _ => match aliases.get(name) {
                        Some(target) if !target.is_empty() => target.clone(),
                        _ if name == "direct" => "direct".into(),
                        _ => return Err(format!("policy '{}' references missing or ambiguous member '{name}'", spec.name)),
                    }
                };
                dependencies.entry(tag.clone()).or_default().push(target.clone());
                resolved.push(Value::String(target));
            }
            if resolved.is_empty() { resolved.push(json!("__tokiboshi_reject")); }
            obj.insert("outbounds".into(), Value::Array(resolved));
            if let Some(default) = obj.get("default").and_then(Value::as_str) {
                let resolved = aliases.get(default).filter(|s| !s.is_empty()).cloned()
                    .or_else(|| match default { "DIRECT" | "direct" => Some("direct".into()), "REJECT" => Some("__tokiboshi_reject".into()), _ => None })
                    .ok_or_else(|| format!("policy '{}' has invalid default", spec.name))?;
                obj.insert("default".into(), Value::String(resolved));
            }
        }
        obj.retain(|key, _| !key.starts_with("_clash_"));
        obj.insert("tag".to_string(), Value::String(tag.clone()));
        outbounds.push(ob);
    }
    // One graph covers both dialer chains and imported policy membership.
    let mut complete = std::collections::HashSet::new();
    for tag in &tags {
        let mut active = std::collections::HashSet::new();
        let mut stack = vec![(tag.clone(), false)];
        while let Some((current, leaving)) = stack.pop() {
            if leaving { active.remove(&current); complete.insert(current); continue; }
            if complete.contains(&current) { continue; }
            if !active.insert(current.clone()) { return Err(format!("cyclic proxy chain or policy involving '{current}'")); }
            stack.push((current.clone(), true));
            if let Some(next) = dependencies.get(&current) {
                for child in next { stack.push((child.clone(), false)); }
            }
        }
    }
    if outbounds.iter().any(|ob| ob.get("outbounds").and_then(Value::as_array).is_some_and(|members| members.iter().any(|member| member == "__tokiboshi_reject"))) {
        outbounds.push(json!({"type":"block", "tag":"__tokiboshi_reject"}));
    }
    outbounds.push(json!({ "type": "direct", "tag": "direct" }));

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

    let cache_path = if settings.data_dir.is_empty() {
        "cache.db".to_string()
    } else {
        format!("{}/cache.db", settings.data_dir.trim_end_matches(['/', '\\']))
    };

    // Rule options chosen in the UI: ads rejection and CN bypass are
    // independent toggles; private-address direct always applies.
    // Rule-sets are LOCAL files the app downloads into
    // `<data_dir>/rules/` ahead of time (see core_download): a remote
    // rule-set download runs inside sing-box's startup, and a slow
    // or unreachable selected node made the whole core exit with a
    // FATAL before it ever listened. A missing file simply drops
    // that rule — the core must always be able to start.
    let local_rule_set = |tag: &str| -> Option<Value> {
        if settings.data_dir.is_empty() {
            return None;
        }
        let path = std::path::Path::new(&settings.data_dir)
            .join("rules")
            .join(format!("{tag}.srs"));
        if path.is_file() {
            Some(json!({ "type": "local", "tag": tag, "format": "binary",
                "path": path.to_string_lossy() }))
        } else {
            None
        }
    };
    let mut route_rules: Vec<Value> = vec![
        json!({ "ip_is_private": true, "outbound": "direct" }),
        // Mode rules make the Clash API mode switcher actually route:
        // without them PATCH /configs only flips an unused variable
        // and Global/Direct silently behave like Rule (HF053-01).
        json!({ "clash_mode": "Direct", "outbound": "direct" }),
        json!({ "clash_mode": "Global", "outbound": "proxy" }),
    ];
    let mut rule_sets: Vec<Value> = Vec::new();
    let mut dns_rules: Vec<Value> = Vec::new();
    if settings.block_ads {
        if let Some(rs) = local_rule_set("geosite-category-ads-all") {
            route_rules.push(json!({ "rule_set": ["geosite-category-ads-all"], "action": "reject" }));
            rule_sets.push(rs);
        }
    }
    if settings.bypass_cn {
        let mut cn_tags: Vec<Value> = Vec::new();
        for tag in ["geosite-cn", "geoip-cn"] {
            if let Some(rs) = local_rule_set(tag) {
                rule_sets.push(rs);
                cn_tags.push(Value::String(tag.to_string()));
            }
        }
        if !cn_tags.is_empty() {
            route_rules.push(json!({ "rule_set": cn_tags, "outbound": "direct" }));
        }
        if rule_sets.iter().any(|rs| rs["tag"] == "geosite-cn") {
            dns_rules.push(json!({ "rule_set": ["geosite-cn"], "action": "route", "server": "dns-local" }));
        }
    }

    let config = json!({
        "log": { "level": settings.log_level, "timestamp": true },
        "dns": {
            "servers": [
                { "type": "https", "tag": "dns-remote", "server": "8.8.8.8", "detour": "proxy" },
                { "type": "local", "tag": "dns-local" }
            ],
            "rules": dns_rules,
            "final": "dns-remote"
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "rules": route_rules,
            "rule_set": rule_sets,
            "final": "proxy",
            "auto_detect_interface": true,
            "default_domain_resolver": "dns-local"
        },
        "experimental": {
            "cache_file": { "enabled": true, "path": cache_path },
            "clash_api": {
                "external_controller": format!("127.0.0.1:{}", settings.clash_api_port),
                "external_ui": if settings.data_dir.is_empty() { "ui".to_string() }
                    else { std::path::Path::new(&settings.data_dir).join("ui").to_string_lossy().into_owned() },
                "external_ui_download_url": ZASHBOARD_DOWNLOAD_URL,
                "external_ui_download_detour": "direct",
                "default_mode": "Rule"
            }
        }
    });
    serde_json::to_string_pretty(&config).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chain_references_follow_reserved_tag_renaming() {
        let nodes = vec![NodeSpec { name: "proxy".into(), outbound_json: r#"{"type":"socks","tag":"entry","server":"127.0.0.1","server_port":1080}"#.into() },
            NodeSpec { name: "exit".into(), outbound_json: r#"{"type":"socks","server":"127.0.0.1","server_port":1081,"detour":"entry"}"#.into() }];
        let v: Value = serde_json::from_str(&build_config_multi(&nodes, &CoreSettings::default(), None).unwrap()).unwrap();
        assert_eq!(v["outbounds"][3]["detour"], "proxy-2");
        let mut broken = nodes.clone();
        broken[1].outbound_json = broken[1].outbound_json.replace("entry", "missing");
        assert!(build_config_multi(&broken, &CoreSettings::default(), None).unwrap_err().contains("missing detour"));
        broken[1].outbound_json = nodes[1].outbound_json.replace("entry", "exit");
        assert!(build_config_multi(&broken, &CoreSettings::default(), None).unwrap_err().contains("cyclic"));
    }

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
    fn policy_members_follow_generated_tags_and_keep_reject_semantics() {
        let nodes = vec![
            NodeSpec {name:"direct".into(),outbound_json:r#"{"type":"socks","server":"127.0.0.1","server_port":1080}"#.into()},
            NodeSpec {name:"group".into(),outbound_json:r#"{"type":"selector","outbounds":["direct","DIRECT","REJECT"],"_clash_proxies":["direct","DIRECT","REJECT"]}"#.into()},
        ];
        let config: Value = serde_json::from_str(&build_config_multi(&nodes,&CoreSettings::default(),Some("group")).unwrap()).unwrap();
        let group = config["outbounds"].as_array().unwrap().iter().find(|n| n["tag"]=="group").unwrap();
        assert_eq!(group["outbounds"],json!(["direct-2","direct","__tokiboshi_reject"]));
        assert!(group.get("_clash_proxies").is_none());
        assert!(config["outbounds"].as_array().unwrap().iter().any(|n| n["type"]=="block"));
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
        assert_eq!(v["outbounds"][0]["type"], "selector");
        assert_eq!(v["outbounds"][0]["tag"], "proxy");
        let last = v["outbounds"].as_array().unwrap().last().unwrap().clone();
        assert_eq!(last["type"], "direct");
        assert_eq!(v["inbounds"][0]["listen_port"], 7890);
        assert_eq!(v["route"]["final"], "proxy");
    }

    fn spec(name: &str, server: &str) -> NodeSpec {
        NodeSpec {
            name: name.to_string(),
            outbound_json: json!({
                "type": "hysteria2", "server": server, "server_port": 443,
                "password": "pw", "tls": {"enabled": true}
            })
            .to_string(),
        }
    }

    #[test]
    fn missing_rule_set_files_drop_rules_not_core() {
        let nodes = vec![spec("节点A", "a.example.com")];
        let settings = CoreSettings {
            data_dir: "/nonexistent-tkb".to_string(),
            ..CoreSettings::default()
        };
        let text = build_config_multi(&nodes, &settings, None).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["route"]["rule_set"].as_array().unwrap().len(), 0);
        // Mode rules still present; only the rule-set rules were dropped.
        assert_eq!(v["route"]["rules"].as_array().unwrap().len(), 3);
        assert_eq!(v["dns"]["rules"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn rule_options_toggle_off() {
        let nodes = vec![NodeSpec {
            name: "n".to_string(),
            outbound_json: r#"{"type":"socks","server":"127.0.0.1","server_port":1080}"#.to_string(),
        }];
        let settings = CoreSettings { block_ads: false, bypass_cn: false, ..Default::default() };
        let text = build_config_multi(&nodes, &settings, None).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        // Private direct, then the two mode rules, then nothing (no
        // rule files). Mode rules exist even when every toggle is off.
        let rules = v["route"]["rules"].as_array().unwrap();
        assert_eq!(rules.len(), 3);
        assert_eq!(rules[0]["ip_is_private"], true);
        assert_eq!(rules[1]["clash_mode"], "Direct");
        assert_eq!(rules[1]["outbound"], "direct");
        assert_eq!(rules[2]["clash_mode"], "Global");
        assert_eq!(rules[2]["outbound"], "proxy");
        assert_eq!(v["route"]["rule_set"].as_array().unwrap().len(), 0);
        assert_eq!(v["dns"]["rules"].as_array().unwrap().len(), 0);
        // Sanity: the leaner config still passes the real core check
        // where the integration harness runs it.
    }

    #[test]
    fn multi_config_has_groups_rules_and_clash_api() {
        let nodes = vec![spec("节点A", "a.example.com"), spec("节点B", "b.example.com")];
        // Local rule-set files present in a scratch data dir.
        let scratch = std::env::temp_dir().join(format!("tkb-cfg-test-{}", std::process::id()));
        let rules_dir = scratch.join("rules");
        std::fs::create_dir_all(&rules_dir).unwrap();
        for tag in ["geosite-category-ads-all", "geosite-cn", "geoip-cn"] {
            std::fs::write(rules_dir.join(format!("{tag}.srs")), b"dummy").unwrap();
        }
        let settings = CoreSettings {
            data_dir: scratch.to_string_lossy().into_owned(),
            ..CoreSettings::default()
        };
        let text = build_config_multi(&nodes, &settings, Some("节点B")).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        // Groups: selector over [auto, A, B], default honours selection.
        let selector = &v["outbounds"][0];
        assert_eq!(selector["type"], "selector");
        assert_eq!(selector["outbounds"], json!(["auto", "节点A", "节点B"]));
        assert_eq!(selector["default"], "节点B");
        assert_eq!(v["outbounds"][1]["type"], "urltest");
        assert_eq!(v["outbounds"][2]["tag"], "节点A");
        // Route template: private direct, mode rules, ads reject, CN direct.
        let rules = v["route"]["rules"].as_array().unwrap();
        assert_eq!(rules[0]["ip_is_private"], true);
        assert_eq!(rules[1]["clash_mode"], "Direct");
        assert_eq!(rules[2]["clash_mode"], "Global");
        assert_eq!(rules[3]["action"], "reject");
        assert_eq!(rules[4]["outbound"], "direct");
        assert_eq!(v["route"]["rule_set"].as_array().unwrap().len(), 3);
        assert_eq!(v["route"]["rule_set"][0]["type"], "local");
        // No remote-download machinery remains in the config.
        assert!(v.get("http_clients").is_none());
        // Clash API + zashboard + cache file.
        let api = &v["experimental"]["clash_api"];
        assert_eq!(api["external_controller"], "127.0.0.1:9090");
        assert_eq!(api["external_ui_download_url"], ZASHBOARD_DOWNLOAD_URL);
        assert_eq!(v["experimental"]["cache_file"]["enabled"], true);
        assert!(v["experimental"]["cache_file"]["path"].as_str().unwrap().ends_with("cache.db"));
        // DNS: new format, remote detours through the selector.
        assert_eq!(v["dns"]["servers"][0]["type"], "https");
        assert_eq!(v["dns"]["servers"][0]["detour"], "proxy");
        assert_eq!(v["dns"]["final"], "dns-remote");
    }

    #[test]
    fn multi_config_dedupes_tags_and_avoids_reserved() {
        let nodes = vec![
            spec("proxy", "a.example.com"),
            spec("dup", "b.example.com"),
            spec("dup", "c.example.com"),
            spec("", "d.example.com"),
        ];
        let text = build_config_multi(&nodes, &CoreSettings::default(), None).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        let selector = &v["outbounds"][0];
        assert_eq!(
            selector["outbounds"],
            json!(["auto", "proxy-2", "dup", "dup-2", "node-4"])
        );
        assert_eq!(selector["default"], "auto");
    }

    #[test]
    fn multi_config_rejects_empty_and_bad_nodes() {
        assert!(build_config_multi(&[], &CoreSettings::default(), None).is_err());
        let bad = vec![NodeSpec { name: "x".into(), outbound_json: "{}".into() }];
        assert!(build_config_multi(&bad, &CoreSettings::default(), None).is_err());
        let bad2 = vec![NodeSpec { name: "x".into(), outbound_json: "nope".into() }];
        assert!(build_config_multi(&bad2, &CoreSettings::default(), None).is_err());
    }

    #[test]
    fn tags_are_deterministic() {
        let names = vec!["a".to_string(), "a".to_string(), "auto".to_string()];
        assert_eq!(assign_tags(&names), vec!["a", "a-2", "auto-2"]);
        assert_eq!(assign_tags(&names), assign_tags(&names));
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
