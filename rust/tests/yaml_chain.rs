//! End-to-end: Clash YAML subscription -> outbound -> sing-box config
//! -> real `sing-box check` (skipped when no sing-box binary is found).

use rust_lib_tokiboshi::config::{build_config, CoreSettings};
use rust_lib_tokiboshi::links::parse_subscription;

#[test]
fn clash_yaml_nodes_pass_sing_box_check() {
    let sing_box = std::env::var("SING_BOX").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_default();
        // The generated config targets the pinned 1.14 format.
        let pinned = format!("{home}/opt/sing-box-1.14.4/sing-box");
        if std::path::Path::new(&pinned).exists() {
            pinned
        } else {
            format!("{home}/opt/sing-box/sing-box")
        }
    });
    if !std::path::Path::new(&sing_box).exists() {
        eprintln!("sing-box binary not found at {sing_box}, skipping");
        return;
    }
    let yaml = r#"
proxies:
  - name: "CHAIN-HY2"
    type: hysteria2
    server: 127.0.0.1
    port: 443
    password: pw
    sni: example.com
  - name: "CHAIN-VLESS"
    type: vless
    server: 127.0.0.1
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    tls: true
    servername: example.com
    reality-opts:
      public-key: UYAJI0NMP2K4jMiSrqGgVKd3Z3Z3Z3Z3Z3Z3Z3Z3Z3Q
      short-id: ab12
  - name: "CHAIN-SOCKS"
    type: socks5
    server: 127.0.0.1
    port: 1080
    username: u
    password: p
  - name: "CHAIN-TUIC"
    type: tuic
    server: 127.0.0.1
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    password: tpw
    sni: example.com
"#;
    let outcome = parse_subscription(yaml).unwrap();
    let nodes = outcome.nodes;
    assert_eq!(nodes.len(), 4);
    assert!(outcome.skipped.is_empty());
    for node in &nodes {
        let outbound: serde_json::Value =
            serde_json::from_str(&node.outbound_json).unwrap();
        let config = build_config(&outbound, &CoreSettings::default()).unwrap();
        let path = std::env::temp_dir().join(format!("tokiboshi-chain-{}.json", node.name));
        std::fs::write(&path, &config).unwrap();
        let output = std::process::Command::new(&sing_box)
            .args(["check", "-c"])
            .arg(&path)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "sing-box check failed for {}: {}",
            node.name,
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
