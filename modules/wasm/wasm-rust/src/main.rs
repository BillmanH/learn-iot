/// DEPRECATED -- superseded by src/lib.rs
///
/// This file was the original WASI preview 1 (wasm32-wasip1) stdin/stdout
/// entry point written for the AIO Data Processor pipeline stage.
/// AIO Data Processor has been replaced by AIO DataflowGraphs which require:
///   - Target:  wasm32-wasip2 (WebAssembly Component Model)
///   - SDK:     wasm_graph_sdk with #[map_operator] / #[filter_operator]
///   - Entry:   src/lib.rs (crate-type = ["cdylib"])
///
/// This file is kept for reference only and is no longer compiled
/// (the [[bin]] section has been removed from Cargo.toml).
///
/// See: src/lib.rs  -- current entry point
///      ../graph.yaml -- DataflowGraph definition
///      ../Build-WasmModule.ps1 -- build + ORAS push workflow
///      https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-develop-wasm-modules

// mod transform;
// use std::io::{self, Read, Write};
// fn main() {
//     let mut input = String::new();
//     io::stdin().read_to_string(&mut input).expect("failed to read stdin");
//     let output = transform::process(&input);
//     io::stdout().write_all(output.as_bytes()).expect("failed to write stdout");
// }

