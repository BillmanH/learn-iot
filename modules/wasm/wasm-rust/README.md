# WASM Data Transform Module

A [Rust](https://www.rust-lang.org/) + [WASI](https://wasi.dev/) module that runs as an
**AIO Data Processor pipeline stage**.  
It enriches the raw JSON telemetry produced by `edgemqttsim` with OEE scores,
alert classifications, and normalised quality fields before the data is re-published
on the `factory/transformed/#` topic tree.

---

## What it does

| Input field | Transformation |
|---|---|
| `status` | Computes `oee_availability` (1.0 = running, 0.5 = planned downtime, 0.0 = faulted) |
| `good` / `scrap` / `rework` / `quality` | Computes `oee_quality` ratio and adds `quality_normalised` string |
| `test_result` | Adds `test_passed` boolean |
| `status` + quality + test result | Derives `alert_level` (`normal` / `warning` / `critical`) with `alert_reason` |
| All messages | Adds `processing_module_version` for audit trail |

### Example - CNC scrap part

```jsonc
// Input (from edgemqttsim)
{
  "timestamp": "2026-03-05T10:00:00Z",
  "machine_id": "CNC-01",
  "station_id": "LINE-1-STATION-A",
  "status": "running",
  "good": 0,
  "scrap": 1,
  "cycle_time": 14.0,
  "part_type": "HullPanel",
  "part_id": "HullPanel-042"
}

// Output (after WASM transform, factory/transformed/cnc)
{
  "timestamp": "2026-03-05T10:00:00Z",
  "machine_id": "CNC-01",
  "station_id": "LINE-1-STATION-A",
  "status": "running",
  "good": 0,
  "scrap": 1,
  "cycle_time": 14.0,
  "part_type": "HullPanel",
  "part_id": "HullPanel-042",
  "oee_availability": 1.0,
  "oee_quality": 0.0,
  "quality_normalised": "scrap",
  "alert_level": "warning",
  "alert_reason": "scrap part produced",
  "processing_module_version": "0.1.0"
}
```

---

## Architecture

```
MQTT broker (factory/#)
        |
   AIO Data Processor
        |
   [WASM stage]  ← factory-transform.wasm  (this module)
        |
   [jq re-topic stage]
        |
MQTT broker (factory/transformed/#)
```

---

## Project layout

```
modules/wasm-rust/
  Cargo.toml             Rust package manifest
  Dockerfile             Multi-stage ACR build  (Rust compiler -> WASM binary -> Alpine image)
  src/
    main.rs              WASI entry point  (stdin -> process -> stdout)
    transform.rs         OEE enrichment + alert classification logic
  Build-WasmModule.ps1   Windows build script  (az acr build, no cluster connection needed)
```

---

## Workflow

```
1. Windows dev machine
   cd modules\wasm
   .\Build-WasmModule.ps1
          |
          v
   az acr build  (Rust compiled inside Azure, no local tooling needed)
          |
          v
   testaioacr.azurecr.io/factory-transform-wasm:latest

2. AIO portal  (no kubectl, no SSH to edge)
   IoT Operations instance
     -> Dataflows (or Data Processor depending on AIO version)
     -> Create / edit a dataflow graph
     -> Add a Transform stage -> WASM
     -> Module image: testaioacr.azurecr.io/factory-transform-wasm:latest
     -> Entrypoint: _start  |  Input path: .payload
     -> Save  (Arc pushes config to edge automatically)
```

---

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| Azure CLI | `az acr build` | `winget install Microsoft.AzureCLI` |

No local Rust, Docker, kubectl, or cluster access needed.
The registry name is read automatically from `config/aio_config.json`
(`azure.container_registry`) unless overridden with `-RegistryName`.

---

## Build

```powershell
cd modules\wasm

# Registry name read automatically from config/aio_config.json
.\Build-WasmModule.ps1

# Override registry or tag if needed
.\Build-WasmModule.ps1 -RegistryName myacr -Tag v1.0.0
```

This pushes `testaioacr.azurecr.io/factory-transform-wasm:latest` to ACR.
That is the image URL you reference in the portal when configuring the WASM stage.



---

## Unit tests

The module has a comprehensive test suite. These require a local Rust toolchain but are
also run automatically during the ACR multi-stage build (`cargo test` runs in the builder stage).

To run locally if you have Rust installed:
```bash
cargo test
```

Tests cover: good parts, scrap, rework, faulted machines, test rigs pass/fail,
in-progress quality, business events (orders/dispatch), and malformed input.

---

## Extending

All enrichment logic lives in [src/transform.rs](src/transform.rs).

To add a new derived field:
1. Add the field to `TransformedMessage` (with `#[serde(skip_serializing_if = "Option::is_none")]`)
2. Compute it in `enrich()` and assign it
3. Add unit tests in the `#[cfg(test)]` block
4. Bump the version in `Cargo.toml`
5. Re-run `.\Build-WasmModule.ps1` — update the image tag in the portal stage to pick up the new binary

---

## Alert levels

| Level | Triggers |
|---|---|
| `critical` | `status == "faulted"`, test result `fail` |
| `warning` | `quality == "scrap"`, `quality == "rework"`, machine in maintenance |
| `normal` | Everything else (including in-progress and idle) |
