//! API surface exposed to Flutter via flutter_rust_bridge.
//!
//! Code generation (`flutter_rust_bridge_codegen generate`) turns the
//! functions in this module into the Dart bindings under
//! `lib/src/rust/`. Until generation runs in a dev environment, the
//! Flutter side talks to this layer through the `CoreBridge` interface
//! in `lib/bridge/core_bridge.dart`.

pub mod core;
