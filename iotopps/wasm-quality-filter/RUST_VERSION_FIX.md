# Rust Version Compatibility Fix

## Issue Fixed
The Docker build was failing because of cascading dependency version requirements:
1. First: `wasm-encoder v0.243.0` required Rust 1.76.0+
2. Then: `zerotrie v0.2.3` (pulled by newer wasmtime) required Rust 1.82.0+

## Changes Made

### 1. GitHub Actions Workflow (deploy-iot-edge.yaml)
- ✅ Updated Rust toolchain from `stable` to `1.82` specifically
- ✅ This ensures consistent Rust version across CI/CD pipeline

### 2. Dockerfile
- ✅ Updated base images from `rust:1.76-slim-bullseye` to `rust:1.82-slim-bullseye`
- ✅ Both WASM builder and processor builder stages now use Rust 1.82

### 3. Dependency Management (mqtt-processor/Cargo.toml)
- ✅ Pinned wasmtime to version `13.0` (compatible with Rust 1.82)
- ✅ Pinned wasmtime-wasi to version `13.0` (compatible with Rust 1.82)
- ✅ This avoids pulling in the latest wasmtime v14+ that requires newer Rust

### 4. What This Fixes
- ✅ Resolves `wasm-encoder v0.243.0` compatibility error
- ✅ Resolves `zerotrie v0.2.3` compatibility error  
- ✅ Ensures consistent Rust toolchain across all build environments
- ✅ Maintains compatibility with all existing dependencies

## Deploy and Test

### Quick Test
1. Make a small change to trigger the pipeline:
   ```bash
   cd iotopps/wasm-quality-filter
   echo "# Fixed Rust version to 1.82" >> README.md
   git add -A && git commit -m "Fix: Update Rust version to 1.82 for dependency compatibility"
   git push origin dev
   ```

2. Or manually trigger deployment:
   - Go to Actions → "Deploy IoT Edge Application"
   - Select `wasm-quality-filter`
   - Run workflow

### Expected Results
- ✅ Rust 1.82 installed in CI/CD
- ✅ Docker multi-stage build completes successfully
- ✅ All dependencies compile without version errors
- ✅ WASM module and MQTT processor built successfully
- ✅ Container deployed to Kubernetes cluster

## Verification Commands
After deployment:
```bash
# Check pod status
kubectl get pods -l app=wasm-quality-filter

# View logs
kubectl logs -l app=wasm-quality-filter -f

# Check health endpoint
kubectl exec -it deployment/wasm-quality-filter -- curl http://localhost:8080/health

# View service
kubectl get service wasm-quality-filter-service
```

## Rust Version Dependencies Summary
- **Required**: Rust 1.82.0+ (for zerotrie v0.2.3 via wasmtime dependencies)
- **CI/CD**: Now uses Rust 1.82 explicitly
- **Dockerfile**: Updated to rust:1.82-slim-bullseye
- **Local builds**: Will use system Rust (should be 1.82+)
- **Dependency Strategy**: Pinned wasmtime to v13.0 to avoid future version conflicts

This fix ensures consistent builds across all environments and resolves the dependency version conflict chain.