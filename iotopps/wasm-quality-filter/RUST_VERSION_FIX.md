# Rust Version Compatibility Fix

## Issue Fixed
The Docker build was failing because Rust 1.75.0 was too old for the `wasm-encoder v0.243.0` dependency, which requires Rust 1.76.0 or newer.

## Changes Made

### 1. GitHub Actions Workflow (deploy-iot-edge.yaml)
- ✅ Updated Rust toolchain from `stable` to `1.76` specifically
- ✅ This ensures consistent Rust version across CI/CD pipeline

### 2. Dockerfile
- ✅ Updated base images from `rust:1.75-slim-bullseye` to `rust:1.76-slim-bullseye`
- ✅ Both WASM builder and processor builder stages now use Rust 1.76

### 3. What This Fixes
- ✅ Resolves `wasm-encoder v0.243.0` compatibility error
- ✅ Ensures consistent Rust toolchain across all build environments
- ✅ Maintains compatibility with all existing dependencies

## Deploy and Test

### Quick Test
1. Make a small change to trigger the pipeline:
   ```bash
   cd iotopps/wasm-quality-filter
   echo "# Fixed Rust version" >> README.md
   git add -A && git commit -m "Fix: Update Rust version to 1.76 for wasm-encoder compatibility"
   git push origin dev
   ```

2. Or manually trigger deployment:
   - Go to Actions → "Deploy IoT Edge Application"
   - Select `wasm-quality-filter`
   - Run workflow

### Expected Results
- ✅ Rust 1.76 installed in CI/CD
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
- **Required**: Rust 1.76.0+ (for wasm-encoder v0.243.0)
- **CI/CD**: Now uses Rust 1.76 explicitly
- **Dockerfile**: Updated to rust:1.76-slim-bullseye
- **Local builds**: Will use system Rust (should be 1.76+)

This fix ensures consistent builds across all environments and resolves the dependency version conflict.