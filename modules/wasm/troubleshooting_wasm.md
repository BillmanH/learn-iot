# WASM DataflowGraph Module - Setup Guide

Last updated: 2026-03-05. End-to-end validated. Both graphs visible in AIO portal Dataflows -> Graphs.

Official reference: https://learn.microsoft.com/azure/iot-operations/develop-edge-apps/howto-develop-wasm-modules

---

## Deployment Checklist

Everything required for a WASM module to appear and run in AIO. All items are complete for this project.

---

### Rust Module (wasm-rust)

#### Source Code

- [x] `src/lib.rs` uses `#[map_operator(init = "...")]` macro as the entry point
- [x] `src/lib.rs` only imports `wasm_graph_sdk::macros::map_operator` and `wasm_graph_sdk::logger`
- [x] `src/lib.rs` does NOT import `DataModel`, `ModuleConfiguration`, `Error`, or `BufferOrBytes` -- these are injected by the macro
- [x] `Cargo.toml` sets `crate-type = ["cdylib"]` in `[lib]`
- [x] `Cargo.toml` sets `autobins = false` in `[package]` -- without this, Cargo detects `src/main.rs` and fails
- [x] `Cargo.toml` references `wasm_graph_sdk` from the private AIO registry: `{ version = "=1.1.3", registry = "azure-iot-sdks" }`
- [x] `.cargo/config.toml` defines the `azure-iot-sdks` registry pointing to `pkgs.dev.azure.com`
- [x] `.cargo/config.toml` sets `[build] target = "wasm32-wasip2"` as the default target

#### Build

- [x] Build target is `wasm32-wasip2` (Component Model) -- NOT `wasm32-wasip1` or `wasm32-unknown-unknown`
- [x] ACR Tasks `acr-task.yaml` uses `rust:1.85` or later -- `rust:1.84` fails due to `edition2024` requirement in `spdx` crate
- [x] ACR Tasks build step writes the private registry config into `/root/.cargo/config.toml` before `cargo build`
- [x] ORAS push steps use `--disable-path-validation` when pushing absolute paths inside ACR Tasks

#### ACR Artifacts

- [x] WASM binary pushed as OCI artifact with artifact-type `application/vnd.module.wasm.content.layer.v1+wasm`
  - Tag: `testaioacr.azurecr.io/factory-transform-wasm:latest`
- [x] Graph YAML pushed as separate OCI artifact with artifact-type `application/vnd.microsoft.aio.graph.v1+yaml`
  - Tag: `testaioacr.azurecr.io/factory-transform-graph:latest`
- [x] Both artifacts use `oras push`, not `az acr build` or `docker push`

---

### Python Module (wasm-python)

#### Source Code

- [x] `oee_enrich.py` defines a `Map` class extending `exports.Map` with `init()` and `process()` methods
- [x] `init()` returns `bool` -- return `True` to proceed, `False` to signal a configuration error
- [x] `process()` takes and returns `types.DataModel` -- check `isinstance(message, types.DataModel_Message)` before accessing payload
- [x] Imports come from `map_impl` (generated bindings) -- do NOT hand-write these; they are produced by `componentize-py bindings`
- [x] All WIT schema `.wit` files must be present in the schema directory -- they reference each other and cannot be used individually

#### Build

- [x] Build tool is `componentize-py==0.14` -- not `cargo`; no private registry or PAT required
- [x] ACR Tasks `acr-task.yaml` uses `ghcr.io/azure-samples/explore-iot-operations/python-wasm-builder` -- no Rust toolchain needed
- [x] Builder is invoked with `--app-name oee_enrich --app-type map` -- `--app-name` must match the Python filename without `.py`
- [x] Output WASM file is `oee_enrich.wasm` in the working directory (not under `target/`)
- [x] ORAS push steps use `--disable-path-validation` when pushing absolute paths inside ACR Tasks

#### ACR Artifacts

- [x] WASM binary pushed as OCI artifact with artifact-type `application/vnd.module.wasm.content.layer.v1+wasm`
  - Tag: `testaioacr.azurecr.io/factory-transform-wasm-py:latest`
- [x] Graph YAML pushed as separate OCI artifact with artifact-type `application/vnd.microsoft.aio.graph.v1+yaml`
  - Tag: `testaioacr.azurecr.io/factory-transform-graph-py:latest`
- [x] Both artifacts use `oras push`, not `az acr build` or `docker push`

---

### Shared (both modules)

#### graph.yaml Structure

- [x] Top-level keys follow official schema: `$schema`, `name`, `version`, `moduleRequirements`, `moduleConfigurations`, `operations`, `connections`
- [x] `moduleRequirements` references the WASM artifact tag in ACR
- [x] `operations` defines at least one operation with the module name and configuration key
- [x] `connections` wires source topic(s) to the operation and operation output to destination topic(s)

#### Azure Permissions

- [x] `AcrPull` role assigned to the Arc k8s-extension managed identity, NOT the AIO instance identity
  - Find with: `az k8s-extension list --cluster-name cluster-test-vm --resource-group rg-test-vm --cluster-type connectedClusters`
  - NOTE: `az iot ops show` identity is `None` -- that is not the right target
  - Current extension: `azure-iot-operations-ammx4`, principal: `1a94662e-c96b-40dc-b0af-6feeb084b051`
- [x] AcrPull scope is the ACR resource ID (not subscription-wide)

#### AIO Registry Endpoint

- [x] At least one registry endpoint exists in AIO for `testaioacr.azurecr.io` -- check before creating a new one:
  - `az iot ops registry list --resource-group rg-test-vm --instance cluster-test-vm-aio -o table`
- [x] The existing `testaioacr` endpoint (created during initial AIO deployment) works fine -- no need to create a second one
- [x] If an endpoint does not exist: `az iot ops registry create -n testaioacr --host testaioacr.azurecr.io -i cluster-test-vm-aio -g rg-test-vm`
- [x] Endpoint `provisioningState` is `Succeeded`
- [x] `dataflow-graph.yaml` `registryEndpointRef` matches the actual endpoint name in AIO

#### Kubernetes / AIO DataflowGraph

- [x] `dataflow-graph.yaml` `registryEndpointRef` matches an actual endpoint name in AIO (currently `testaioacr`)
- [x] `dataflow-graph.yaml` references the correct graph artifact tag (`factory-transform-graph:latest` for Rust, `factory-transform-graph-py:latest` for Python)
- [x] Deployed via AIO portal (Dataflows -> Graphs -> deploy) -- or `kubectl apply -f <module>/dataflow-graph.yaml` as an alternative

---

## How It Works

```
cargo build --target wasm32-wasip2  ->  .wasm binary
      |
      v
oras push -> ACR as OCI artifact (NOT a Docker image)
      |
      v
graph.yaml pushed separately via oras push -> ACR
      |
      v
check: az iot ops registry list -> verify endpoint exists for ACR (create one if not)
      |
      v
AIO Portal: Dataflows -> Graphs -> graph artifact is visible
      |
      v
Arc pushes DataflowGraph CRD to cluster automatically
      |
      v
AIO operator on cluster pulls .wasm from ACR via registry endpoint
and executes per-message WASM transform in the dataflow pipeline
```

No SSH required. No manual steps on the edge device.

---

## Source File Details

### `src/lib.rs`

```rust
use wasm_graph_sdk::macros::map_operator;
use wasm_graph_sdk::logger::{self, Level};

mod transform;

#[map_operator(init = "oee_enrich_init")]
fn oee_enrich(msg: &mut DataModel, _config: &ModuleConfiguration) -> Result<(), Error> {
    let payload_bytes = msg.payload.read();
    match transform::enrich_bytes(&payload_bytes) {
        Ok(enriched) => {
            msg.payload.write(BufferOrBytes::Bytes(enriched));
            Ok(())
        }
        Err(e) => {
            logger::log(Level::Error, &format!("OEE enrich failed: {e}"));
            Ok(()) // pass through unchanged on error
        }
    }
}

fn oee_enrich_init(_config: &ModuleConfiguration) -> Result<(), Error> {
    logger::log(Level::Info, "OEE enrich module initialized");
    Ok(())
}
```

`DataModel`, `ModuleConfiguration`, `Error`, and `BufferOrBytes` are injected by the `#[map_operator]`
macro. Do NOT add `use` statements for them -- that causes `E0432` compile errors.

### `Cargo.toml` (critical fields)

```toml
[package]
name = "factory_transform_wasm"
version = "0.1.0"
edition = "2021"
autobins = false        # required -- prevents auto-detection of src/main.rs as a binary

[lib]
crate-type = ["cdylib"] # required -- WASM component needs a dynamic lib

[dependencies]
wasm_graph_sdk = { version = "=1.1.3", registry = "azure-iot-sdks" }
# Note: =1.1.3 resolves to 1.1.4 (1.1.3 was yanked -- APIs are identical)
```

### `.cargo/config.toml`

```toml
[registries.azure-iot-sdks]
index = "sparse+https://pkgs.dev.azure.com/azure-iot-sdks/iot-operations/_packaging/preview/Cargo/index/"

[build]
target = "wasm32-wasip2"
```

---

## Build via ACR Tasks

ACR Tasks runs the Rust build in the cloud -- no local MSVC linker or Docker required.

```powershell
# From modules/wasm/wasm-rust/ directory
az acr run --registry testaioacr --file acr-task.yaml .
```

Full pipeline is in `modules/wasm/wasm-rust/acr-task.yaml`. Key points:

- Uses `rust:1.85` minimum (`rust:1.84` fails)
- Uses `oras:v1.2.2` for push steps
- All ORAS push steps include `--disable-path-validation` (required for absolute paths in ACR Tasks)
- `$Registry` is automatically set to `testaioacr.azurecr.io` by ACR Tasks

---

## Verify Artifacts

```powershell
az acr login --name testaioacr

oras manifest fetch testaioacr.azurecr.io/factory-transform-wasm:latest
# Must show: "artifactType": "application/vnd.module.wasm.content.layer.v1+wasm"

oras manifest fetch testaioacr.azurecr.io/factory-transform-graph:latest
# Must show: "artifactType": "application/vnd.microsoft.aio.graph.v1+yaml"
```

---

## Re-pushing graph.yaml Only (Windows)

If you only need to update the graph definition without a full ACR Task rebuild:

```powershell
az acr login --name testaioacr

# Windows has no /dev/null -- use a temp empty config file
'{}' | Set-Content "$ENV:TEMP\oras-cfg.json"

oras push testaioacr.azurecr.io/factory-transform-graph:latest `
    --config "${ENV:TEMP}\oras-cfg.json:application/vnd.microsoft.aio.graph.v1+yaml" `
    .\graph.yaml:application/vnd.microsoft.aio.graph.v1+yaml

Remove-Item "$ENV:TEMP\oras-cfg.json"
```

---

## Re-granting AcrPull

```powershell
# Find the Arc extension managed identity -- az iot ops show returns None, use this instead
az k8s-extension list `
    --cluster-name cluster-test-vm `
    --resource-group rg-test-vm `
    --cluster-type connectedClusters `
    --query "[?contains(name,'iotoperations')].{name:name, principal:identity.principalId}" `
    -o table

# Assign AcrPull
$acrId = az acr show --name testaioacr --query id -o tsv
az role assignment create --assignee <principalId> --role AcrPull --scope $acrId
```

Or run `.\external_configuration\grant_entra_id_roles.ps1` which handles this automatically.

---

## Key Lessons

| Problem | Root Cause | Fix |
|---|---|---|
| `unresolved import wasm_graph_sdk::map_operator` | Not at crate root -- it is macro-injected | Use `wasm_graph_sdk::macros::map_operator` |
| `E0432` on DataModel etc. | Types are macro-injected, not importable | Remove those `use` statements |
| `expected item after doc comment` on main.rs | Cargo auto-detects `src/main.rs` as a binary target | Add `autobins = false` to `[package]` |
| ACR Task fails with `edition2024 is not stable` | `rust:1.84` too old | Use `rust:1.85` |
| ORAS push fails on absolute path in ACR Task | ORAS rejects absolute paths by default | Add `--disable-path-validation` |
| `/dev/null` fails on Windows | No `/dev/null` on Windows | Use a temp empty JSON file |
| AcrPull grant has no effect | Wrong identity -- `az iot ops show` returns None | Use `az k8s-extension list` to find real principal |
| Portal shows no graphs after push | No registry endpoint exists for the ACR in AIO | Check with `az iot ops registry list`, create one if missing |

---

## Diagnostics

```powershell
# Confirm artifact types in ACR
oras manifest fetch testaioacr.azurecr.io/factory-transform-wasm:latest
oras manifest fetch testaioacr.azurecr.io/factory-transform-graph:latest

# List registry endpoints
az iot ops registry list --resource-group rg-test-vm --instance cluster-test-vm-aio -o table

# Check AcrPull assignment
$acrId = az acr show --name testaioacr --query id -o tsv
az role assignment list --scope $acrId --query "[].{principal:principalName, role:roleDefinitionName}" -o table

# Check DataflowGraph CRD on cluster
kubectl get dataflowgraphs -n azure-iot-operations

# AIO operator logs
kubectl logs -n azure-iot-operations -l app.kubernetes.io/component=aio-operator --tail=80
```

---

## Repository Files

| File | Purpose |
|---|---|
| `modules/wasm/wasm-rust/src/lib.rs` | WASM entry point -- `#[map_operator]` |
| `modules/wasm/wasm-rust/src/transform.rs` | OEE enrichment logic |
| `modules/wasm/wasm-rust/Cargo.toml` | `autobins = false`, `cdylib`, `wasm_graph_sdk` |
| `modules/wasm/wasm-rust/.cargo/config.toml` | Private registry + default target |
| `modules/wasm/wasm-rust/graph.yaml` | Graph definition OCI artifact source |
| `modules/wasm/wasm-rust/acr-task.yaml` | ACR Tasks build + push pipeline |
| `modules/wasm/wasm-rust/dataflow-graph.yaml` | K8s DataflowGraph CRD manifest |
| `modules/wasm/wasm-python/oee_enrich.py` | Python WASM map operator |
| `modules/wasm/wasm-python/graph.yaml` | Python graph definition OCI artifact source |
| `modules/wasm/wasm-python/acr-task.yaml` | Python ACR Tasks build + push pipeline |
| `modules/wasm/wasm-python/dataflow-graph.yaml` | Python K8s DataflowGraph CRD manifest |
| `external_configuration/grant_entra_id_roles.ps1` | Grants AcrPull to Arc extension identity |

---

## References

- https://github.com/Azure-Samples/azure-edge-extensions-aio-dataflow-graphs
- https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-develop-wasm-modules
- https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-dataflow-graph-wasm
- https://oras.land/
- troubleshooting_aio.md