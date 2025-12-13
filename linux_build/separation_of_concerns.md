# Azure IoT Operations - Separation of Concerns Implementation Plan

## Executive Summary

This document outlines the separation of the current monolithic `linuxAIO.sh` script into two distinct processes:

1. **`linux_installer.sh`** - Local edge device configuration (runs on the target edge machine)
2. **`external_configurator.sh`** - Remote Azure resource management (runs from any machine with Azure CLI)

This separation enables:
- Better security practices (no Azure credentials needed on edge devices in production)
- Simplified edge device preparation and maintenance
- Remote management of multiple edge devices
- Clearer separation between infrastructure (edge) and orchestration (cloud)
- Easier troubleshooting and debugging of specific components

---

## Current State Analysis

### Existing `linuxAIO.sh` Functions

The current script performs these functions in order:

#### LOCAL (Edge Device) Functions
1. `check_root()` - Verify non-root user
2. `check_system_requirements()` - Validate CPU, RAM, kernel version
3. `check_port_conflicts()` - Ensure ports 6443, 10250, etc. are available
4. `load_config()` - Load local configuration from JSON
5. `update_system()` - Update Ubuntu packages
6. `install_kubectl()` - Install kubectl binary
7. `install_helm()` - Install Helm package manager
8. `install_optional_tools()` - Install k9s, mqtt-viewer, and mqttui based on configuration
9. `check_kubelite_conflicts()` - Check for MicroK8s/kubelite conflicts
9. `cleanup_k3s()` - Remove existing K3s installations
10. `check_k3s_resources()` - Pre-flight resource check
11. `install_k3s()` - Install and start K3s cluster
12. `configure_kubectl()` - Set up kubectl configuration for K3s
13. `configure_system_settings()` - Set sysctl parameters for AIO
14. `deploy_modules()` - Deploy edge applications based on modules configuration (edgemqttsim, hello-flask, sputnik, wasm-quality-filter-python)
15. `verify_local_deployment()` - Local verification (kubectl checks for deployed modules)

#### HYBRID (Both Local & Azure) Functions
16. `install_azure_cli()` - Install Azure CLI (needed locally for arc-enable)

#### REMOTE (Azure) Functions
17. `azure_login_setup()` - Azure authentication and subscription selection
18. `create_azure_resources()` - Create resource groups
19. `arc_enable_cluster()` - Connect K3s cluster to Azure Arc
20. `verify_cluster_connectivity()` - Verify Arc connectivity
21. `create_namespace()` - Create Azure Device Registry namespace
22. `deploy_iot_operations()` - Deploy AIO instance via Azure
23. `enable_asset_sync()` - Enable resource sync (rsync)

---

## Proposed Architecture

### Process 1: `linux_installer.sh` (Local Edge Device)

**Purpose**: Prepare the edge device with all necessary local infrastructure

**Runs On**: Target Ubuntu edge device (24.04+)

**Prerequisites**:
- Non-root user with sudo privileges
- Internet connectivity
- 16GB+ RAM, 4+ CPUs

**Functions** (in order):
1. `check_root()`
2. `check_system_requirements()`
3. `check_port_conflicts()`
4. `load_local_config()` - Load edge device configuration
5. `update_system()` - Optional, configurable
6. `install_kubectl()`
7. `install_helm()`
8. `install_optional_tools()` - Install k9s, mqtt-viewer based on optional_tools config
9. `check_kubelite_conflicts()`
10. `cleanup_k3s()`
11. `check_k3s_resources()`
12. `install_k3s()`
13. `configure_kubectl()`
14. `configure_system_settings()`
15. `deploy_modules()` - Deploy selected edge applications based on modules config
16. `verify_local_cluster()` - Local K3s health check
17. `generate_cluster_info()` - Export cluster details for remote configuration
18. `display_next_steps()` - Guide user to run external_configurator.sh

**Output**:
- Fully functional K3s cluster
- kubectl configured for local access
- Cluster information file: `cluster_info.json`
  ```json
  {
    "cluster_name": "edge-device-001",
    "kube_config": "<base64 encoded>",
    "node_info": {...},
    "deployed_modules": ["edgemqttsim"],
    "installed_tools": ["k9s"],
    "timestamp": "2025-12-12T10:30:00Z",
    "ready_for_arc": true
  }
  ```

**Configuration File**: `edge_config.json`
```json
{
  "edge_device": {
    "cluster_name": "edge-device-001",
    "skip_system_update": false,
    "force_reinstall": false
  },
  "k3s": {
    "disable_traefik": true,
    "write_kubeconfig_mode": "644"
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

**Optional Tools Configuration**:
The `optional_tools` section controls installation of helpful utilities:
- `k9s` - Terminal-based Kubernetes UI for cluster management (recommended for development)
- `mqtt-viewer` - Command-line MQTT message viewer for debugging telemetry
- `mqttui` - Terminal UI for MQTT with interactive topic browsing and subscription management

**Module Configuration**:
The `modules` section allows selective deployment of edge applications:
- `edgemqttsim` - Factory telemetry simulator with MQTT publishing
- `hello-flask` - Sample Flask web application for testing
- `sputnik` - Custom IoT processing application
- `wasm-quality-filter-python` - WebAssembly-based data filter

Set values to `true` to install/deploy, `false` to skip.

---

### Process 2: `external_configurator.sh` (Remote Management)

**Purpose**: Connect edge clusters to Azure and deploy AIO resources

**Runs On**: Any machine with Azure CLI (DevOps machine, developer workstation, CI/CD pipeline)

**Prerequisites**:
- Azure CLI installed
- Azure credentials with appropriate permissions
- Cluster information from `linux_installer.sh` (cluster_info.json)
- Network connectivity to edge device (for kubectl commands)

**Functions** (in order):
1. `check_prerequisites()` - Verify Azure CLI, credentials, cluster_info.json
2. `load_azure_config()` - Load Azure resource configuration
3. `azure_login_setup()` - Authenticate to Azure
4. `validate_cluster_connectivity()` - Test connection to edge K3s cluster
5. `create_azure_resources()` - Create RG, storage accounts, etc.
6. `arc_enable_cluster()` - Connect cluster to Azure Arc
7. `verify_arc_connectivity()` - Confirm Arc connection
8. `create_namespace()` - Create Device Registry namespace
9. `create_schema_registry()` - Create schema registry and storage
10. `deploy_iot_operations()` - Deploy AIO instance
11. `enable_asset_sync()` - Enable resource sync
12. `deploy_assets_to_azure()` - Deploy assets via ARM templates
13. `verify_deployment()` - End-to-end verification
14. `display_management_info()` - Show portal links and next steps

**Configuration File**: `azure_config.json`
```json
{
  "azure": {
    "subscription_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "subscription_name": "My IoT Subscription",
    "resource_group": "rg-iot-operations",
    "location": "eastus",
    "cluster_name": "edge-device-001",
    "namespace_name": "factory-namespace"
  },
  "deployment": {
    "deployment_mode": "production",
    "deploy_mqtt_assets": true,
    "enable_resource_sync": true
  }
}
```

**Input**: `cluster_info.json` from linux_installer.sh

**Output**:
- Arc-enabled Kubernetes cluster
- Azure IoT Operations instance deployed
- Assets synchronized to Azure
- Deployment summary: `deployment_summary.json`

---

## Implementation Phases

### Phase 1: Planning & Preparation (Week 1)
**Objective**: Establish foundation and validate approach

**Tasks**:
1. ✅ Create this separation_of_concerns.md document
2. ⬜ Review and validate function separation with stakeholders
3. ⬜ Create new configuration file schemas
   - `edge_config.template.json`
   - `azure_config.template.json`
   - `cluster_info.schema.json` (output from linux_installer)
4. ⬜ Document new workflows and use cases
5. ⬜ Create test plan for both scripts
6. ⬜ Set up test environments:
   - Fresh Ubuntu VM for edge testing
   - Azure subscription for integration testing
   - DevOps machine for external configurator testing

**Success Criteria**:
- [ ] All configuration templates created and validated
- [ ] Test environments provisioned
- [ ] Stakeholder approval on architecture

---

### Phase 2: Core Script Development (Week 2-3)

#### Phase 2a: linux_installer.sh
**Objective**: Create standalone edge device installer

**Tasks**:
1. ⬜ Create `linux_installer.sh` base structure
   - Copy logging functions (log, warn, error)
   - Copy utility functions
   - Create main() function skeleton
2. ⬜ Implement LOCAL functions from linuxAIO.sh
   - Copy and adapt: check_root, check_system_requirements
   - Copy and adapt: check_port_conflicts, update_system
   - Copy and adapt: install_kubectl, install_helm
   - Copy and adapt: check_kubelite_conflicts, cleanup_k3s
   - Copy and adapt: install_k3s, configure_kubectl
   - Copy and adapt: configure_system_settings
3. ⬜ Implement new functions:
   - `install_optional_tools()` - Install k9s (terminal K8s UI), mqtt-viewer (MQTT debugging), and mqttui (MQTT TUI)
   - `load_local_config()` - Parse edge_config.json
   - `deploy_modules()` - Iterate through modules config and deploy enabled applications
   - `verify_local_cluster()` - Comprehensive K3s health check
   - `generate_cluster_info()` - Export cluster metadata (include deployed modules and installed tools)
   - `display_next_steps()` - Guide to external_configurator
4. ⬜ Add error handling and rollback capabilities
5. ⬜ Implement dry-run mode for testing

**Deliverables**:
- Working `linux_installer.sh`
- `edge_config.template.json`
- Unit tests for each function

**Testing**:
- [ ] Clean Ubuntu VM installation (full install)
- [ ] Existing K3s cluster (detect and skip)
- [ ] Insufficient resources (graceful failure)
- [ ] Port conflicts (detection and resolution)
- [ ] Interrupted installation (resume capability)

---

#### Phase 2b: external_configurator.sh
**Objective**: Create remote Azure configuration tool

**Tasks**:
1. ⬜ Create `external_configurator.sh` base structure
   - Copy logging functions
   - Create main() function skeleton
   - Add remote execution helpers
2. ⬜ Implement REMOTE functions from linuxAIO.sh
   - Copy and adapt: azure_login_setup
   - Copy and adapt: create_azure_resources
   - Copy and adapt: arc_enable_cluster
   - Copy and adapt: create_namespace
   - Copy and adapt: deploy_iot_operations
   - Copy and adapt: enable_asset_sync
3. ⬜ Implement new functions:
   - `check_prerequisites()` - Verify Azure CLI, cluster_info
   - `load_azure_config()` - Parse azure_config.json
   - `load_cluster_info()` - Import edge cluster metadata
   - `validate_cluster_connectivity()` - Remote kubectl test
   - `deploy_assets_to_azure()` - ARM template deployment
   - `generate_deployment_summary()` - Export deployment results
4. ⬜ Add support for managing multiple clusters
5. ⬜ Implement idempotent operations (safe to re-run)

**Deliverables**:
- Working `external_configurator.sh`
- `azure_config.template.json`
- `deployment_summary.schema.json`
- Unit tests for each function

**Testing**:
- [ ] Connect to edge cluster from remote machine
- [ ] Handle Azure authentication failures gracefully
- [ ] Deploy to existing resource group
- [ ] Deploy to new resource group
- [ ] Re-run without side effects (idempotency)
- [ ] Multiple cluster management

---

### Phase 3: Integration & Testing (Week 4)
**Objective**: Validate end-to-end workflows

**Tasks**:
1. ⬜ End-to-end integration testing
   - Clean installation on fresh Ubuntu VM
   - Run linux_installer.sh
   - Transfer cluster_info.json to remote machine
   - Run external_configurator.sh
   - Verify AIO deployment in Azure portal
2. ⬜ Scenario testing:
   - **Scenario A**: Developer local setup (both scripts on same machine)
   - **Scenario B**: Production deployment (scripts on different machines)
   - **Scenario C**: CI/CD pipeline integration
   - **Scenario D**: Multiple edge devices (one external_configurator, many installers)
   - **Scenario E**: Disaster recovery (re-run linux_installer after cluster failure)
3. ⬜ Performance benchmarking
   - Time each phase
   - Measure resource usage
   - Document bottlenecks
4. ⬜ Create troubleshooting guides
   - Common failure modes
   - Debug commands
   - Recovery procedures

**Success Criteria**:
- [ ] All scenarios pass successfully
- [ ] Installation time documented
- [ ] Failure recovery procedures validated
- [ ] Zero manual interventions required

---

### Phase 4: Existing Scripts Integration (Week 5)
**Objective**: Update supporting scripts to work with new architecture

**Tasks**:
1. ⬜ Update `deploy-assets.sh`
   - Make compatible with external_configurator output
   - Support cluster_info.json as input
   - Add validation checks
2. ⬜ Update `deploy-fabric-dataflows.sh`
   - Read from deployment_summary.json
   - Support remote execution
3. ⬜ Update diagnostic scripts
   - `diagnose-orchestrator.sh` - Support remote diagnostics
   - `check_discovery.sh` - Work with new asset structure
   - `k3s_troubleshoot.sh` - Enhanced edge-only checks
4. ⬜ Create new helper scripts:
   - `transfer-cluster-info.sh` - Secure transfer of cluster_info.json
   - `validate-configs.sh` - Pre-flight config validation
   - `multi-cluster-manager.sh` - Manage multiple edge devices

**Deliverables**:
- Updated scripts in linux_build/
- New helper scripts
- Updated script documentation

---

### Phase 5: Documentation & Training (Week 6)
**Objective**: Comprehensive documentation for new processes

**Tasks**:
1. ⬜ Update root `readme.md`
   - Add new architecture section
   - Update Quick Start guide
   - Add use case examples
2. ⬜ Update `linux_build_steps.md`
   - Separate edge and cloud sections
   - Add new configuration examples
   - Update troubleshooting guide
3. ⬜ Create new documentation:
   - `edge_installation_guide.md` - Complete linux_installer guide
   - `remote_configuration_guide.md` - External configurator guide
   - `multi_cluster_management.md` - Managing multiple edge devices
   - `cicd_integration_guide.md` - Pipeline integration examples
4. ⬜ Create video tutorials:
   - Basic setup walkthrough
   - Multi-cluster deployment
   - Troubleshooting common issues
5. ⬜ Update iotopps/ documentation
   - How to deploy apps on new architecture
   - Remote deployment patterns

**Deliverables**:
- Updated readme.md
- 4 new documentation files
- Tutorial videos
- Updated inline script documentation

---

### Phase 6: Migration & Deprecation (Week 7)
**Objective**: Transition from old to new scripts

**Tasks**:
1. ⬜ Create migration guide
   - How to move from linuxAIO.sh to new scripts
   - Data migration (if any)
   - Compatibility notes
2. ⬜ Add deprecation notice to `linuxAIO.sh`
   - Header warning about new scripts
   - Link to migration guide
   - Set EOL date
3. ⬜ Create compatibility shim (optional)
   - `linuxAIO_compat.sh` - Calls new scripts internally
   - Maintains backward compatibility
   - Logs deprecation warnings
4. ⬜ Update all references in repository
   - Github Actions workflows
   - Other script references
   - Documentation links
5. ⬜ Community communication
   - Blog post about new architecture
   - Update README with migration notice
   - Respond to user feedback

**Deliverables**:
- Migration guide
- Deprecated linuxAIO.sh with notices
- Optional compatibility shim
- Updated repository references

---

### Phase 7: Production Validation (Week 8)
**Objective**: Real-world validation before final release

**Tasks**:
1. ⬜ Beta testing program
   - Recruit 5-10 beta testers
   - Provide early access to new scripts
   - Collect feedback and issues
2. ⬜ Production deployment testing
   - Deploy to development environment
   - Deploy to staging environment
   - Deploy to production (limited rollout)
3. ⬜ Performance optimization
   - Address any bottlenecks found in beta
   - Optimize long-running operations
   - Add progress indicators
4. ⬜ Security review
   - Credential handling audit
   - Network security review
   - File permission checks
5. ⬜ Final documentation updates
   - Address beta tester feedback
   - Add FAQ section
   - Update troubleshooting guides

**Success Criteria**:
- [ ] Zero critical issues from beta testing
- [ ] Production deployments successful
- [ ] Performance meets or exceeds linuxAIO.sh
- [ ] Security review passed

---

## Testing Strategy

### Unit Testing
Each function should be testable independently:

```bash
# Test individual functions
bash test_functions.sh check_system_requirements
bash test_functions.sh install_k3s --dry-run
```

### Integration Testing
Test complete workflows:

```bash
# Test full edge installation
bash test_integration.sh --test-suite edge_install

# Test full Azure configuration
bash test_integration.sh --test-suite azure_config

# Test end-to-end
bash test_integration.sh --test-suite e2e
```

### Compatibility Testing
Ensure works on:
- [ ] Ubuntu 24.04 LTS
- [ ] Ubuntu 22.04 LTS (if supported)
- [ ] Different Azure regions
- [ ] Different VM sizes
- [ ] Different network configurations

### Regression Testing
Compare new scripts with original linuxAIO.sh:
- [ ] Same end result (functional parity)
- [ ] No new errors introduced
- [ ] Performance comparable or better

---

## Risk Management

### Risk 1: Breaking Changes for Existing Users
**Mitigation**:
- Keep linuxAIO.sh available during transition period
- Create compatibility shim
- Provide clear migration guide
- Set 6-month deprecation timeline

### Risk 2: Increased Complexity
**Mitigation**:
- Comprehensive documentation
- Wizard-style helper scripts
- Clear error messages with remediation steps
- Video tutorials

### Risk 3: Network Connectivity Issues
**Mitigation**:
- External configurator should handle intermittent connectivity
- Add retry logic with exponential backoff
- Support offline mode where possible
- Clear connectivity requirements documentation

### Risk 4: Security of cluster_info.json
**Mitigation**:
- Document secure transfer methods
- Add encryption option for cluster_info.json
- Include kubeconfig expiration handling
- Provide secure deletion instructions

### Risk 5: Testing Coverage Gaps
**Mitigation**:
- Automated test suite
- Beta testing program
- Gradual rollout strategy
- Rollback procedures documented

---

## Success Metrics

### Quantitative
- [ ] Installation time reduced by 20% (parallel execution)
- [ ] 90% of functions have unit tests
- [ ] 100% of integration scenarios pass
- [ ] Zero critical bugs in production first month
- [ ] Support for 10+ concurrent edge devices from one external_configurator

### Qualitative
- [ ] Positive user feedback (>80% satisfaction)
- [ ] Easier troubleshooting (reduced support tickets)
- [ ] Improved security posture (credentials not on edge)
- [ ] Better maintainability (clear separation of concerns)

---

## File Structure After Implementation

```
linux_build/
├── linux_installer.sh              # NEW: Edge device installer
├── external_configurator.sh        # NEW: Remote Azure configurator
├── linuxAIO.sh                     # DEPRECATED: Original monolithic script
├── edge_config.template.json       # NEW: Edge configuration template
├── azure_config.template.json      # NEW: Azure configuration template
├── cluster_info.schema.json        # NEW: Cluster info output schema
├── deployment_summary.schema.json  # NEW: Deployment output schema
├── linux_aio_config.json           # DEPRECATED: Will be removed
├── linux_aio_config.template.json  # DEPRECATED: Will be removed
├── deploy-assets.sh                # UPDATED: Compatible with new architecture
├── deploy-fabric-dataflows.sh      # UPDATED: Works with deployment_summary.json
├── transfer-cluster-info.sh        # NEW: Helper for secure transfer
├── validate-configs.sh             # NEW: Pre-flight validation
├── multi-cluster-manager.sh        # NEW: Manage multiple edge devices
├── test_functions.sh               # NEW: Unit test runner
├── test_integration.sh             # NEW: Integration test suite
├── docs/
│   ├── edge_installation_guide.md      # NEW: Edge installer documentation
│   ├── remote_configuration_guide.md   # NEW: External configurator docs
│   ├── multi_cluster_management.md     # NEW: Multi-cluster patterns
│   ├── cicd_integration_guide.md       # NEW: CI/CD examples
│   └── migration_guide.md              # NEW: Migration from linuxAIO.sh
├── arm_templates/                  # EXISTING: No changes
├── assets/                         # EXISTING: No changes
└── ... (other diagnostic scripts)  # UPDATED: Support new architecture
```

---

## Next Steps

1. **Immediate Actions** (This Week):
   - [ ] Review this document with team
   - [ ] Get approval on architecture
   - [ ] Provision test environments
   - [ ] Create GitHub issues for each phase

2. **Phase 1 Kickoff** (Next Week):
   - [ ] Start configuration schema design
   - [ ] Begin test plan documentation
   - [ ] Set up development branches

3. **Communication**:
   - [ ] Share this document with stakeholders
   - [ ] Schedule weekly sync meetings
   - [ ] Create project board for tracking

---

## Questions for Review

1. **Naming**: Are `linux_installer.sh` and `external_configurator.sh` good names? Alternatives?
2. **Backward Compatibility**: Should we maintain linuxAIO.sh indefinitely or set firm deprecation date?
3. **Security**: Do we need encryption for cluster_info.json? Or is secure transfer documentation sufficient?
4. **Testing**: What level of test automation is expected?
5. **Documentation**: Are video tutorials required or optional?
6. **Timeline**: Is 8-week timeline realistic given resources?

---

## Conclusion

This separation of concerns will significantly improve the maintainability, security, and usability of the Azure IoT Operations deployment process. By clearly separating edge infrastructure (linux_installer) from cloud orchestration (external_configurator), we enable:

- **Production-ready deployments** with proper security boundaries
- **Multi-cluster management** from a single control point
- **Easier troubleshooting** with clear responsibility boundaries
- **CI/CD integration** with scriptable, idempotent operations
- **Better testing** with isolated, unit-testable components

The phased approach ensures we can validate each step before proceeding, minimizing risk while maximizing value delivery.
