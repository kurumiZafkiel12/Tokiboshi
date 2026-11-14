//! Tokiboshi Rust middle layer.
//!
//! Sits between the Flutter UI and the sing-box core:
//! - `config`: sing-box configuration model, validation and generation.
//! - `links`: share link / subscription parsing into sing-box outbounds.
//! - `process`: sing-box core process lifecycle (start / stop / status).
//! - `api`: functions exposed to Flutter via flutter_rust_bridge.

pub mod api;
pub mod config;
pub mod core_download;
pub mod links;
pub mod process;
mod frb_generated;
