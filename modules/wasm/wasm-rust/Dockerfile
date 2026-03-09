# Multi-stage build: compile Rust to wasm32-wasip2, output the .wasm binary.
#
# NOTE: The primary build path is Build-WasmModule.ps1 which builds locally
# and pushes the .wasm directly to ACR via ORAS (no Docker required).
# Use this Dockerfile only for CI pipelines or when a local Rust toolchain
# is not available.  The output binary /factory_transform_wasm.wasm must be
# pushed to ACR with oras push -- see Build-WasmModule.ps1 for the command.

# ── Stage 1: Compile ──────────────────────────────────────────────────────────
FROM rust:1.85-bookworm AS builder

# Add the AIO private Cargo registry so wasm_graph_sdk can be resolved
RUN mkdir -p /root/.cargo && \
    printf '[registries.azure-iot-sdks]\nindex = "sparse+https://pkgs.dev.azure.com/azure-iot-sdks/iot-operations/_packaging/preview/Cargo/index/"\n' \
    >> /root/.cargo/config.toml

WORKDIR /build

# Add the wasm32-wasip2 target (WebAssembly Component Model, required by AIO)
RUN rustup target add wasm32-wasip2

# Cache dependency compilation (rebuilt only when Cargo.toml changes)
COPY Cargo.toml .cargo ./
RUN mkdir -p src && \
    printf 'use wasm_graph_sdk::map_operator;\n#[map_operator]\nfn stub(i: wasm_graph_sdk::DataModel, _c: wasm_graph_sdk::ModuleConfiguration) -> wasm_graph_sdk::DataModel { i }\n' \
    > src/lib.rs && \
    cargo build --release --target wasm32-wasip2 --quiet 2>/dev/null || true && \
    rm -rf src

# Copy real source and run unit tests on the host target first
COPY src ./src
RUN cargo test --quiet

# Build the WebAssembly Component Model binary
RUN cargo build --release --target wasm32-wasip2 --quiet

# ── Stage 2: Minimal artifact image ──────────────────────────────────────────
# scratch: the image carries only the .wasm binary for extraction in CI.
FROM scratch

COPY --from=builder \
     /build/target/wasm32-wasip2/release/factory_transform_wasm.wasm \
     /factory_transform_wasm.wasm
