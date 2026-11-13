//! Tokiboshi Rust middle layer.
//!
//! Sits between the Flutter UI and the sing-box core:
//! - `config`: sing-box configuration model, validation and generation.
//! - `process`: sing-box core process lifecycle (start / stop / status).
//! - `api`: thin functions exposed toward Flutter (flutter_rust_bridge).

pub mod api;
pub mod config;
pub mod process;
