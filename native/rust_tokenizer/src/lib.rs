//! Rust tokenizer bridge for the note embedding stack (spec D17).
//!
//! The Dart side never links this crate directly; `flutter_rust_bridge_codegen`
//! reads `src/api.rs` and emits bindings under `lib/bridge/`. See
//! `flutter_rust_bridge.yaml` at the repository root.
//!
//! The tokenizer is a process-global so it is initialised once and shared across
//! the app's isolates. The ONNX session is not shared the same way and lives on
//! the Dart side.

mod api;
