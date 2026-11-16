//! Subscription profile: rules / rule-providers / DNS carried by the
//! subscription itself (T069).
//!
//! A "profile" is the routing part of a subscription response — Clash
//! YAML rules + rule-providers + DNS, or the route/dns of a native
//! sing-box JSON. Parsed profiles are stored in CLASH form (targets as
//! names); `build_config_multi` resolves names to tags at generation
//! time and reports unknown targets explicitly. Nothing is silently
//! dropped: every unsupported entry is listed in `unsupported`.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// A subscription-carried routing profile, normalised for transport
/// and generation.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct ParsedProfile {
    /// sing-box route rules; targets are OUTBOUND NAMES (not tags yet).
    pub route_rules: Vec<Value>,
    /// sing-box rule_set entries (remote) referenced by route rules.
    pub rule_sets: Vec<Value>,
    /// Terminal target from a MATCH rule (outbound name), if any.
    pub final_outbound: Option<String>,
    /// Converted sing-box `dns` section, when the subscription
    /// provides a convertible one. For native sing-box profiles this
    /// is carried VERBATIM (rules/final/strategy preserved,
    /// T069-S03) and `dns_native` is true.
    pub dns: Option<Value>,
    /// True when [dns] is the native sing-box section carried
    /// verbatim (not a Clash conversion).
    #[serde(default)]
    pub dns_native: bool,
    /// Human-readable reports for entries that could not be carried.
    pub unsupported: Vec<String>,
    /// Total rule lines seen (kept + unsupported).
    pub rules_total: usize,
}

impl ParsedProfile {
    pub fn summary(&self) -> String {
        let mut s = format!(
            "规则 {}/{} 条 · 规则集 {} · final {}",
            self.route_rules.len(),
            self.rules_total,
            self.rule_sets.len(),
            self.final_outbound.as_deref().unwrap_or("(订阅未定义，沿用应用默认)")
        );
        if !self.unsupported.is_empty() {
            s.push_str(&format!(" · 不兼容 {} 项（见日志）", self.unsupported.len()));
        }
        s
    }
}

/// Rule types this phase can carry into sing-box. Everything else is
/// reported as unsupported with its line number (HF053: no silent
/// drops).
const SUPPORTED: [&str; 8] = [
    "DOMAIN",
    "DOMAIN-SUFFIX",
    "DOMAIN-KEYWORD",
    "IP-CIDR",
    "IP-CIDR6",
    "GEOIP",
    "RULE-SET",
    "MATCH",
];

fn is_supported(t: &str) -> bool {
    SUPPORTED.iter().any(|s| s.eq_ignore_ascii_case(t))
}

/// Convert one Clash rule line into a sing-box route rule.
/// `providers` maps rule-provider name → sing-box rule_set tag.
/// Returns Ok(None) for entries that produce no route rule.
fn convert_rule(
    parts: &[&str],
    line_no: usize,
    providers: &std::collections::BTreeMap<String, String>,
) -> Result<Option<Value>, String> {
    let rtype = parts[0].trim();
    if !is_supported(rtype) {
        return Err(format!(
            "第 {line_no} 行：规则类型 {rtype} 暂不支持（已登记，不会静默套用模板）"
        ));
    }
    if rtype.eq_ignore_ascii_case("MATCH") {
        let target = parts.get(1).ok_or("MATCH 缺少目标")?.trim();
        return Ok(Some(json!({ "__match_target": target })));
    }
    let payload = parts.get(1).ok_or("规则缺少载荷")?.trim();
    let target = parts.get(2).ok_or("规则缺少目标")?.trim();
    let no_resolve = parts.iter().skip(3).any(|p| p.trim().eq_ignore_ascii_case("no-resolve"));
    let mut out = match rtype.to_ascii_uppercase().as_str() {
        "DOMAIN" => json!({ "domain": [payload] }),
        "DOMAIN-SUFFIX" => json!({ "domain_suffix": [payload] }),
        "DOMAIN-KEYWORD" => json!({ "domain_keyword": [payload] }),
        "IP-CIDR" | "IP-CIDR6" => json!({ "ip_cidr": [payload] }),
        // GEOIP route rules were removed in sing-box 1.14 (T069-S01):
        // carried as an audit marker, converted at build time into a
        // rule_set reference (local geoip-<cc>.srs for CN, remote
        // SagerNet rule-set for other codes).
        "GEOIP" => {
            if payload.eq_ignore_ascii_case("private") { json!({"ip_is_private":true}) }
            else if payload.len()==2 && payload.bytes().all(|b|b.is_ascii_alphabetic()) { json!({"__geoip":payload}) }
            else { return Err(format!("第 {line_no} 行：GEOIP国家代码无效")); }
        },
        "RULE-SET" => {
            let tag = providers.get(payload).ok_or_else(|| {
                format!("RULE-SET 引用了未定义的 provider「{payload}」")
            })?;
            json!({ "rule_set": [tag] })
        }
        _ => unreachable!("is_supported guard"),
    };
    if let Some(obj) = out.as_object_mut() {
        obj.insert("outbound".into(), Value::String(target.to_string()));
        if no_resolve && rtype.to_ascii_uppercase().starts_with("IP") {
            // clash no-resolve: do not resolve domains for ip rules.
            // sing-box matches addresses without resolving by default;
            // nothing extra to emit, kept for the audit trail.
            obj.insert("_no_resolve".into(), Value::Bool(true));
        }
    }
    Ok(Some(out))
}

/// Parse the routing part of a Clash YAML subscription.
/// Returns Ok(None) when the document carries no rules at all (pure
/// node list) — callers must then disclose "仅节点订阅".
pub fn parse_clash_profile(text: &str) -> Result<Option<ParsedProfile>, String> {
    // Deserialize straight into a JSON value so the whole traversal
    // below can use one consistent Value type (serde_yaml::Value and
    // serde_json::Value do not mix).
    let doc: Value =
        serde_yaml::from_str(text).map_err(|e| format!("订阅 YAML 解析失败：{e}"))?;
    if doc.get("rules").is_some_and(|r| !r.is_array()) {
        return Err("订阅rules必须为数组".into());
    }
    let rules = doc.get("rules").and_then(Value::as_array);
    let providers = doc.get("rule-providers").and_then(Value::as_object);
    let dns = doc.get("dns");
    if rules.is_none() && providers.is_none() && dns.is_none() {
        return Ok(None);
    }

    let mut profile = ParsedProfile::default();
    // rule-providers → sing-box rule_set (remote). mrs / inline are
    // reported as unsupported in this phase.
    if let Some(map) = providers {
        for (name, body) in map {
            let btype = body.get("behavior").and_then(Value::as_str).unwrap_or("");
            let format = body
                .get("format")
                .and_then(Value::as_str)
                .unwrap_or("yaml")
                .to_ascii_lowercase();
            let url = body.get("url").and_then(Value::as_str).unwrap_or("");
            if url.is_empty() {
                profile.unsupported.push(format!(
                    "rule-provider「{name}」缺少 url，无法作为远程规则集"
                ));
                continue;
            }
            let behavior = match btype {
                "domain" => "domain",
                "ipcidr" => "ip_cidr",
                _ => {
                    profile.unsupported.push(format!(
                        "rule-provider「{name}」behavior={btype:?} 暂不支持（仅 domain/ipcidr）"
                    ));
                    continue;
                }
            };
            let sb_format = match format.as_str() {
                "yaml" | "text" => "source",
                "mrs" => {
                    profile.unsupported.push(format!(
                        "rule-provider「{name}」format=mrs 暂不支持（请改用 yaml/text 分发）"
                    ));
                    continue;
                }
                other => {
                    profile.unsupported.push(format!(
                        "rule-provider「{name}」format={other:?} 暂不支持"
                    ));
                    continue;
                }
            };
            profile.rule_sets.push(json!({
                "type": "remote",
                "tag": name,
                "format": sb_format,
                "url": url,
                "download_detour": "direct",
                "update_interval": "24h",
                "__behavior": behavior,
                "__format": format,
            }));
        }
    }

    if let Some(list) = rules {
        profile.rules_total = list.len();
        let mut line_no = 0usize;
        for entry in list {
            line_no += 1;
            let line = match entry.as_str() {
                Some(l) => l,
                None => {
                    profile
                        .unsupported
                        .push(format!("第 {line_no} 行：规则不是字符串（无法解析）"));
                    continue;
                }
            };
            let parts: Vec<&str> = line.split(',').map(str::trim).collect();
            let providers_tags: std::collections::BTreeMap<String, String> = profile
                .rule_sets
                .iter()
                .filter_map(|rs| {
                    let tag = rs.get("tag")?.as_str()?.to_string();
                    let name = rs.get("tag")?.as_str()?.to_string(); // provider name == tag here
                    Some((name, tag))
                })
                .collect();
            match convert_rule(&parts, line_no, &providers_tags) {
                Ok(Some(mut rule)) => {
                    // MATCH → terminal target.
                    if rule.get("__match_target").is_some() {
                        profile.final_outbound =
                            rule["__match_target"].as_str().map(str::to_string);
                        // MATCH is terminal: later rules are unreachable in Clash.
                        break;
                    }
                    // Strip audit-only keys.
                    if let Some(obj) = rule.as_object_mut() {
                        obj.retain(|k, _| !k.starts_with("__") || k == "__geoip");
                    }
                    profile.route_rules.push(rule);
                }
                Ok(None) => {}
                Err(e) => profile.unsupported.push(e),
            }
        }
    }

    if let Some(dns_body) = dns {
        profile.dns = convert_clash_dns(dns_body, &mut profile.unsupported);
        profile.dns_native = false;
    }
    Ok(Some(profile))
}

/// Minimal Clash DNS → sing-box DNS conversion (T069 phase 1):
/// nameserver strings are mapped by scheme; nameserver-policy /
/// fallback / fake-ip are reported as unsupported (same boundary as
/// Hotaru's converter).
fn convert_clash_dns(body: &Value, unsupported: &mut Vec<String>) -> Option<Value> {
    let nameservers = body.get("nameserver")?.as_array()?;
    let mut servers = Vec::new();
    let mut tag_i = 0;
    for ns in nameservers.iter().filter_map(Value::as_str) {
        tag_i += 1;
        let tag = format!("dns-sub-{tag_i}");
        if let Some(rest) = ns.strip_prefix("https://") {
            let (host, path) = match rest.split_once('/') {
                Some((h, p)) => (h.to_string(), format!("/{}", p)),
                None => (rest.to_string(), "/dns-query".to_string()),
            };
            let (host, port) = split_port(&host, 443);
            servers.push(json!({
                "type": "https", "tag": tag, "server": host,
                "server_port": port, "path": path,
            }));
        } else if let Some(rest) = ns.strip_prefix("tls://") {
            let (host, port) = split_port(rest, 853);
            servers.push(json!({
                "type": "tls", "tag": tag, "server": host, "server_port": port,
            }));
        } else if ns.starts_with("dhcp://") || ns == "system" {
            servers.push(json!({ "type": "local", "tag": tag }));
        } else {
            let (host, port) = split_port(ns, 53);
            servers.push(json!({
                "type": "udp", "tag": tag, "server": host, "server_port": port,
            }));
        }
    }
    if servers.is_empty() {
        return None;
    }
    for key in ["fallback", "nameserver-policy", "default-nameserver", "enhanced-mode", "fake-ip-range"] {
        if body.get(key).is_some() {
            unsupported.push(format!("dns.{key} 暂不支持转换（已忽略，DNS 行为可能与订阅预期不同）"));
        }
    }
    Some(json!({
        "servers": servers,
        "final": servers[0]["tag"],
    }))
}

fn split_port(hostport: &str, default_port: u16) -> (String, u16) {
    match hostport.rsplit_once(':') {
        Some((h, p)) => (h.trim_matches(|c| c == '[' || c == ']').to_string(), p.parse().unwrap_or(default_port)),
        None => (hostport.to_string(), default_port),
    }
}

/// Extract the routing profile from a native sing-box JSON config.
/// route.rules / rule_set / dns are carried verbatim; outbounds that
/// rules depend on must exist in the imported set (missing ones are
/// reported).
pub fn parse_singbox_profile(text: &str) -> Result<Option<ParsedProfile>, String> {
    let doc: Value = serde_json::from_str(text).map_err(|e| format!("订阅 JSON 解析失败：{e}"))?;
    let route = doc.get("route");
    // T069-S05: a native final-only config IS a profile (the old gate
    // dropped it and the run config fell back to the app template).
    let has_route = route
        .map(|r| {
            r.get("rules").is_some()
                || r.get("rule_set").is_some()
                || r.get("final").is_some()
        })
        .unwrap_or(false);
    let dns = doc.get("dns").filter(|d| !d.as_object().map(|o| o.is_empty()).unwrap_or(true));
    if !has_route && dns.is_none() {
        return Ok(None);
    }
    let mut profile = ParsedProfile::default();
    let mut final_outbound = route.and_then(|r| r.get("final")).and_then(Value::as_str).map(str::to_string);
    if let Some(list) = route.and_then(|r| r.get("rules")).and_then(Value::as_array) {
        profile.rules_total = list.len();
        for rule in list {
            // Referenced outbounds may be dependency outbounds that the
            // node importer filtered; report instead of failing here.
            if let Some(target) = rule.get("outbound").and_then(Value::as_str) {
                profile.final_outbound.get_or_insert_with(String::new);
                let _ = target;
            }
            profile.route_rules.push(rule.clone());
        }
    }
    if let Some(list) = route.and_then(|r| r.get("rule_set")).and_then(Value::as_array) {
        for rs in list {
            let is_remote = rs.get("type").and_then(Value::as_str) == Some("remote");
            if !is_remote {
                profile.unsupported.push(format!(
                    "rule_set「{}」type={} 暂不支持（仅 remote）",
                    rs.get("tag").and_then(Value::as_str).unwrap_or("?"),
                    rs.get("type").and_then(Value::as_str).unwrap_or("?")
                ));
                continue;
            }
            profile.rule_sets.push(rs.clone());
        }
    }
    if let Some(f) = final_outbound.take() {
        profile.final_outbound = Some(f);
    }
    if let Some(d) = dns {
        profile.dns = Some(d.clone());
        profile.dns_native = true;
    }
    Ok(Some(profile))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clash_rules_convert_in_order_with_targets() {
        let yaml = r#"
rules:
  - DOMAIN,ads.example.com,REJECT
  - DOMAIN-SUFFIX,cn,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - MATCH,HK
"#;
        let p = parse_clash_profile(yaml).unwrap().unwrap();
        assert_eq!(p.route_rules.len(), 3);
        assert_eq!(p.rules_total, 4);
        assert_eq!(p.final_outbound.as_deref(), Some("HK"));
        assert_eq!(p.route_rules[0]["domain"][0], "ads.example.com");
        assert_eq!(p.route_rules[0]["outbound"], "REJECT");
        assert_eq!(p.route_rules[2]["ip_cidr"][0], "10.0.0.0/8");
        assert!(p.unsupported.is_empty());
    }

    #[test]
    fn unsupported_rule_types_are_listed_not_dropped_silently() {
        let yaml = r#"
rules:
  - PROCESS,telegram.exe,PROXY
  - DOMAIN,ok.example.com,DIRECT
"#;
        let p = parse_clash_profile(yaml).unwrap().unwrap();
        assert_eq!(p.route_rules.len(), 1);
        assert_eq!(p.unsupported.len(), 1);
        assert!(p.unsupported[0].contains("PROCESS"));
    }

    #[test]
    fn rule_set_requires_defined_provider_and_counts() {
        let yaml = r#"
rule-providers:
  ads:
    type: http
    behavior: domain
    url: "https://example.com/ads.yaml"
    format: yaml
rules:
  - RULE-SET,ads,REJECT
  - RULE-SET,ghost,DIRECT
"#;
        let p = parse_clash_profile(yaml).unwrap().unwrap();
        assert_eq!(p.rule_sets.len(), 1);
        assert_eq!(p.rule_sets[0]["tag"], "ads");
        assert_eq!(p.route_rules.len(), 1);
        assert_eq!(p.route_rules[0]["rule_set"][0], "ads");
        assert!(p.unsupported.iter().any(|u| u.contains("ghost")));
    }

    #[test]
    fn mrs_providers_are_reported_unsupported() {
        let yaml = r#"
rule-providers:
  m:
    type: http
    behavior: domain
    url: "https://example.com/x.mrs"
    format: mrs
rules:
  - RULE-SET,m,DIRECT
"#;
        let p = parse_clash_profile(yaml).unwrap().unwrap();
        assert!(p.rule_sets.is_empty());
        assert!(p.unsupported[0].contains("mrs"));
    }

    #[test]
    fn dns_nameservers_convert_by_scheme_and_report_gaps() {
        let yaml = r#"
dns:
  enable: true
  nameserver:
    - "223.5.5.5"
    - "https://doh.pub/dns-query"
    - "tls://dns.google:853"
  nameserver-policy:
    "+.cn": "223.5.5.5"
rules:
  - MATCH,PROXY
"#;
        let p = parse_clash_profile(yaml).unwrap().unwrap();
        let dns = p.dns.unwrap();
        let servers = dns["servers"].as_array().unwrap();
        assert_eq!(servers.len(), 3);
        assert_eq!(servers[0]["type"], "udp");
        assert_eq!(servers[1]["type"], "https");
        assert_eq!(servers[2]["type"], "tls");
        assert!(p.unsupported.iter().any(|u| u.contains("nameserver-policy")));
    }

    #[test]
    fn pure_node_list_yields_no_profile() {
        let yaml = "proxies:\n  - name: a\n    type: ss\n";
        assert!(parse_clash_profile(yaml).unwrap().is_none());
    }

    #[test]
    fn singbox_profile_carries_route_dns_and_reports_missing_sets() {
        let json = r#"{
          "route": { "rules": [{"domain_suffix":["cn"],"outbound":"DIRECT"}],
                     "rule_set": [{"type":"remote","tag":"rs1","format":"source","url":"https://x/rs.json"}],
                     "final": "PROXY" },
          "dns": { "servers": [{"type":"local","tag":"local"}] }
        }"#;
        let p = parse_singbox_profile(json).unwrap().unwrap();
        assert_eq!(p.route_rules.len(), 1);
        assert_eq!(p.rule_sets.len(), 1);
        assert_eq!(p.final_outbound.as_deref(), Some("PROXY"));
        assert!(p.dns.is_some());
    }

    #[test]
    fn summary_mentions_counts_and_gaps() {
        let yaml = r#"
rule-providers:
  ads:
    type: http
    behavior: domain
    url: "https://example.com/ads.yaml"
rules:
  - RULE-SET,ads,REJECT
  - MATCH,HK
"#;
        let p = parse_clash_profile(yaml).unwrap().unwrap();
        let s = p.summary();
        assert!(s.contains("1/2"), "{s}");
        assert!(s.contains("HK"), "{s}");
    }
}

/// Convert the content of a Clash HTTP rule-provider to inline sing-box rules.
/// Fetching, limits and ownership stay with the root subscription resolver.
pub fn convert_provider(text: &str, behavior: &str, format: &str) -> Result<Value, String> {
    if text.len() > 8 * 1024 * 1024 { return Err("规则集超过8MiB上限".into()); }
    let entries: Vec<String> = match format {
        "yaml" => {
            let doc: Value = serde_yaml::from_str(text).map_err(|_| "规则集YAML无效")?;
            doc.get("payload").and_then(Value::as_array).ok_or("规则集缺少payload数组")?
                .iter().map(|v| v.as_str().map(str::to_string).ok_or("规则集payload必须为字符串".to_string())).collect::<Result<_,_>>()?
        }
        "text" => text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')).map(str::to_string).collect(),
        _ => return Err("规则集仅支持yaml/text格式".into()),
    };
    if entries.len() > 100_000 { return Err("规则集超过100000条上限".into()); }
    let mut exact=Vec::new();let mut suffix=Vec::new();let mut ips=Vec::new();
    for entry in entries {
        let s=entry.trim();
        match behavior {
            "domain" => {
                let (s,is_suffix)=s.strip_prefix("+.").map(|s|(s,true)).unwrap_or((s,false));
                if s.is_empty() || s.contains(['*','+','/',':',',']) || s.chars().any(char::is_whitespace) {
                    return Err("规则集包含不支持的域名语法".into());
                }
                if is_suffix {suffix.push(s.to_string());} else {exact.push(s.to_string());}
            }
            "ip_cidr" => {
                let (ip,bits)=s.split_once('/').ok_or("规则集IP条目缺少CIDR前缀")?;
                let addr: std::net::IpAddr=ip.parse().map_err(|_| "规则集IP地址无效")?;
                let bits: u8=bits.parse().map_err(|_| "规则集CIDR前缀无效")?;
                if bits > if addr.is_ipv4(){32}else{128} {return Err("规则集CIDR前缀越界".into());}
                ips.push(s.to_string());
            }
            _ => return Err("规则集仅支持domain/ipcidr行为".into()),
        }
    }
    let mut rule=serde_json::Map::new();
    if !exact.is_empty(){rule.insert("domain".into(),json!(exact));}
    if !suffix.is_empty(){rule.insert("domain_suffix".into(),json!(suffix));}
    if !ips.is_empty(){rule.insert("ip_cidr".into(),json!(ips));}
    Ok(if rule.is_empty(){json!([])}else{json!([rule])})
}

#[cfg(test)]
mod provider_regressions {
    use super::*;
    #[test] fn yaml_and_text_provider_are_real_inline_rules() {
        assert_eq!(convert_provider("payload:\n - '+.example.com'\n - exact.example\n","domain","yaml").unwrap(),
            json!([{"domain":["exact.example"],"domain_suffix":["example.com"]}]));
        assert_eq!(convert_provider("# comment\n192.0.2.0/24\n2001:db8::/32","ip_cidr","text").unwrap(),
            json!([{"ip_cidr":["192.0.2.0/24","2001:db8::/32"]}]));
        assert!(convert_provider("payload: [5]","domain","yaml").is_err());
        assert!(convert_provider("192.0.2.0/99","ip_cidr","text").is_err());
        assert!(convert_provider("*.example.com","domain","text").is_err());
    }
    #[test] fn geoip_marker_survives_and_match_is_terminal() {
        let p=parse_clash_profile("rules:\n - GEOIP,CN,DIRECT\n - MATCH,DIRECT\n - DOMAIN,unreachable.example,REJECT\n").unwrap().unwrap();
        assert_eq!(p.route_rules.len(),1);assert_eq!(p.route_rules[0]["__geoip"],"CN");
        assert_eq!(p.final_outbound.as_deref(),Some("DIRECT"));
        assert!(parse_clash_profile("rules: broken").is_err());
    }
}
