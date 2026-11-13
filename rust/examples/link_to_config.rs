//! Dev helper: share link -> sing-box client config via the middle layer.
//! Usage: cargo run --example link_to_config '<link>' <mixed_port>
use rust_lib_tokiboshi::config::{build_config, CoreSettings};
use rust_lib_tokiboshi::links::parse_share_link;
fn main() {
    let link = std::env::args().nth(1).expect("link");
    let port: u16 = std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(7890);
    let node = parse_share_link(&link).expect("parse link");
    let outbound: serde_json::Value = serde_json::from_str(&node.outbound_json).expect("outbound json");
    let settings = CoreSettings { mixed_port: port, ..CoreSettings::default() };
    println!("{}", build_config(&outbound, &settings).expect("build config"));
}
