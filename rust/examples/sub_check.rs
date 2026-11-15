//! Dev helper: subscription file -> parse report + full client config.
//! Usage: cargo run --example sub_check <file> <tun:0|1> <out.json>
use rust_lib_tokiboshi::config::{build_config_multi, CoreSettings};
use rust_lib_tokiboshi::links::parse_subscription;
fn main() {
    let path = std::env::args().nth(1).expect("file");
    let tun = std::env::args().nth(2).map(|s| s == "1").unwrap_or(false);
    let out = std::env::args().nth(3).expect("out");
    let text = std::fs::read_to_string(&path).expect("read sub file");
    let outcome = parse_subscription(&text).expect("parse subscription");
    eprintln!("nodes: {}", outcome.nodes.len());
    eprintln!("providers: {}", outcome.providers.len());
    for p in &outcome.providers {
        eprintln!("  provider: {} ua={:?} exclude={}", p.name, p.user_agent, p.exclude_filter.is_some());
    }
    eprintln!("skipped: {}", outcome.skipped.len());
    for s in &outcome.skipped {
        eprintln!("  skip: {s}");
    }
    // Select the node whose server is the user's Tokyo hy2 box, if present.
    let selected = outcome.nodes.iter().find(|n| n.outbound_json.contains("14.137.255.154")).map(|n| n.name.clone());
    eprintln!("selected: {:?}", selected);
    let data_dir = std::env::args().nth(4).unwrap_or_default();
    let settings = CoreSettings { enable_tun: tun, data_dir, ..CoreSettings::default() };
    let specs: Vec<rust_lib_tokiboshi::config::NodeSpec> = outcome.nodes.iter().map(|n| rust_lib_tokiboshi::config::NodeSpec { name: n.name.clone(), outbound_json: n.outbound_json.clone() }).collect();
    let cfg = build_config_multi(&specs, &settings, selected.as_deref(), None).expect("build config");
    std::fs::write(&out, cfg).expect("write config");
    eprintln!("config written: {out}");
}
