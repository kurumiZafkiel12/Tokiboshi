//! Share link and subscription parsing.
//!
//! Converts the formats users actually paste — vless://, vmess://,
//! trojan://, hysteria2:// (hy2://) and ss:// links, either one by one
//! or bundled in a subscription (plain lines or one base64 blob) — into
//! sing-box outbound objects for `config::build_config`.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NodeInfo {
    pub name: String,
    /// A single sing-box outbound as JSON text.
    pub outbound_json: String,
}

fn b64_decode(input: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    let cleaned: String = input.chars().filter(|c| !c.is_whitespace()).collect();
    base64::engine::general_purpose::STANDARD
        .decode(&cleaned)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(&cleaned))
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(&cleaned))
        .map_err(|e| format!("invalid base64: {e}"))
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
            if let Ok(v) = u8::from_str_radix(hex, 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Minimal URL splitter for share links: scheme, userinfo, host, port,
/// query map, fragment (display name).
struct LinkParts {
    userinfo: String,
    host: String,
    port: u16,
    query: Map<String, Value>,
    name: String,
}

fn split_link(link: &str, scheme: &str) -> Result<LinkParts, String> {
    let rest = link
        .strip_prefix(&format!("{scheme}://"))
        .ok_or_else(|| format!("not a {scheme} link"))?;
    let (before_frag, name) = match rest.split_once('#') {
        Some((b, f)) => (b, percent_decode(f)),
        None => (rest, String::new()),
    };
    let (authority, query_str) = match before_frag.split_once('?') {
        Some((a, q)) => (a, q),
        None => (before_frag, ""),
    };
    // Authority may carry a path suffix (rare); drop it.
    let authority = authority.split('/').next().unwrap_or(authority);
    let (userinfo, hostport) = authority
        .rsplit_once('@')
        .ok_or_else(|| "link missing userinfo@host".to_string())?;
    let (host, port_str) = if let Some(stripped) = hostport.strip_prefix('[') {
        // IPv6 literal [::1]:443
        let end = stripped.find(']').ok_or("bad IPv6 host")?;
        let port = stripped[end + 1..].strip_prefix(':').unwrap_or("");
        (stripped[..end].to_string(), port.to_string())
    } else {
        match hostport.rsplit_once(':') {
            Some((h, p)) => (h.to_string(), p.to_string()),
            None => (hostport.to_string(), String::new()),
        }
    };
    let port: u16 = port_str
        .parse()
        .map_err(|_| format!("invalid port: {port_str}"))?;
    let mut query = Map::new();
    for pair in query_str.split('&').filter(|s| !s.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        query.insert(percent_decode(k), Value::String(percent_decode(v)));
    }
    Ok(LinkParts { userinfo: percent_decode(userinfo), host, port, query, name })
}

fn q<'a>(parts: &'a LinkParts, key: &str) -> Option<&'a str> {
    parts.query.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn tls_object(parts: &LinkParts, enabled: bool) -> Value {
    let mut tls = Map::new();
    tls.insert("enabled".into(), Value::Bool(enabled));
    if let Some(sni) = q(parts, "sni").or_else(|| q(parts, "peer")) {
        tls.insert("server_name".into(), Value::String(sni.to_string()));
    }
    if matches!(q(parts, "allowInsecure").or_else(|| q(parts, "insecure")), Some("1") | Some("true")) {
        tls.insert("insecure".into(), Value::Bool(true));
    }
    if let Some(alpn) = q(parts, "alpn") {
        tls.insert(
            "alpn".into(),
            Value::Array(alpn.split(',').map(|s| Value::String(s.to_string())).collect()),
        );
    }
    Value::Object(tls)
}

fn transport_object(parts: &LinkParts) -> Option<Value> {
    match q(parts, "type").or_else(|| q(parts, "net"))? {
        "ws" => {
            let mut t = Map::new();
            t.insert("type".into(), Value::String("ws".into()));
            if let Some(path) = q(parts, "path") {
                t.insert("path".into(), Value::String(path.to_string()));
            }
            if let Some(host) = q(parts, "host") {
                let mut headers = Map::new();
                headers.insert("Host".into(), Value::String(host.to_string()));
                t.insert("headers".into(), Value::Object(headers));
            }
            Some(Value::Object(t))
        }
        "grpc" => {
            let mut t = Map::new();
            t.insert("type".into(), Value::String("grpc".into()));
            if let Some(svc) = q(parts, "serviceName").or_else(|| q(parts, "service_name")) {
                t.insert("service_name".into(), Value::String(svc.to_string()));
            }
            Some(Value::Object(t))
        }
        "tcp" | "none" => None,
        _ => None,
    }
}

fn node(name: String, fallback: &str, outbound: Value) -> NodeInfo {
    NodeInfo {
        name: if name.is_empty() { fallback.to_string() } else { name },
        outbound_json: outbound.to_string(),
    }
}

pub fn parse_share_link(link: &str) -> Result<NodeInfo, String> {
    let link = link.trim();
    if let Some(rest) = link.strip_prefix("hy2://") {
        return parse_share_link(&format!("hysteria2://{rest}"));
    }
    if link.starts_with("vless://") {
        let p = split_link(link, "vless")?;
        let mut ob = Map::new();
        ob.insert("type".into(), "vless".into());
        ob.insert("server".into(), p.host.clone().into());
        ob.insert("server_port".into(), p.port.into());
        ob.insert("uuid".into(), p.userinfo.clone().into());
        let security = q(&p, "security").unwrap_or("none");
        if security == "tls" || security == "reality" {
            let mut tls = tls_object(&p, true);
            if security == "reality" {
                let mut reality = Map::new();
                if let Some(pbk) = q(&p, "pbk") {
                    reality.insert("public_key".into(), Value::String(pbk.to_string()));
                }
                if let Some(sid) = q(&p, "sid") {
                    reality.insert("short_id".into(), Value::String(sid.to_string()));
                }
                reality.insert("enabled".into(), Value::Bool(true));
                if let Some(m) = tls.as_object_mut() {
                    m.insert("reality".into(), Value::Object(reality));
                    m.insert("utls".into(), json!({"enabled": true, "fingerprint": q(&p, "fp").unwrap_or("chrome")}));
                }
            }
            ob.insert("tls".into(), tls);
        }
        if let Some(flow) = q(&p, "flow") {
            ob.insert("flow".into(), Value::String(flow.to_string()));
        }
        if let Some(t) = transport_object(&p) {
            ob.insert("transport".into(), t);
        }
        return Ok(node(p.name.clone(), &format!("vless-{}:{}", p.host, p.port), Value::Object(ob)));
    }
    if link.starts_with("trojan://") {
        let p = split_link(link, "trojan")?;
        let mut ob = Map::new();
        ob.insert("type".into(), "trojan".into());
        ob.insert("server".into(), p.host.clone().into());
        ob.insert("server_port".into(), p.port.into());
        ob.insert("password".into(), p.userinfo.clone().into());
        ob.insert("tls".into(), tls_object(&p, true));
        if let Some(t) = transport_object(&p) {
            ob.insert("transport".into(), t);
        }
        return Ok(node(p.name.clone(), &format!("trojan-{}:{}", p.host, p.port), Value::Object(ob)));
    }
    if link.starts_with("hysteria2://") {
        let p = split_link(link, "hysteria2")?;
        let mut ob = Map::new();
        ob.insert("type".into(), "hysteria2".into());
        ob.insert("server".into(), p.host.clone().into());
        ob.insert("server_port".into(), p.port.into());
        ob.insert("password".into(), p.userinfo.clone().into());
        ob.insert("tls".into(), tls_object(&p, true));
        if let Some(obfs_type) = q(&p, "obfs") {
            let mut obfs = Map::new();
            obfs.insert("type".into(), Value::String(obfs_type.to_string()));
            if let Some(pw) = q(&p, "obfs-password") {
                obfs.insert("password".into(), Value::String(pw.to_string()));
            }
            ob.insert("obfs".into(), Value::Object(obfs));
        }
        return Ok(node(p.name.clone(), &format!("hysteria2-{}:{}", p.host, p.port), Value::Object(ob)));
    }
    if link.starts_with("ss://") {
        let p = split_link(link, "ss")?;
        // userinfo is either "method:password" or base64 of it.
        let (method, password) = if p.userinfo.contains(':') {
            let (m, pw) = p.userinfo.split_once(':').unwrap();
            (m.to_string(), pw.to_string())
        } else {
            let raw = b64_decode(&p.userinfo)?;
            let text = String::from_utf8_lossy(&raw).into_owned();
            text.split_once(':')
                .map(|(m, pw)| (m.to_string(), pw.to_string()))
                .ok_or_else(|| "ss userinfo is not method:password".to_string())?
        };
        let ob = json!({
            "type": "shadowsocks",
            "server": p.host,
            "server_port": p.port,
            "method": method,
            "password": password
        });
        return Ok(node(p.name.clone(), &format!("ss-{}:{}", p.host, p.port), ob));
    }
    if link.starts_with("vmess://") {
        let raw = b64_decode(link.strip_prefix("vmess://").unwrap())?;
        let v: Value = serde_json::from_slice(&raw).map_err(|e| format!("invalid vmess JSON: {e}"))?;
        let get = |k: &str| v.get(k).and_then(|x| x.as_str().map(str::to_string).or_else(|| x.as_i64().map(|n| n.to_string()))).unwrap_or_default();
        let mut ob = Map::new();
        ob.insert("type".into(), "vmess".into());
        ob.insert("server".into(), get("add").into());
        let port: u16 = get("port").parse().map_err(|_| "invalid vmess port")?;
        ob.insert("server_port".into(), port.into());
        ob.insert("uuid".into(), get("id").into());
        ob.insert("security".into(), Value::String(if get("scy").is_empty() { "auto".into() } else { get("scy") }));
        ob.insert("alter_id".into(), Value::from(get("aid").parse::<i64>().unwrap_or(0)));
        if get("tls") == "tls" {
            let mut tls = Map::new();
            tls.insert("enabled".into(), Value::Bool(true));
            if !get("sni").is_empty() {
                tls.insert("server_name".into(), get("sni").into());
            }
            ob.insert("tls".into(), Value::Object(tls));
        }
        if get("net") == "ws" {
            let mut t = Map::new();
            t.insert("type".into(), Value::String("ws".into()));
            if !get("path").is_empty() {
                t.insert("path".into(), get("path").into());
            }
            if !get("host").is_empty() {
                let mut headers = Map::new();
                headers.insert("Host".into(), get("host").into());
                t.insert("headers".into(), Value::Object(headers));
            }
            ob.insert("transport".into(), Value::Object(t));
        }
        let name = if get("ps").is_empty() { format!("vmess-{}:{}", get("add"), port) } else { get("ps") };
        return Ok(NodeInfo { name, outbound_json: Value::Object(ob).to_string() });
    }
    Err("unsupported link scheme (vless/vmess/trojan/hysteria2/ss)".to_string())
}

fn yaml_to_json(v: &serde_yaml::Value) -> Value {
    match v {
        serde_yaml::Value::Null => Value::Null,
        serde_yaml::Value::Bool(b) => Value::Bool(*b),
        serde_yaml::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::from(i)
            } else if let Some(u) = n.as_u64() {
                Value::from(u)
            } else if let Some(f) = n.as_f64() {
                serde_json::Number::from_f64(f).map(Value::Number).unwrap_or(Value::Null)
            } else {
                Value::Null
            }
        }
        serde_yaml::Value::String(s) => Value::String(s.clone()),
        serde_yaml::Value::Sequence(seq) => Value::Array(seq.iter().map(yaml_to_json).collect()),
        serde_yaml::Value::Mapping(map) => {
            let mut out = Map::new();
            for (k, val) in map {
                if let serde_yaml::Value::String(key) = k {
                    out.insert(key.clone(), yaml_to_json(val));
                }
            }
            Value::Object(out)
        }
        serde_yaml::Value::Tagged(tagged) => yaml_to_json(&tagged.value),
    }
}

fn cs<'a>(m: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    m.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn cbool(m: &Map<String, Value>, key: &str) -> bool {
    m.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// TLS object from Clash-style fields (servername/sni,
/// skip-cert-verify, alpn, reality-opts, client-fingerprint).
fn clash_tls(m: &Map<String, Value>) -> Map<String, Value> {
    let mut tls = Map::new();
    tls.insert("enabled".into(), Value::Bool(true));
    if let Some(sni) = cs(m, "servername").or_else(|| cs(m, "sni")) {
        tls.insert("server_name".into(), Value::String(sni.to_string()));
    }
    if cbool(m, "skip-cert-verify") {
        tls.insert("insecure".into(), Value::Bool(true));
    }
    if let Some(alpn) = m.get("alpn").and_then(Value::as_array) {
        tls.insert("alpn".into(), Value::Array(alpn.clone()));
    }
    if let Some(reality) = m.get("reality-opts").and_then(Value::as_object) {
        let mut r = Map::new();
        r.insert("enabled".into(), Value::Bool(true));
        if let Some(pk) = cs(reality, "public-key") {
            r.insert("public_key".into(), Value::String(pk.to_string()));
        }
        if let Some(sid) = cs(reality, "short-id") {
            r.insert("short_id".into(), Value::String(sid.to_string()));
        }
        tls.insert("reality".into(), Value::Object(r));
        tls.insert(
            "utls".into(),
            json!({"enabled": true, "fingerprint": cs(m, "client-fingerprint").unwrap_or("chrome")}),
        );
    }
    tls
}

fn clash_transport(m: &Map<String, Value>) -> Option<Value> {
    match cs(m, "network")? {
        "ws" => {
            let mut t = Map::new();
            t.insert("type".into(), Value::String("ws".into()));
            if let Some(opts) = m.get("ws-opts").and_then(Value::as_object) {
                if let Some(path) = cs(opts, "path") {
                    t.insert("path".into(), Value::String(path.to_string()));
                }
                if let Some(host) = opts
                    .get("headers")
                    .and_then(Value::as_object)
                    .and_then(|h| cs(h, "Host"))
                {
                    let mut headers = Map::new();
                    headers.insert("Host".into(), Value::String(host.to_string()));
                    t.insert("headers".into(), Value::Object(headers));
                }
            }
            Some(Value::Object(t))
        }
        "grpc" => {
            let mut t = Map::new();
            t.insert("type".into(), Value::String("grpc".into()));
            if let Some(svc) = m
                .get("grpc-opts")
                .and_then(Value::as_object)
                .and_then(|o| cs(o, "grpc-service-name"))
            {
                t.insert("service_name".into(), Value::String(svc.to_string()));
            }
            Some(Value::Object(t))
        }
        _ => None,
    }
}

/// Convert one Clash proxy mapping into a sing-box outbound.
fn clash_proxy_to_outbound(m: &Map<String, Value>) -> Option<Value> {
    let typ = cs(m, "type")?;
    let server = cs(m, "server")?;
    let port = m.get("port").and_then(Value::as_u64)?;
    let mut ob = Map::new();
    ob.insert("server".into(), Value::String(server.to_string()));
    ob.insert("server_port".into(), Value::from(port));
    match typ {
        "ss" => {
            ob.insert("type".into(), "shadowsocks".into());
            ob.insert("method".into(), Value::String(cs(m, "cipher")?.to_string()));
            ob.insert("password".into(), Value::String(cs(m, "password")?.to_string()));
            if cs(m, "plugin") == Some("obfs") {
                let opts = m.get("plugin-opts").and_then(Value::as_object);
                let mode = opts.and_then(|o| cs(o, "mode")).unwrap_or("http");
                let host = opts.and_then(|o| cs(o, "host")).unwrap_or("");
                ob.insert("plugin".into(), Value::String("obfs-local".into()));
                ob.insert(
                    "plugin_opts".into(),
                    Value::String(format!("obfs={mode};obfs-host={host}")),
                );
            }
        }
        "vmess" => {
            ob.insert("type".into(), "vmess".into());
            ob.insert("uuid".into(), Value::String(cs(m, "uuid")?.to_string()));
            ob.insert(
                "security".into(),
                Value::String(cs(m, "cipher").unwrap_or("auto").to_string()),
            );
            ob.insert(
                "alter_id".into(),
                Value::from(m.get("alterId").and_then(Value::as_i64).unwrap_or(0)),
            );
            if cbool(m, "tls") {
                ob.insert("tls".into(), Value::Object(clash_tls(m)));
            }
            if let Some(t) = clash_transport(m) {
                ob.insert("transport".into(), t);
            }
        }
        "vless" => {
            ob.insert("type".into(), "vless".into());
            ob.insert("uuid".into(), Value::String(cs(m, "uuid")?.to_string()));
            if let Some(flow) = cs(m, "flow") {
                ob.insert("flow".into(), Value::String(flow.to_string()));
            }
            if cbool(m, "tls") {
                ob.insert("tls".into(), Value::Object(clash_tls(m)));
            }
            if let Some(t) = clash_transport(m) {
                ob.insert("transport".into(), t);
            }
        }
        "trojan" => {
            ob.insert("type".into(), "trojan".into());
            ob.insert("password".into(), Value::String(cs(m, "password")?.to_string()));
            ob.insert("tls".into(), Value::Object(clash_tls(m)));
            if let Some(t) = clash_transport(m) {
                ob.insert("transport".into(), t);
            }
        }
        "hysteria2" => {
            ob.insert("type".into(), "hysteria2".into());
            let password = cs(m, "password").or_else(|| cs(m, "auth"))?;
            ob.insert("password".into(), Value::String(password.to_string()));
            ob.insert("tls".into(), Value::Object(clash_tls(m)));
            if let Some(obfs_type) = cs(m, "obfs") {
                let mut obfs = Map::new();
                obfs.insert("type".into(), Value::String(obfs_type.to_string()));
                if let Some(pw) = cs(m, "obfs-password") {
                    obfs.insert("password".into(), Value::String(pw.to_string()));
                }
                ob.insert("obfs".into(), Value::Object(obfs));
            }
        }
        _ => return None,
    }
    Some(Value::Object(ob))
}

/// Parse a Clash YAML subscription (its `proxies:` list becomes nodes).
pub fn parse_clash_yaml(text: &str) -> Result<Vec<NodeInfo>, String> {
    let doc: serde_yaml::Value =
        serde_yaml::from_str(text).map_err(|e| format!("invalid YAML: {e}"))?;
    let doc = yaml_to_json(&doc);
    let proxies = doc
        .get("proxies")
        .and_then(Value::as_array)
        .ok_or("YAML has no proxies list")?;
    let nodes: Vec<NodeInfo> = proxies
        .iter()
        .filter_map(Value::as_object)
        .filter_map(|m| {
            let outbound = clash_proxy_to_outbound(m)?;
            let name = cs(m, "name")
                .map(str::to_string)
                .unwrap_or_else(|| "clash-node".to_string());
            Some(NodeInfo { name, outbound_json: outbound.to_string() })
        })
        .collect();
    if nodes.is_empty() {
        Err("no usable proxies in Clash YAML".to_string())
    } else {
        Ok(nodes)
    }
}

/// Parse subscription content: newline separated links, one base64 blob
/// of links, a sing-box JSON config (its outbounds become nodes), or a
/// Clash YAML document (its proxies become nodes).
/// Invalid lines are skipped; an error is returned only when nothing
/// usable was found.
pub fn parse_subscription(text: &str) -> Result<Vec<NodeInfo>, String> {
    let trimmed = text.trim();
    if trimmed.lines().any(|l| {
        let t = l.trim_start();
        t.starts_with("proxies:") || t.starts_with("proxies :")
    }) {
        return parse_clash_yaml(trimmed);
    }
    if trimmed.starts_with('{') {
        let v: Value = serde_json::from_str(trimmed).map_err(|e| format!("invalid JSON: {e}"))?;
        let outbounds = v
            .get("outbounds")
            .and_then(Value::as_array)
            .ok_or("JSON config has no outbounds")?;
        let nodes: Vec<NodeInfo> = outbounds
            .iter()
            .filter(|ob| ob.get("server").is_some())
            .map(|ob| {
                let tag = ob.get("tag").and_then(Value::as_str).unwrap_or("");
                let typ = ob.get("type").and_then(Value::as_str).unwrap_or("node");
                NodeInfo {
                    name: if tag.is_empty() { typ.to_string() } else { tag.to_string() },
                    outbound_json: ob.to_string(),
                }
            })
            .collect();
        if nodes.is_empty() {
            return Err("no usable outbounds in JSON config".to_string());
        }
        return Ok(nodes);
    }
    let decoded_text;
    let content: &str = if trimmed.contains("://") {
        trimmed
    } else {
        decoded_text = String::from_utf8_lossy(&b64_decode(trimmed)?).into_owned();
        &decoded_text
    };
    let nodes: Vec<NodeInfo> = content
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .filter_map(|l| parse_share_link(l).ok())
        .collect();
    if nodes.is_empty() {
        Err("no usable share links found".to_string())
    } else {
        Ok(nodes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn out(node: &NodeInfo) -> Value {
        serde_json::from_str(&node.outbound_json).unwrap()
    }

    #[test]
    fn parses_vless_tls_ws() {
        let n = parse_share_link("vless://11111111-2222-3333-4444-555555555555@example.com:443?security=tls&sni=example.com&type=ws&path=%2Fws&host=cdn.example.com#My%20Node").unwrap();
        assert_eq!(n.name, "My Node");
        let ob = out(&n);
        assert_eq!(ob["type"], "vless");
        assert_eq!(ob["server_port"], 443);
        assert_eq!(ob["tls"]["server_name"], "example.com");
        assert_eq!(ob["transport"]["type"], "ws");
        assert_eq!(ob["transport"]["path"], "/ws");
    }

    #[test]
    fn parses_hysteria2_with_obfs() {
        let n = parse_share_link("hysteria2://passw0rd@hy.example.com:443?sni=hy.example.com&obfs=salamander&obfs-password=obfspw#HY2").unwrap();
        let ob = out(&n);
        assert_eq!(ob["type"], "hysteria2");
        assert_eq!(ob["password"], "passw0rd");
        assert_eq!(ob["obfs"]["type"], "salamander");
    }

    #[test]
    fn parses_trojan() {
        let n = parse_share_link("trojan://secret@tr.example.com:8443?sni=tr.example.com#TR").unwrap();
        let ob = out(&n);
        assert_eq!(ob["type"], "trojan");
        assert_eq!(ob["server_port"], 8443);
        assert_eq!(ob["tls"]["enabled"], true);
    }

    #[test]
    fn parses_ss_base64_userinfo() {
        use base64::Engine;
        let ui = base64::engine::general_purpose::STANDARD.encode("aes-256-gcm:mypassword");
        let n = parse_share_link(&format!("ss://{ui}@ss.example.com:8388#SS1")).unwrap();
        let ob = out(&n);
        assert_eq!(ob["type"], "shadowsocks");
        assert_eq!(ob["method"], "aes-256-gcm");
        assert_eq!(ob["password"], "mypassword");
    }

    #[test]
    fn parses_vmess() {
        use base64::Engine;
        let j = r#"{"v":"2","ps":"VM1","add":"vm.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","scy":"auto","net":"ws","host":"cdn.example.com","path":"/vm","tls":"tls","sni":"vm.example.com"}"#;
        let link = format!("vmess://{}", base64::engine::general_purpose::STANDARD.encode(j));
        let n = parse_share_link(&link).unwrap();
        assert_eq!(n.name, "VM1");
        let ob = out(&n);
        assert_eq!(ob["type"], "vmess");
        assert_eq!(ob["transport"]["type"], "ws");
        assert_eq!(ob["tls"]["enabled"], true);
    }

    #[test]
    fn parses_base64_subscription() {
        use base64::Engine;
        let blob = "trojan://secret@a.example.com:443#A\nss://aes-128-gcm:pw@b.example.com:8388#B\n";
        let encoded = base64::engine::general_purpose::STANDARD.encode(blob);
        let nodes = parse_subscription(&encoded).unwrap();
        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0].name, "A");
        assert_eq!(nodes[1].name, "B");
    }

    #[test]
    fn parses_singbox_json_subscription() {
        let text = r#"{"outbounds":[{"type":"hysteria2","tag":"n1","server":"h.example.com","server_port":443,"password":"x","tls":{"enabled":true}},{"type":"direct","tag":"direct"}]}"#;
        let nodes = parse_subscription(text).unwrap();
        assert_eq!(nodes.len(), 1);
        assert_eq!(nodes[0].name, "n1");
    }

    #[test]
    fn parses_hy2_alias() {
        let n = parse_share_link("hy2://pw@hy2.example.com:443?sni=hy2.example.com#A2").unwrap();
        let ob = out(&n);
        assert_eq!(ob["type"], "hysteria2");
        assert_eq!(n.name, "A2");
    }

    #[test]
    fn parses_clash_yaml() {
        let yaml = r#"
proxies:
  - name: "YAML-SS"
    type: ss
    server: ss.example.com
    port: 8388
    cipher: aes-256-gcm
    password: pw1
  - name: "YAML-VLESS"
    type: vless
    server: vl.example.com
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    tls: true
    servername: vl.example.com
    reality-opts:
      public-key: PUBKEY
      short-id: ab12
  - name: "YAML-HY2"
    type: hysteria2
    server: hy.example.com
    port: 443
    password: pw3
    sni: hy.example.com
    skip-cert-verify: true
  - name: "YAML-TUIC"
    type: tuic
    server: tu.example.com
    port: 443
"#;
        let nodes = parse_subscription(yaml).unwrap();
        assert_eq!(nodes.len(), 3);
        assert_eq!(nodes[0].name, "YAML-SS");
        assert_eq!(out(&nodes[0])["method"], "aes-256-gcm");
        assert_eq!(out(&nodes[1])["tls"]["reality"]["public_key"], "PUBKEY");
        assert_eq!(out(&nodes[2])["tls"]["insecure"], true);
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_share_link("https://example.com").is_err());
        assert!(parse_subscription("not a subscription at all!!!").is_err());
    }
}
