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

/// Result of parsing subscription content: converted nodes plus a
/// human-readable note per entry that had to be skipped (currently
/// unsupported type), formatted as "name (type)".
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ParseOutcome {
    pub nodes: Vec<NodeInfo>,
    pub skipped: Vec<String>,
    /// Node sources declared by a Clash YAML `proxy-providers:`
    /// section. The caller fetches each provider and parses its
    /// content as another subscription; other formats leave this
    /// empty.
    #[serde(default)]
    pub providers: Vec<ProviderInfo>,
}

/// One entry of a Clash YAML `proxy-providers:` section (http type).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProviderInfo {
    pub name: String,
    pub url: String,
    pub user_agent: Option<String>,
    pub exclude_filter: Option<String>,
    pub filter: Option<String>,
}

fn b64_decode(input: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    let cleaned: String = input.chars().filter(|c| !c.is_whitespace()).collect();
    base64::engine::general_purpose::STANDARD
        .decode(&cleaned)
        .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(&cleaned))
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

/// "20000-30000,30001" -> ["20000:30000", "30001"] (sing-box
/// `server_ports` syntax uses colons for ranges).
fn parse_port_ranges(raw: &str) -> Vec<String> {
    raw.split(',')
        .map(|t| t.trim().replace('-', ":"))
        .filter(|t| !t.is_empty())
        .collect()
}

/// Clash `ports:` value (string or list) -> sing-box server_ports.
fn clash_ports(m: &Map<String, Value>) -> Vec<String> {
    match m.get("ports") {
        Some(Value::String(s)) => parse_port_ranges(s),
        Some(Value::Array(a)) => a
            .iter()
            .flat_map(|v| match v {
                Value::String(s) => parse_port_ranges(s),
                Value::Number(n) => vec![n.to_string()],
                _ => Vec::new(),
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn first_port_of(ranges: &[String]) -> Option<u64> {
    ranges.first()?.split(':').next()?.parse().ok()
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
        if let Some(mport) = q(&p, "mport") {
            let ranges = parse_port_ranges(mport);
            if !ranges.is_empty() {
                ob.insert("server_ports".into(), json!(ranges));
            }
        }
        return Ok(node(p.name.clone(), &format!("hysteria2-{}:{}", p.host, p.port), Value::Object(ob)));
    }
    if link.starts_with("anytls://") {
        let p = split_link(link, "anytls")?;
        let mut ob = Map::new();
        ob.insert("type".into(), "anytls".into());
        ob.insert("server".into(), p.host.clone().into());
        ob.insert("server_port".into(), p.port.into());
        ob.insert("password".into(), p.userinfo.clone().into());
        let mut tls = tls_object(&p, true);
        if let Some(m) = tls.as_object_mut() {
            m.insert(
                "utls".into(),
                json!({"enabled": true, "fingerprint": q(&p, "fp").unwrap_or("chrome")}),
            );
        }
        ob.insert("tls".into(), tls);
        return Ok(node(p.name.clone(), &format!("anytls-{}:{}", p.host, p.port), Value::Object(ob)));
    }
    if link.starts_with("tuic://") {
        let p = split_link(link, "tuic")?;
        let (uuid, password) = match p.userinfo.split_once(':') {
            Some((u, pw)) => (u.to_string(), pw.to_string()),
            None => (p.userinfo.clone(), String::new()),
        };
        let mut ob = Map::new();
        ob.insert("type".into(), "tuic".into());
        ob.insert("server".into(), p.host.clone().into());
        ob.insert("server_port".into(), p.port.into());
        ob.insert("uuid".into(), uuid.into());
        if !password.is_empty() {
            ob.insert("password".into(), password.into());
        }
        ob.insert(
            "congestion_control".into(),
            Value::String(q(&p, "congestion_control").unwrap_or("bbr").to_string()),
        );
        ob.insert(
            "udp_relay_mode".into(),
            Value::String(q(&p, "udp_relay_mode").unwrap_or("native").to_string()),
        );
        let mut tls = tls_object(&p, true);
        if let Some(m) = tls.as_object_mut() {
            if !m.contains_key("alpn") {
                m.insert("alpn".into(), json!(["h3"]));
            }
        }
        ob.insert("tls".into(), tls);
        return Ok(node(p.name.clone(), &format!("tuic-{}:{}", p.host, p.port), Value::Object(ob)));
    }
    if link.starts_with("hysteria://") {
        // v1 links carry no userinfo; auth is a query parameter.
        let rest = link.strip_prefix("hysteria://").unwrap();
        let (before_frag, name) = match rest.split_once('#') {
            Some((b, f)) => (b, percent_decode(f)),
            None => (rest, String::new()),
        };
        let (authority, query_str) = match before_frag.split_once('?') {
            Some((a, q)) => (a, q),
            None => (before_frag, ""),
        };
        let authority = authority.split('/').next().unwrap_or(authority);
        let (host, port_str) = match authority.rsplit_once(':') {
            Some((h, p)) => (h.to_string(), p.to_string()),
            None => (authority.to_string(), String::new()),
        };
        let port: u16 = port_str.parse().map_err(|_| format!("invalid port: {port_str}"))?;
        let mut query = Map::new();
        for pair in query_str.split('&').filter(|x| !x.is_empty()) {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            query.insert(percent_decode(k), Value::String(percent_decode(v)));
        }
        let p = LinkParts { userinfo: String::new(), host: host.clone(), port, query, name: name.clone() };
        let mut ob = Map::new();
        ob.insert("type".into(), "hysteria".into());
        ob.insert("server".into(), host.clone().into());
        ob.insert("server_port".into(), port.into());
        if let Some(auth) = q(&p, "auth") {
            ob.insert("auth_str".into(), Value::String(auth.to_string()));
        }
        if let Some(up) = q(&p, "upmbps").and_then(|v| v.parse::<u64>().ok()) {
            ob.insert("up_mbps".into(), Value::from(up));
        }
        if let Some(down) = q(&p, "downmbps").and_then(|v| v.parse::<u64>().ok()) {
            ob.insert("down_mbps".into(), Value::from(down));
        }
        if let Some(obfs) = q(&p, "obfs") {
            ob.insert("obfs".into(), Value::String(obfs.to_string()));
        }
        if let Some(mport) = q(&p, "mport") {
            let ranges = parse_port_ranges(mport);
            if !ranges.is_empty() {
                ob.insert("server_ports".into(), json!(ranges));
            }
        }
        ob.insert("tls".into(), tls_object(&p, true));
        return Ok(node(name, &format!("hysteria-{host}:{port}"), Value::Object(ob)));
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
    if link.starts_with("socks://") || link.starts_with("socks5://") {
        return parse_socks_link(link);
    }
    Err("unsupported link scheme (vless/vmess/trojan/hysteria2/ss/socks)".to_string())
}

fn parse_host_port(s: &str) -> Result<(String, u16), String> {
    let (host, port_s) = if let Some(close) = s.find(']') {
        let port = s[close + 1..]
            .strip_prefix(':')
            .ok_or_else(|| "missing port".to_string())?;
        (s[1..close].to_string(), port)
    } else {
        let (h, p) = s.rsplit_once(':').ok_or("missing port")?;
        (h.to_string(), p)
    };
    let port = port_s.parse().map_err(|_| "bad port".to_string())?;
    Ok((host, port))
}

/// socks:// / socks5:// — userinfo may be plain user:pass, a base64
/// blob, or the whole authority may be base64 (v2rayN style).
fn parse_socks_link(link: &str) -> Result<NodeInfo, String> {
    let scheme = if link.starts_with("socks5://") { "socks5" } else { "socks" };
    if link.contains('@') {
        let p = split_link(link, scheme)?;
        // userinfo is either "user:password" or base64 of it.
        let (username, password) = if p.userinfo.contains(':') {
            let (u, pw) = p.userinfo.split_once(':').unwrap();
            (Some(u.to_string()), Some(pw.to_string()))
        } else if let Ok(raw) = b64_decode(&p.userinfo) {
            let text = String::from_utf8_lossy(&raw).into_owned();
            match text.split_once(':') {
                Some((u, pw)) => (Some(u.to_string()), Some(pw.to_string())),
                None => (Some(p.userinfo.clone()), None),
            }
        } else {
            (Some(p.userinfo.clone()), None)
        };
        let mut ob = json!({
            "type": "socks", "version": "5",
            "server": p.host, "server_port": p.port
        });
        if let Some(u) = username {
            ob["username"] = Value::String(u);
        }
        if let Some(pw) = password {
            ob["password"] = Value::String(pw);
        }
        return Ok(node(p.name.clone(), &format!("socks-{}:{}", p.host, p.port), ob));
    }
    // No '@': try base64 whole-authority, else plain host:port.
    let rest = link.split_once("://").unwrap().1;
    let (main, frag) = match rest.split_once('#') {
        Some((m, f)) => (m, Some(percent_decode(f))),
        None => (rest, None),
    };
    let authority = main.split(['?', '/']).next().unwrap_or("");
    let decoded = b64_decode(authority)
        .map(|raw| String::from_utf8_lossy(&raw).into_owned())
        .unwrap_or_default();
    let (userinfo, hostport) = match decoded.rsplit_once('@') {
        Some((u, h)) => (Some(u.to_string()), h.to_string()),
        None => (None, authority.to_string()),
    };
    let (server, port) = parse_host_port(&hostport)?;
    let mut ob = json!({
        "type": "socks", "version": "5",
        "server": server, "server_port": port
    });
    if let Some(ui) = userinfo {
        if let Some((u, pw)) = ui.split_once(':') {
            ob["username"] = Value::String(u.to_string());
            ob["password"] = Value::String(pw.to_string());
        }
    }
    let name = frag
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| format!("socks-{server}:{port}"));
    Ok(NodeInfo { name, outbound_json: ob.to_string() })
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
    if !tls.contains_key("utls") {
        if let Some(fp) = cs(m, "client-fingerprint") {
            tls.insert(
                "utls".into(),
                json!({"enabled": true, "fingerprint": fp}),
            );
        }
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
    let ports = clash_ports(m);
    let port = m.get("port").and_then(|v| v.as_u64().or_else(|| v.as_str()?.parse().ok()))
        .or_else(|| first_port_of(&ports))?;
    if port == 0 || port > u16::MAX as u64 { return None; }
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
        "anytls" => {
            ob.insert("type".into(), "anytls".into());
            ob.insert("password".into(), Value::String(cs(m, "password")?.to_string()));
            ob.insert("tls".into(), Value::Object(clash_tls(m)));
        }
        "hysteria2" | "hy2" => {
            ob.insert("type".into(), "hysteria2".into());
            let password = cs(m, "password").or_else(|| cs(m, "auth"))?;
            ob.insert("password".into(), Value::String(password.to_string()));
            ob.insert("tls".into(), Value::Object(clash_tls(m)));
            if !ports.is_empty() {
                ob.insert("server_ports".into(), json!(ports));
            }
            if let Some(obfs_type) = cs(m, "obfs") {
                let mut obfs = Map::new();
                obfs.insert("type".into(), Value::String(obfs_type.to_string()));
                if let Some(pw) = cs(m, "obfs-password") {
                    obfs.insert("password".into(), Value::String(pw.to_string()));
                }
                ob.insert("obfs".into(), Value::Object(obfs));
            }
        }
        "socks5" | "socks" => {
            ob.insert("type".into(), "socks".into());
            ob.insert("version".into(), Value::String("5".into()));
            if let Some(u) = cs(m, "username") {
                ob.insert("username".into(), Value::String(u.to_string()));
            }
            if let Some(p) = cs(m, "password") {
                ob.insert("password".into(), Value::String(p.to_string()));
            }
        }
        "http" => {
            ob.insert("type".into(), "http".into());
            if let Some(u) = cs(m, "username") {
                ob.insert("username".into(), Value::String(u.to_string()));
            }
            if let Some(p) = cs(m, "password") {
                ob.insert("password".into(), Value::String(p.to_string()));
            }
            if cbool(m, "tls") {
                ob.insert("tls".into(), Value::Object(clash_tls(m)));
            }
        }
        "hysteria" => {
            ob.insert("type".into(), "hysteria".into());
            if let Some(auth) = cs(m, "auth-str").or_else(|| cs(m, "auth_str")) {
                ob.insert("auth_str".into(), Value::String(auth.to_string()));
            }
            let mbps = |key: &str| -> Option<u64> {
                match m.get(key) {
                    Some(Value::Number(n)) => n.as_u64(),
                    Some(Value::String(s)) => {
                        let digits: String =
                            s.chars().take_while(|c| c.is_ascii_digit()).collect();
                        digits.parse().ok()
                    }
                    _ => None,
                }
            };
            if let Some(up) = mbps("up") {
                ob.insert("up_mbps".into(), Value::from(up));
            }
            if let Some(down) = mbps("down") {
                ob.insert("down_mbps".into(), Value::from(down));
            }
            if let Some(obfs) = cs(m, "obfs") {
                ob.insert("obfs".into(), Value::String(obfs.to_string()));
            }
            if !ports.is_empty() {
                ob.insert("server_ports".into(), json!(ports));
            }
            ob.insert("tls".into(), Value::Object(clash_tls(m)));
        }
        "tuic" => {
            ob.insert("type".into(), "tuic".into());
            ob.insert("uuid".into(), Value::String(cs(m, "uuid")?.to_string()));
            ob.insert("password".into(), Value::String(cs(m, "password")?.to_string()));
            ob.insert(
                "congestion_control".into(),
                Value::String(
                    cs(m, "congestion-controller").unwrap_or("bbr").to_string(),
                ),
            );
            ob.insert(
                "udp_relay_mode".into(),
                Value::String(cs(m, "udp-relay-mode").unwrap_or("native").to_string()),
            );
            if cbool(m, "reduce-rtt") {
                ob.insert("zero_rtt_handshake".into(), Value::Bool(true));
            }
            let mut tls = clash_tls(m);
            if !tls.contains_key("alpn") {
                tls.insert("alpn".into(), json!(["h3"]));
            }
            if cbool(m, "disable-sni") {
                tls.insert("disable_sni".into(), Value::Bool(true));
            }
            ob.insert("tls".into(), Value::Object(tls));
        }
        _ => return None,
    }
    if let Some(via) = cs(m, "dialer-proxy") {
        ob.insert("detour".into(), Value::String(if via == "DIRECT" { "direct" } else { via }.into()));
    }
    Some(Value::Object(ob))
}

/// Parse a Clash YAML subscription (its `proxies:` list becomes nodes).
pub fn parse_clash_yaml(text: &str) -> Result<ParseOutcome, String> {
    let mut doc: serde_yaml::Value =
        serde_yaml::from_str(text).map_err(|e| format!("invalid YAML: {e}"))?;
    doc.apply_merge().map_err(|e| format!("invalid YAML merge: {e}"))?;
    let doc = yaml_to_json(&doc);
    let proxies = doc
        .as_array().or_else(|| doc.get("proxies").or_else(|| doc.get("payload")).and_then(Value::as_array))
        .map(Vec::as_slice).unwrap_or(&[]);
    let mut nodes = Vec::new();
    let mut skipped = Vec::new();
    for proxy in proxies.iter().filter_map(Value::as_object) {
        let name = cs(proxy, "name")
            .map(str::to_string)
            .unwrap_or_else(|| "clash-node".to_string());
        match clash_proxy_to_outbound(proxy) {
            Some(outbound) => nodes.push(NodeInfo {
                name,
                outbound_json: outbound.to_string(),
            }),
            None => {
                let typ = cs(proxy, "type").unwrap_or("unknown");
                skipped.push(format!("{name} ({typ})"));
            }
        }
    }
    let mut providers = Vec::new();
    if let Some(map) = doc.get("proxy-providers").and_then(Value::as_object) {
        for (pname, pval) in map {
            let Some(pobj) = pval.as_object() else { continue };
            let ptype = cs(pobj, "type").unwrap_or("http");
            let url = if ptype == "inline" {
                let Some(payload) = pobj.get("payload").and_then(Value::as_array) else {
                    skipped.push(format!("节点源「{pname}」缺少内联 payload"));
                    continue;
                };
                use base64::Engine;
                format!("data:application/json;base64,{}", base64::engine::general_purpose::STANDARD.encode(
                    json!({"proxies": payload}).to_string()))
            } else if ptype == "http" {
                let Some(url) = cs(pobj, "url").filter(|s| !s.is_empty()) else {
                    skipped.push(format!("节点源「{pname}」缺少 URL"));
                    continue;
                };
                url.to_string()
            } else {
                skipped.push(format!("节点源「{pname}」类型 {ptype} 暂不支持"));
                continue;
            };
            let user_agent = pobj
                .get("header")
                .and_then(Value::as_object)
                .and_then(|h| h.iter().find(|(key, _)| key.eq_ignore_ascii_case("user-agent")).map(|(_, value)| value))
                .and_then(|ua| match ua {
                    Value::String(t) => Some(t.clone()),
                    Value::Array(items) => items.iter().find_map(Value::as_str).map(str::to_string),
                    _ => None,
                });
            providers.push(ProviderInfo {
                name: pname.clone(),
                url: url.to_string(),
                user_agent,
                exclude_filter: cs(pobj, "exclude-filter").map(str::to_string),
                filter: cs(pobj, "filter").map(str::to_string),
            });
        }
    }
    if nodes.is_empty() && providers.is_empty() {
        Err("no usable proxies in Clash YAML".to_string())
    } else {
        Ok(ParseOutcome { nodes, skipped, providers })
    }
}

/// Parse subscription content: newline separated links, one base64 blob
/// of links, a sing-box JSON config (its outbounds become nodes), or a
/// Clash YAML document (its proxies become nodes).
/// Invalid lines are skipped; an error is returned only when nothing
/// usable was found.
pub fn parse_subscription(text: &str) -> Result<ParseOutcome, String> {
    parse_subscription_inner(text, 0)
}

fn parse_subscription_inner(text: &str, depth: usize) -> Result<ParseOutcome, String> {
    if depth > 4 { return Err("subscription encoding nesting is too deep".into()); }
    let trimmed = text.trim().trim_start_matches('\u{feff}');
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        let v: Value = serde_json::from_str(trimmed).map_err(|e| format!("invalid JSON: {e}"))?;
        if v.get("proxies").is_some() || v.get("proxy-providers").is_some() || v.get("payload").is_some()
            || v.as_array().is_some_and(|items| items.iter().any(|item| item.get("name").is_some() && item.get("port").is_some())) {
            return parse_clash_yaml(trimmed);
        }
        let outbounds = v.get("outbounds").and_then(Value::as_array).or_else(|| v.as_array())
            .ok_or("JSON config has no outbounds")?;
        let nodes: Vec<NodeInfo> = outbounds.iter()
            .filter(|ob| ob.get("server").is_some())
            .map(|ob| NodeInfo {
                name: ob.get("tag").and_then(Value::as_str).filter(|s| !s.is_empty())
                    .unwrap_or_else(|| ob.get("type").and_then(Value::as_str).unwrap_or("node")).into(),
                outbound_json: ob.to_string(),
            }).collect();
        if nodes.is_empty() { return Err("no usable outbounds in JSON config".into()); }
        return Ok(ParseOutcome { nodes, skipped: vec![], providers: vec![] });
    }
    if trimmed.starts_with("- ") || trimmed.lines().any(|l| {
        let t = l.trim_start();
        ["proxies", "proxy-providers", "payload"].iter().any(|key|
            t.strip_prefix(key).is_some_and(|rest| rest.trim_start().starts_with(':')))
    }) { return parse_clash_yaml(trimmed); }
    if !trimmed.contains("://") {
        let decoded = String::from_utf8(b64_decode(trimmed)?).map_err(|_| "subscription is not UTF-8")?;
        return parse_subscription_inner(&decoded, depth + 1);
    }
    let mut nodes = Vec::new();
    let mut skipped = Vec::new();
    let mut providers = Vec::new();
    for line in trimmed.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
        if line.starts_with("https://") || line.starts_with("http://") {
            providers.push(ProviderInfo { name: String::new(), url: line.into(), user_agent: None,
                exclude_filter: None, filter: None });
            continue;
        }
        match parse_share_link(line) {
            Ok(n) => nodes.push(n),
            Err(_) => {
                let scheme = line.split_once("://").map(|(s, _)| s).unwrap_or("invalid");
                skipped.push(format!("未识别链接 ({scheme})"));
            }
        }
    }
    if nodes.is_empty() && providers.is_empty() { Err("no usable share links found".into()) }
    else { Ok(ParseOutcome { nodes, skipped, providers }) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn out(node: &NodeInfo) -> Value {
        serde_json::from_str(&node.outbound_json).unwrap()
    }

    #[test]
    fn inline_provider_payload_is_preserved_for_recursive_filtering() {
        let result = parse_subscription(r#"
proxy-providers:
  local:
    type: inline
    filter: JP
    payload:
      - {name: JP, type: socks5, server: 127.0.0.1, port: 1080}
  remote:
    type: http
    url: https://example.com/sub
    header: {user-agent: [Clash.Meta]}
"#).unwrap();
        assert_eq!(result.providers.len(), 2);
        let inline = result.providers.iter().find(|p| p.name == "local").unwrap();
        assert_eq!(inline.filter.as_deref(), Some("JP"));
        let encoded = inline.url.strip_prefix("data:application/json;base64,").unwrap();
        let payload = String::from_utf8(b64_decode(encoded).unwrap()).unwrap();
        let nodes = parse_subscription(&payload).unwrap().nodes;
        assert_eq!(nodes.len(), 1);
        assert_eq!(out(&nodes[0])["type"], "socks");
        assert_eq!(result.providers.iter().find(|p| p.name == "remote").unwrap().user_agent.as_deref(), Some("Clash.Meta"));
    }

    #[test]
    fn clash_proxy_arrays_are_converted_instead_of_treated_as_sing_box() {
        for text in [r#"[{"name":"local","type":"socks5","server":"127.0.0.1","port":1080}]"#,
            "- name: local\n  type: socks5\n  server: 127.0.0.1\n  port: 1080\n"] {
            let nodes = parse_subscription(text).unwrap().nodes;
            assert_eq!(nodes.len(), 1);
            assert_eq!(out(&nodes[0])["type"], "socks");
            assert_eq!(out(&nodes[0])["server_port"], 1080);
            assert!(out(&nodes[0]).get("port").is_none());
        }
    }

    #[test]
    fn provider_only_and_encoded_merged_subscriptions() {
        use base64::Engine;
        let text = "proxy-providers:\n  airport:\n    type: http\n    url: https://example.com/sub\n";
        assert_eq!(parse_subscription(text).unwrap().providers.len(), 1);
        let encoded = base64::engine::general_purpose::STANDARD_NO_PAD.encode(text);
        assert_eq!(parse_subscription(&encoded).unwrap().providers.len(), 1);
        let merged = "https://example.com/a\nhttps://example.com/b\nsocks5://127.0.0.1:1080#local";
        let outcome = parse_subscription(merged).unwrap();
        assert_eq!(outcome.providers.len(), 2);
        assert_eq!(outcome.nodes.len(), 1);
    }

    #[test]
    fn clash_json_and_yaml_merges_preserve_chain() {
        let yaml = "defaults: &base {type: socks5, server: 127.0.0.1, port: '1080'}\nproxies:\n  - {<<: *base, name: exit, dialer-proxy: entry}\n  - {<<: *base, name: entry}\n";
        let parsed = parse_subscription(yaml).unwrap();
        assert_eq!(out(&parsed.nodes[0])["detour"], "entry");
        assert_eq!(out(&parsed.nodes[0])["server_port"], 1080);
        let json = r#"{"proxies":[{"name":"a","type":"socks5","server":"127.0.0.1","port":1080}]}"#;
        assert_eq!(parse_subscription(json).unwrap().nodes.len(), 1);
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
        let outcome = parse_subscription(&encoded).unwrap();
        let nodes = outcome.nodes;
        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0].name, "A");
        assert_eq!(nodes[1].name, "B");
    }

    #[test]
    fn parses_singbox_json_subscription() {
        let text = r#"{"outbounds":[{"type":"hysteria2","tag":"n1","server":"h.example.com","server_port":443,"password":"x","tls":{"enabled":true}},{"type":"direct","tag":"direct"}]}"#;
        let nodes = parse_subscription(text).unwrap().nodes;
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
    fn anytls_link_parses() {
        let n = parse_share_link("anytls://secret@a.example.com:443?sni=a.example.com&insecure=1#我的anytls").unwrap();
        assert_eq!(n.name, "我的anytls");
        let ob: Value = serde_json::from_str(&n.outbound_json).unwrap();
        assert_eq!(ob["type"], "anytls");
        assert_eq!(ob["password"], "secret");
        assert_eq!(ob["tls"]["server_name"], "a.example.com");
        assert_eq!(ob["tls"]["insecure"], true);
        assert_eq!(ob["tls"]["utls"]["fingerprint"], "chrome");
    }

    #[test]
    fn tuic_link_parses() {
        let n = parse_share_link("tuic://11111111-2222-3333-4444-555555555555:pw@t.example.com:443?congestion_control=cubic&sni=t.example.com#tuic1").unwrap();
        let ob: Value = serde_json::from_str(&n.outbound_json).unwrap();
        assert_eq!(ob["type"], "tuic");
        assert_eq!(ob["uuid"], "11111111-2222-3333-4444-555555555555");
        assert_eq!(ob["password"], "pw");
        assert_eq!(ob["congestion_control"], "cubic");
        assert_eq!(ob["tls"]["alpn"][0], "h3");
    }

    #[test]
    fn hysteria_v1_link_parses() {
        let n = parse_share_link("hysteria://h.example.com:443?auth=tok&peer=h.example.com&upmbps=50&downmbps=200&insecure=1#hy1").unwrap();
        let ob: Value = serde_json::from_str(&n.outbound_json).unwrap();
        assert_eq!(ob["type"], "hysteria");
        assert_eq!(ob["auth_str"], "tok");
        assert_eq!(ob["up_mbps"], 50);
        assert_eq!(ob["down_mbps"], 200);
    }

    #[test]
    fn hy2_link_mport_becomes_server_ports() {
        let n = parse_share_link("hysteria2://pw@h.example.com:443?mport=20000-30000&sni=h.example.com#hop").unwrap();
        let ob: Value = serde_json::from_str(&n.outbound_json).unwrap();
        assert_eq!(ob["server_ports"][0], "20000:30000");
    }

    #[test]
    fn clash_yaml_anytls_and_ports_only_hy2() {
        let text = r#"
proxies:
  - {name: at1, type: anytls, server: a.example.com, port: 443, password: secret, sni: a.example.com, skip-cert-verify: true, client-fingerprint: chrome}
  - {name: hop1, type: hysteria2, server: h.example.com, ports: "20000-30000", password: pw, sni: h.example.com}
"#;
        let out = parse_clash_yaml(text).unwrap();
        assert_eq!(out.nodes.len(), 2, "skipped: {:?}", out.skipped);
        let at: Value = serde_json::from_str(&out.nodes[0].outbound_json).unwrap();
        assert_eq!(at["type"], "anytls");
        assert_eq!(at["tls"]["utls"]["fingerprint"], "chrome");
        let hop: Value = serde_json::from_str(&out.nodes[1].outbound_json).unwrap();
        assert_eq!(hop["type"], "hysteria2");
        assert_eq!(hop["server_port"], 20000);
        assert_eq!(hop["server_ports"][0], "20000:30000");
    }

    #[test]
    fn clash_yaml_extracts_proxy_providers() {
        let yaml = r#"
mixed-port: 7890
proxies:
  - {name: A, type: socks5, server: 127.0.0.1, port: 1080}
proxy-providers:
  ProvOne:
    type: http
    url: "https://example.com/sub1"
    header:
      User-Agent: ["Clash.Meta"]
    exclude-filter: "(?i)traffic|expire"
  ProvTwo:
    type: file
    path: ./local.yaml
"#;
        let outcome = parse_clash_yaml(yaml).unwrap();
        assert_eq!(outcome.nodes.len(), 1);
        assert_eq!(outcome.providers.len(), 1);
        let p = &outcome.providers[0];
        assert_eq!(p.name, "ProvOne");
        assert_eq!(p.url, "https://example.com/sub1");
        assert_eq!(p.user_agent.as_deref(), Some("Clash.Meta"));
        assert_eq!(p.exclude_filter.as_deref(), Some("(?i)traffic|expire"));
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
        let outcome = parse_subscription(yaml).unwrap();
        let nodes = outcome.nodes;
        assert_eq!(nodes.len(), 3);
        assert_eq!(nodes[0].name, "YAML-SS");
        assert_eq!(out(&nodes[0])["method"], "aes-256-gcm");
        assert_eq!(out(&nodes[1])["tls"]["reality"]["public_key"], "PUBKEY");
        assert_eq!(out(&nodes[2])["tls"]["insecure"], true);
        // The tuic entry has no uuid/password: skipped, and reported.
        assert_eq!(outcome.skipped, vec!["YAML-TUIC (tuic)".to_string()]);
    }

    #[test]
    fn parses_clash_yaml_extra_types() {
        let yaml = r#"
proxies:
  - name: "SOCKS-NODE"
    type: socks5
    server: sk.example.com
    port: 1080
    username: u1
    password: p1
  - name: "HTTP-NODE"
    type: http
    server: ht.example.com
    port: 8080
  - name: "HY1-NODE"
    type: hysteria
    server: h1.example.com
    port: 443
    auth-str: a1
    up: 10 Mbps
    down: 50 Mbps
    sni: h1.example.com
  - name: "TUIC-NODE"
    type: tuic
    server: tu.example.com
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    password: tpw
    sni: tu.example.com
  - name: "WG-NODE"
    type: wireguard
    server: wg.example.com
    port: 51820
"#;
        let outcome = parse_subscription(yaml).unwrap();
        let nodes = outcome.nodes;
        assert_eq!(nodes.len(), 4);
        assert_eq!(out(&nodes[0])["type"], "socks");
        assert_eq!(out(&nodes[0])["username"], "u1");
        assert_eq!(out(&nodes[1])["type"], "http");
        assert_eq!(out(&nodes[2])["type"], "hysteria");
        assert_eq!(out(&nodes[2])["auth_str"], "a1");
        assert_eq!(out(&nodes[2])["up_mbps"], 10);
        assert_eq!(out(&nodes[3])["type"], "tuic");
        assert_eq!(out(&nodes[3])["tls"]["alpn"][0], "h3");
        assert_eq!(outcome.skipped, vec!["WG-NODE (wireguard)".to_string()]);
    }

    #[test]
    fn parses_socks_links() {
        let n = parse_share_link("socks5://user:pass@sk.example.com:1080#SK1").unwrap();
        let ob = out(&n);
        assert_eq!(ob["type"], "socks");
        assert_eq!(ob["server"], "sk.example.com");
        assert_eq!(ob["server_port"], 1080);
        assert_eq!(ob["username"], "user");
        assert_eq!(n.name, "SK1");
        // v2rayN base64 whole-authority form.
        use base64::Engine;
        let blob = base64::engine::general_purpose::STANDARD
            .encode("u2:p2@sk2.example.com:2080");
        let n2 = parse_share_link(&format!("socks://{blob}#SK2")).unwrap();
        let ob2 = out(&n2);
        assert_eq!(ob2["server"], "sk2.example.com");
        assert_eq!(ob2["server_port"], 2080);
        assert_eq!(ob2["password"], "p2");
        assert_eq!(n2.name, "SK2");
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_share_link("https://example.com").is_err());
        assert!(parse_subscription("not a subscription at all!!!").is_err());
    }
}
