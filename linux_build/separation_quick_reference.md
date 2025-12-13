# Separation of Concerns - Quick Reference

## What Changed

### Before (Current State)
```
linuxAIO.sh (1 monolithic script, ~1340 lines)
├── Runs ON edge device
├── Requires Azure credentials on edge
├── Does EVERYTHING: local install + Azure config
└── Hard to manage multiple edge devices
```

### After (Proposed Architecture)
```
linux_installer.sh (~500 lines)              external_configurator.sh (~500 lines)
├── Runs ON edge device                      ├── Runs FROM any machine
├── NO Azure credentials needed              ├── Requires Azure credentials
├── Local infrastructure ONLY                ├── Cloud resources ONLY
├── Outputs: cluster_info.json               ├── Inputs: cluster_info.json
└── Fast, secure, repeatable                 └── Manages multiple clusters
```

---

## Function Separation Summary

### Local Functions (linux_installer.sh)
| Function | Purpose | Dependencies |
|----------|---------|--------------|
| check_root | Verify non-root user | None |
| check_system_requirements | CPU, RAM, kernel validation | /proc/meminfo |
| check_port_conflicts | Port 6443, 10250 availability | ss/lsof |
| update_system | Update Ubuntu packages | apt |
| install_kubectl | Install kubectl binary | Internet |
| install_helm | Install Helm | Internet |
| install_optional_tools | Install k9s, mqtt-viewer, mqttui | Internet, optional_tools config |
| check_kubelite_conflicts | MicroK8s detection | pgrep |
| cleanup_k3s | Remove old K3s | systemctl |
| install_k3s | Install K3s cluster | curl, systemctl |
| configure_kubectl | Setup kubeconfig | K3s |
| configure_system_settings | sysctl parameters | sysctl |
| deploy_modules | Deploy selected edge apps | kubectl, modules config |
| verify_local_cluster | K3s health check | kubectl |
| generate_cluster_info | Export metadata | kubectl, jq |

### Remote Functions (external_configurator.sh)
| Function | Purpose | Dependencies |
|----------|---------|--------------|
| check_prerequisites | Azure CLI, cluster_info | az |
| azure_login_setup | Azure auth | az login |
| create_azure_resources | Create RG, storage | az group |
| arc_enable_cluster | Connect to Arc | az connectedk8s |
| verify_arc_connectivity | Test Arc connection | az connectedk8s |
| create_namespace | Device Registry namespace | az deviceregistry |
| create_schema_registry | Schema storage | az storage |
| deploy_iot_operations | Deploy AIO | az iot ops |
| enable_asset_sync | Enable rsync | az iot ops |
| deploy_assets_to_azure | ARM templates | az deployment |
| verify_deployment | E2E verification | az iot ops check |

---

## Configuration Files

### edge_config.json (for linux_installer.sh)
```json
{
  "edge_device": {
    "cluster_name": "edge-001",
    "skip_system_update": false
  },
  "k3s": {
    "disable_traefik": true
  },
  "optional_tools": {
    "k9s": true,
    "mqtt-viewer": false,
    "mqttui": false
  },
  "modules": {
    "edgemqttsim": true,
    "hello-flask": false,
    "sputnik": false,
    "wasm-quality-filter-python": false
  }
}
```

**Optional Tools**:
- **k9s** - Terminal-based Kubernetes UI (recommended for development/debugging)
- **mqtt-viewer** - Command-line MQTT message viewer (useful for telemetry debugging)
- **mqttui** - Terminal UI for MQTT with interactive topic browsing (advanced MQTT debugging)

**Available Modules**:
- **edgemqttsim** - Factory telemetry simulator with MQTT publishing
- **hello-flask** - Sample Flask web application for testing
- **sputnik** - Custom IoT processing application
- **wasm-quality-filter-python** - WebAssembly-based data filter

Set to `true` to deploy, `false` to skip.

### azure_config.json (for external_configurator.sh)
```json
{
  "azure": {
    "subscription_id": "xxx",
    "resource_group": "rg-iot",
    "location": "eastus",
    "cluster_name": "edge-001",
    "namespace_name": "factory"
  },
  "deployment": {
    "deployment_mode": "production",
    "deploy_mqtt_assets": true
  }
}
```

### cluster_info.json (output from linux_installer.sh)
```json
{
  "cluster_name": "edge-001",
  "kube_config": "<base64 kubeconfig>",
  "node_info": {
    "cpu": 4,
    "memory_gb": 16,
    "k3s_version": "v1.28.5"
  },
  "deployed_modules": ["edgemqttsim"],
  "installed_tools": ["k9s"],
  "timestamp": "2025-12-12T10:30:00Z",
  "ready_for_arc": true
}
```

---

## Use Cases

### Use Case 1: Developer Local Testing
**Scenario**: Developer testing on single machine

```bash
# Terminal 1: Edge setup with custom modules
cd linux_build
# Edit edge_config.json to enable desired modules
bash linux_installer.sh

# Terminal 2: Azure config (same machine)
bash external_configurator.sh --cluster-info ./cluster_info.json
```

### Use Case 2: Production Deployment
**Scenario**: Factory edge device + remote IT management

```bash
# On factory floor (edge device)
ssh edge-device-001
cd linux_build

# Configure which modules to deploy
cat > edge_config.json <<EOF
{
  "edge_device": {"cluster_name": "edge-001"},
  "modules": {
    "edgemqttsim": true,
    "wasm-quality-filter-python": true
  }
}
EOF

bash linux_installer.sh
# Outputs: cluster_info.json

# Transfer to IT workstation
scp edge-device-001:~/linux_build/cluster_info.json ./

# On IT workstation
cd linux_build
bash external_configurator.sh --cluster-info ./cluster_info.json
```

### Use Case 3: Multi-Cluster Management
**Scenario**: 10 edge devices, 1 management machine, different module configurations

```bash
# On edge device 1 (telemetry only)
cat > edge_config.json <<EOF
{
  "modules": {"edgemqttsim": true}
}
EOF
bash linux_installer.sh

# On edge device 2 (processing + telemetry)
cat > edge_config.json <<EOF
{
  "modules": {
    "edgemqttsim": true,
    "wasm-quality-filter-python": true
  }
}
EOF
bash linux_installer.sh

# On management machine - configure all clusters
for cluster in edge-{001..010}; do
  bash external_configurator.sh \
    --cluster-info "${cluster}_cluster_info.json" \
    --config "azure_config_${cluster}.json"
done
```

### Use Case 4: CI/CD Pipeline with Module Selection
**Scenario**: Automated deployment with environment-specific modules

```yaml
# .github/workflows/deploy-edge.yml
jobs:
  edge-setup:
    runs-on: self-hosted-edge-runner
    steps:
      - name: Configure modules for environment
        run: |
          if [ "${{ env.ENVIRONMENT }}" == "production" ]; then
            jq '.modules.edgemqttsim = true | .modules."wasm-quality-filter-python" = true' \
              edge_config.template.json > edge_config.json
          else
            jq '.modules.edgemqttsim = true | .modules."hello-flask" = true' \
              edge_config.template.json > edge_config.json
          fi
      - run: bash linux_installer.sh
      - upload: cluster_info.json

  azure-config:
    runs-on: ubuntu-latest
    needs: edge-setup
    steps:
      - download: cluster_info.json
      - run: bash external_configurator.sh
```

---

## Timeline Visualization

```
Week 1: Planning & Preparation
├── Create config schemas (including modules section) ✅
├── Set up test environments
└── Stakeholder approval

Week 2-3: Core Development
├── Week 2: linux_installer.sh
│   ├── Day 1-2: Base structure
│   ├── Day 3-4: Local functions + deploy_modules()
│   └── Day 5: Testing with different module combinations
└── Week 3: external_configurator.sh
    ├── Day 1-2: Base structure
    ├── Day 3-4: Remote functions
    └── Day 5: Testing

Week 4: Integration Testing
├── E2E scenarios with various module configs
├── Performance benchmarking
└── Troubleshooting guides

Week 5: Supporting Scripts
├── Update existing scripts
├── Create helper utilities
└── Integration validation

Week 6: Documentation
├── Update readme.md ✅ COMPLETE
├── Create new guides
└── Video tutorials

Week 7: Migration
├── Migration guide
├── Deprecation notices
└── Community communication

Week 8: Production Validation
├── Beta testing
├── Security review
└── Final release
```

---

## Key Benefits Comparison

| Aspect | Current (linuxAIO.sh) | New Architecture |
|--------|----------------------|------------------|
| **Security** | ⚠️ Azure creds on edge | ✅ No edge creds |
| **Multi-cluster** | ❌ Must run on each | ✅ Central management |
| **Module flexibility** | ⚠️ All or nothing | ✅ Granular control |
| **Debugging** | 🤔 Mixed concerns | ✅ Clear separation |
| **CI/CD** | ⚠️ Difficult | ✅ Pipeline-friendly |
| **Rollback** | ❌ Manual cleanup | ✅ Independent phases |
| **Testing** | ⚠️ E2E only | ✅ Unit + integration |
| **Documentation** | 📖 1 guide | 📚 Focused guides |

---

## Module Deployment Examples

### Minimal Setup (Telemetry Only)
```json
{
  "modules": {
    "edgemqttsim": true
  }
}
```
**Use Case**: Basic telemetry collection, testing MQTT connectivity

### Full Development Setup
```json
{
  "modules": {
    "edgemqttsim": true,
    "hello-flask": true,
    "sputnik": true,
    "wasm-quality-filter-python": true
  }
}
```
**Use Case**: Developer workstation with all modules for testing

### Production Edge Processing
```json
{
  "modules": {
    "edgemqttsim": true,
    "wasm-quality-filter-python": true
  }
}
```
**Use Case**: Factory floor with telemetry + local data filtering

### Testing Only (No Telemetry)
```json
{
  "modules": {
    "hello-flask": true
  }
}
```
**Use Case**: Validate K3s deployment without industrial applications

---

## Next Actions

### Immediate (This Week)
- [ ] Review separation_of_concerns.md with team
- [ ] Get stakeholder approval on modular architecture
- [ ] Create GitHub project board
- [ ] Set up test Ubuntu VM

### Short Term (Next 2 Weeks)
- [ ] Start Phase 1: Planning tasks
- [ ] Create config schema files with modules section
- [ ] Write test plan document covering all module combinations
- [ ] Begin linux_installer.sh development with deploy_modules()

### Medium Term (4-6 Weeks)
- [ ] Complete both scripts with module support
- [ ] Run integration tests with various module configurations
- [ ] Update all documentation
- [ ] Begin beta testing

---

## Questions & Answers

**Q: Will linuxAIO.sh still work?**  
A: Yes, during transition period (6+ months). Eventually deprecated.

**Q: Can I deploy custom modules not in the list?**  
A: Yes! The modules section is extensible. Add custom module names and implement deployment logic in deploy_modules().

**Q: What if I don't specify modules section?**  
A: Default behavior: deploy edgemqttsim only (backward compatible).

**Q: Can I add modules after initial deployment?**  
A: Yes! Edit edge_config.json, set new modules to true, and re-run linux_installer.sh (idempotent).

**Q: Do I need two machines?**  
A: No, both scripts can run on same machine. Separation is logical, not physical.

**Q: What about existing deployments?**  
A: No migration required. Continue using linuxAIO.sh or start fresh with new scripts.

**Q: When will new scripts be ready?**  
A: Target: 8 weeks from approval. Beta: Week 7, GA: Week 8.

**Q: Can I use in production today?**  
A: No, new scripts are in development. Use linuxAIO.sh for production.

**Q: How do modules affect deployment time?**  
A: Each module adds ~30-60 seconds. Deploy only what you need for faster installations.

---

## Files Created/Updated

### New Files
- ✅ `linux_build/separation_of_concerns.md` - Complete implementation plan
- ✅ `linux_build/separation_quick_reference.md` - This file
- 🚧 `linux_build/linux_installer.sh` - Edge installer (in development)
- 🚧 `linux_build/external_configurator.sh` - Azure configurator (in development)
- 🚧 `linux_build/edge_config.template.json` - Edge config with modules section
- 🚧 `linux_build/azure_config.template.json` - Azure config template

### Updated Files
- ✅ `readme.md` - Added new architecture section and notices
- 🚧 `linux_build/linux_build_steps.md` - Will update in Phase 6
- 🚧 `linux_build/deploy-assets.sh` - Will update in Phase 4

### Existing Files (No Changes)
- `linux_build/linuxAIO.sh` - Remains available, will be deprecated later
- `linux_build/arm_templates/*` - No changes
- `linux_build/assets/*` - No changes
- `iotopps/*` - Module source applications, no changes to code

---

For complete details, see [separation_of_concerns.md](./separation_of_concerns.md)
