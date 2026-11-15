//! Prints counts only; never prints subscription URLs, node names or credentials.
use rust_lib_tokiboshi::links::parse_subscription;
use std::{collections::BTreeMap, io::Read};
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    match parse_subscription(&input) {
        Ok(result) => {
            let mut protocols = BTreeMap::<String, usize>::new();
            for node in &result.nodes {
                let outbound: serde_json::Value = serde_json::from_str(&node.outbound_json).unwrap();
                *protocols.entry(outbound["type"].as_str().unwrap_or("unknown").into()).or_default() += 1;
            }
            println!("{}", serde_json::json!({"nodes":result.nodes.len(), "providers":result.providers.len(), "skipped":result.skipped.len(), "protocols":protocols}));
        }
        Err(_) => { eprintln!("No usable subscription content"); std::process::exit(1); }
    }
}
