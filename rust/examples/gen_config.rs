//! Dev helper: build a sing-box config with the middle layer and print it.
//! Usage: cargo run --example gen_config '<outbound-json>' [mixed_port]

use tokiboshi_rust::config::{build_config, CoreSettings};

fn main() {
    let outbound_json = std::env::args()
        .nth(1)
        .unwrap_or_else(|| r#"{"type":"direct"}"#.to_string());
    let mixed_port: u16 = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(7890);
    let outbound: serde_json::Value = serde_json::from_str(&outbound_json).expect("outbound JSON");
    let settings = CoreSettings { mixed_port, ..CoreSettings::default() };
    println!("{}", build_config(&outbound, &settings).expect("build config"));
}
