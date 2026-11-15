//! Prints counts only; never prints subscription URLs, node names or credentials.
use rust_lib_tokiboshi::links::parse_subscription;
use std::{collections::BTreeMap, io::Read};
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    match parse_subscription(&input) {
        Ok(result) => {
            if let Some(path) = std::env::args().nth(1) {
                use rust_lib_tokiboshi::config::{build_config_multi, CoreSettings, NodeSpec};
                let nodes = result.nodes.iter().map(|n| NodeSpec { name: n.name.clone(), outbound_json: n.outbound_json.clone() }).collect::<Vec<_>>();
                let config = match build_config_multi(&nodes, &CoreSettings::default(), None) {
                    Ok(config) => config,
                    Err(_) => { eprintln!("Config generation failed"); std::process::exit(2); }
                };
                let mut options = std::fs::OpenOptions::new();
                options.write(true).create_new(true);
                #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
                use std::io::Write;
                options.open(path).expect("use a new private output path").write_all(config.as_bytes()).unwrap();
            }
            let mut protocols = BTreeMap::<String, usize>::new();
            for node in &result.nodes {
                let outbound: serde_json::Value = serde_json::from_str(&node.outbound_json).unwrap();
                *protocols.entry(outbound["type"].as_str().unwrap_or("unknown").into()).or_default() += 1;
            }
            println!("{}", serde_json::json!({"nodes":result.nodes.iter().filter(|n| serde_json::from_str::<serde_json::Value>(&n.outbound_json).is_ok_and(|v| v.get("server").is_some())).count(), "policies":result.nodes.iter().filter(|n| serde_json::from_str::<serde_json::Value>(&n.outbound_json).is_ok_and(|v| matches!(v["type"].as_str(), Some("selector" | "urltest")))).count(), "providers":result.providers.len(), "skipped":result.skipped.len(), "protocols":protocols}));
        }
        Err(_) => { eprintln!("No usable subscription content"); std::process::exit(1); }
    }
}
