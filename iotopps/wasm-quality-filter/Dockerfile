FROM rust:1.76-slim-bullseye as wasm-builder

# Install build dependencies for WASM
RUN apt-get update && apt-get install -y \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build/wasm

# Copy WASM module source
COPY Cargo.toml .
COPY src/ src/

# Build the WASM module
RUN rustup target add wasm32-wasi && \
    cargo build --target wasm32-wasi --release

# Build stage for MQTT processor
FROM rust:1.76-slim-bullseye as processor-builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build/processor

# Copy MQTT processor source
COPY mqtt-processor/Cargo.toml .
COPY mqtt-processor/src/ src/

# Build the MQTT processor
RUN cargo build --release

# Production stage
FROM debian:bullseye-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl1.1 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install wasmtime for WASM execution
RUN curl -sSf https://wasmtime.dev/install.sh | bash
ENV PATH="/root/.wasmtime/bin:${PATH}"

# Create app directory
WORKDIR /app

# Copy WASM module from wasm builder
COPY --from=wasm-builder /build/wasm/target/wasm32-wasi/release/wasm_quality_filter.wasm ./

# Copy MQTT processor from processor builder
COPY --from=processor-builder /build/processor/target/release/mqtt-processor ./

# Copy configuration
COPY config.toml .

# Create non-root user for security
RUN groupadd -r wasmuser && useradd -r -g wasmuser wasmuser
RUN chown -R wasmuser:wasmuser /app
USER wasmuser

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1

EXPOSE 8080

CMD ["./mqtt-processor"]