# Edge Modules and Tools Configuration Guide

## Overview

The modular deployment system allows you to selectively deploy edge applications and install optional development tools based on your use case. Instead of deploying everything or nothing, you can choose exactly which modules run on your edge device and which tools are available for management and debugging.

## Configuration Location

Modules and tools are configured in the `linux_aio_config.json` file:

```json
{
  "optional_tools": {
    "k9s": true,
    "mqtt-viewer": false,
    "mqttui": false,
    "ssh": false
  },
  "modules": {
    "edgemqttsim": true,
    "hello-flask": false,
    "sputnik": false,
    "wasm-quality-filter-python": false
  }
}
```

---

## Optional Tools

### k9s
**Purpose**: Terminal-based Kubernetes cluster management UI

**What it does**:
- Interactive terminal UI for Kubernetes cluster management
- Real-time pod monitoring and log viewing
- Easy resource navigation (pods, services, deployments, etc.)
- Keyboard-driven interface for fast operations
- Color-coded status indicators

**When to enable**:
- ✅ Development environments
- ✅ Troubleshooting and debugging
- ✅ Learning Kubernetes
- ✅ Real-time cluster monitoring
- ❌ Production (unless operators need it)
- ❌ Automated/headless environments

**Resource usage**: Minimal (20-30MB RAM when running)

**Usage after installation**:
```bash
# Launch k9s
k9s

# Common shortcuts:
# :pods - View pods
# :svc - View services
# :deploy - View deployments
# l - View logs
# d - Describe resource
# q - Quit
```

**Installation method**: Binary download from GitHub releases

---

### mqtt-viewer
**Purpose**: Command-line MQTT message viewer for debugging

**What it does**:
- Subscribe to MQTT topics and display messages in real-time
- Color-coded message display
- JSON formatting for structured data
- Filter by topic patterns
- Useful for debugging telemetry flows

**When to enable**:
- ✅ Debugging MQTT connectivity
- ✅ Validating telemetry data
- ✅ Development and testing
- ✅ Troubleshooting data flows
- ❌ Production (no continuous monitoring needed)
- ❌ Minimal installations

**Resource usage**: Minimal (10-20MB RAM when running)

**Usage after installation**:
```bash
# View messages from AIO broker
mqtt-viewer -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883 -t 'factory/#'

# View specific topic
mqtt-viewer -h localhost -p 1883 -t 'factory/telemetry'

# With authentication (if required)
mqtt-viewer -h broker -p 8883 -t 'topic' -u username -P password
```

**Installation method**: Python package via pip

---

### mqttui
**Purpose**: Terminal UI for MQTT with interactive topic browsing

**What it does**:
- Full-featured terminal user interface for MQTT
- Interactive topic tree browser (discover topics automatically)
- Subscribe to multiple topics simultaneously
- Real-time message display with syntax highlighting
- Message history and search
- Visual connection status
- Topic pattern matching and wildcards
- Export messages to file

**When to enable**:
- ✅ Advanced MQTT debugging and exploration
- ✅ Discovery of unknown topics (topic tree browsing)
- ✅ Development with complex MQTT structures
- ✅ Learning MQTT topic hierarchies
- ✅ Interactive message inspection
- ❌ Production environments
- ❌ Simple one-off message viewing (use mqtt-viewer)
- ❌ Automated/headless environments

**Resource usage**: Minimal (15-30MB RAM when running)

**Usage after installation**:
```bash
# Launch mqttui with AIO broker
mqttui -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883

# With authentication
mqttui -h broker -p 8883 -u username -P password

# With TLS
mqttui -h broker -p 8883 --insecure

# Interactive mode (default)
# - Browse topic tree on left
# - View messages on right
# - Press 's' to subscribe to selected topic
# - Press 'h' for help
```

**Key Features**:
- **Topic Discovery**: Automatically builds topic tree as messages arrive
- **Multi-subscription**: Subscribe to many topics at once
- **Search**: Find messages by content or topic
- **History**: Scroll through message history
- **Export**: Save messages for later analysis
- **Visual**: Color-coded UI with clear status indicators

**Installation method**: Binary download from GitHub releases

---

### ssh
**Purpose**: Secure remote shell access to the edge device

**What it does**:
- Installs and configures OpenSSH server
- Sets up key-based authentication (password auth disabled)
- Configures firewall rules for SSH port 22
- Generates unique host keys
- Creates an SSH key pair for secure access
- Prints connection details at end of installation

**When to enable**:
- ✅ Remote management and troubleshooting
- ✅ Development environments requiring remote access
- ✅ Multi-operator scenarios
- ✅ Edge devices in accessible network locations
- ❌ Air-gapped environments
- ❌ Strict zero-trust networks
- ❌ When physical-only access is required

**Resource usage**: Minimal (~10MB disk, <5MB RAM idle, ~20MB per active session)

**Security features**:
- Key-based authentication only (passwords disabled)
- Automatic key generation with 4096-bit RSA
- Host key verification
- Connection logging
- Firewall integration

**Installation method**: apt package (openssh-server)

**Post-install output**: Displays SSH connection command with IP address and key location

```bash
# Example output at end of installation:
========================================
SSH Configuration Complete
========================================
SSH Server: RUNNING
Host IP: 192.168.1.100
SSH Port: 22

Private Key Location: /home/adminuser/.ssh/id_rsa_edge_device
Public Key: Added to authorized_keys

To connect from another machine:
1. Copy private key to your machine
2. Run: ssh -i /path/to/id_rsa_edge_device adminuser@192.168.1.100

Security Notes:
- Password authentication is DISABLED
- Only key-based authentication is allowed
- Keep private key secure and never commit to git
========================================
```

---

## Available Modules

### edgemqttsim
**Purpose**: Factory telemetry simulator with MQTT publishing

**What it does**:
- Simulates factory equipment (CNC machines, assembly lines, welding stations)
- Publishes realistic telemetry data to the AIO MQTT broker
- Supports multiple equipment types with configurable intervals
- Ideal for testing and demonstration scenarios

**When to enable**:
- ✅ Testing MQTT connectivity
- ✅ Demonstrating AIO capabilities
- ✅ Development and learning environments
- ✅ Data pipeline validation
- ❌ Production (use real equipment data)

**Resource usage**: Low (50-100MB RAM, minimal CPU)

**Location**: `iotopps/edgemqttsim/`

---

### hello-flask
**Purpose**: Sample Flask web application for testing

**What it does**:
- Simple Python Flask web server
- Basic HTTP endpoint for health checks
- Useful for validating container deployment
- Demonstrates basic Kubernetes service exposure

**When to enable**:
- ✅ Testing K3s deployment
- ✅ Validating container registry access
- ✅ Learning Kubernetes basics
- ✅ Network connectivity testing
- ❌ Production workloads

**Resource usage**: Minimal (30-50MB RAM, minimal CPU)

**Location**: `iotopps/hello-flask/`

---

### sputnik
**Purpose**: Custom IoT processing application

**What it does**:
- Specialized edge processing logic
- Custom business logic for IoT scenarios
- Extensible framework for custom applications

**When to enable**:
- ✅ Custom IoT processing requirements
- ✅ Specific business logic needed on edge
- ✅ Production custom applications
- ❌ Standard telemetry collection only

**Resource usage**: Medium (100-200MB RAM, moderate CPU)

**Location**: `iotopps/sputnik/`

---

### wasm-quality-filter-python
**Purpose**: WebAssembly-based telemetry filtering

**What it does**:
- Filters telemetry data at the edge using WebAssembly
- Reduces bandwidth by processing data locally
- Quality checks and data validation
- High-performance data transformation

**When to enable**:
- ✅ Edge data filtering needed
- ✅ Bandwidth optimization required
- ✅ Quality checks before cloud transmission
- ✅ Production edge processing
- ❌ All data needed in cloud

**Resource usage**: Medium (150-250MB RAM, CPU varies with load)

**Location**: `iotopps/wasm-quality-filter-python/`

---

## Configuration Examples

### Scenario 1: Basic Telemetry Testing
**Goal**: Test MQTT connectivity and data flows

```json
{
  "optional_tools": {
    "k9s": true,
    "mqtt-viewer": true,
    "mqttui": false,
    "ssh": false
  },
  "modules": {
    "edgemqttsim": true,
    "hello-flask": false,
    "sputnik": false,
    "wasm-quality-filter-python": false
  }
}
```

**Result**: MQTT simulator + basic debugging tools, perfect for development and testing

---

### Scenario 2: Advanced MQTT Development
**Goal**: Deep MQTT debugging with topic discovery

```json
{
  "optional_tools": {
    "k9s": true,
    "mqtt-viewer": false,
    "mqttui": true,
    "ssh": false
  },
  "modules": {
    "edgemqttsim": true,
    "hello-flask": false,
    "sputnik": false,
    "wasm-quality-filter-python": false
  }
}
```

**Result**: Interactive MQTT exploration with mqttui for complex topic hierarchies

---

### Scenario 3: Complete Development Environment
**Goal**: All modules and tools for comprehensive testing

```json
{
  "optional_tools": {
    "k9s": true,
    "mqtt-viewer": true,
    "mqttui": true,
    "ssh": true
  },
  "modules": {
    "edgemqttsim": true,
    "hello-flask": true,
    "sputnik": true,
    "wasm-quality-filter-python": true
  }
}
```

**Result**: Full stack with all debugging tools, highest resource usage, comprehensive testing

---

### Scenario 4: Production Edge Processing
**Goal**: Real telemetry with edge filtering, minimal tools

```json
{
  "optional_tools": {
    "k9s": false,
    "mqtt-viewer": false,
    "mqttui": false,
    "ssh": false
  },
  "modules": {
    "edgemqttsim": false,
    "hello-flask": false,
    "sputnik": false,
    "wasm-quality-filter-python": true
  }
}
```

**Result**: Only the WebAssembly filter runs, no dev tools, production-ready

---

### Scenario 5: Infrastructure Validation Only
**Goal**: Test K3s without IoT workloads but with monitoring

```json
{
  "optional_tools": {
    "k9s": true,
    "mqtt-viewer": false,
    "mqttui": false,
    "ssh": false
  },
  "modules": {
    "edgemqttsim": false,
    "hello-flask": true,
    "sputnik": false,
    "wasm-quality-filter-python": false
  }
}
```

**Result**: Simple web app with k9s for cluster monitoring

---

### Scenario 6: No Modules (Minimal Setup)
**Goal**: AIO infrastructure only, deploy apps later

```json
{
  "optional_tools": {
    "k9s": false,
    "mqtt-viewer": false,
    "mqttui": false,
    "ssh": false
  },
  "modules": {}
}
```
or
```json
{
  "optional_tools": {
    "k9s": false,
    "mqtt-viewer": false,
    "mqttui": false,
    "ssh": false
  },
  "modules": {
    "edgemqttsim": false,
    "hello-flask": false,
    "sputnik": false,
    "wasm-quality-filter-python": false
  }
}
```

**Result**: K3s + AIO only, no edge applications, fastest installation

---

## Module Deployment Process

When you run `linux_installer.sh`, the `deploy_modules()` function:

1. **Reads Configuration**: Parses `linux_aio_config.json` modules section
2. **Validates Availability**: Checks if deployment files exist in `iotopps/`
3. **Iterates Through Modules**: For each module set to `true`:
   - Locates the deployment YAML file
   - Runs `kubectl apply -f <module>/deployment.yaml`
   - Waits for pod to be ready
   - Validates deployment success
4. **Records Status**: Adds deployed modules to `cluster_info.json`
5. **Displays Summary**: Shows which modules were deployed and their status

## Adding Custom Modules

You can extend the module system with your own applications:

### Step 1: Create Your Application
```
iotopps/
└── my-custom-app/
    ├── app.py (or your application code)
    ├── deployment.yaml
    ├── Dockerfile
    ├── README.md
    └── requirements.txt (if applicable)
```

### Step 2: Add to Configuration
```json
{
  "modules": {
    "my-custom-app": true
  }
}
```

### Step 3: Update deploy_modules() Function
The function will automatically detect and deploy modules based on directory structure, or you can add explicit handling:

```bash
# In deploy_modules() function
deploy_module() {
    local module_name=$1
    local module_dir="$BASE_DIR/../iotopps/$module_name"
    
    if [ -f "$module_dir/deployment.yaml" ]; then
        log "Deploying $module_name..."
        kubectl apply -f "$module_dir/deployment.yaml"
        # Wait and verify...
    fi
}
```

## Module Dependencies

Some modules may depend on others:

- **wasm-quality-filter-python** requires MQTT broker (provided by AIO)
- **sputnik** may require specific storage or network configurations
- **edgemqttsim** requires MQTT broker and asset endpoint profiles

The deployment script handles these dependencies automatically by:
1. Deploying AIO first (provides MQTT broker)
2. Deploying modules in dependency order
3. Validating prerequisites before each module

## Troubleshooting Module Deployment

### Module Won't Deploy
```bash
# Check if deployment file exists
ls -la iotopps/edgemqttsim/deployment.yaml

# Check for typos in module name
cat linux_aio_config.json | jq '.modules'

# Check K3s cluster status
kubectl get pods -n azure-iot-operations
```

### Module Deployed But Not Running
```bash
# Check pod status
kubectl get pods -n azure-iot-operations -l app=edgemqttsim

# View pod logs
kubectl logs -n azure-iot-operations deployment/edgemqttsim

# Describe pod for events
kubectl describe pod -n azure-iot-operations <pod-name>
```

### Remove Deployed Module
```bash
# Delete specific module
kubectl delete -f iotopps/edgemqttsim/deployment.yaml

# Or delete by label
kubectl delete deployment,service -n azure-iot-operations -l app=edgemqttsim
```

### Optional Tools Not Installing
```bash
# Check if internet connectivity is available
ping github.com
ping pypi.org

# Manually install k9s
wget https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz
tar -xzf k9s_Linux_amd64.tar.gz
sudo mv k9s /usr/local/bin/

# Manually install mqtt-viewer
pip3 install mqtt-viewer

# Manually install mqttui
wget https://github.com/EdJoPaTo/mqttui/releases/latest/download/mqttui-x86_64-unknown-linux-gnu.tar.gz
tar -xzf mqttui-x86_64-unknown-linux-gnu.tar.gz
sudo mv mqttui /usr/local/bin/

# Verify installation
k9s version
mqtt-viewer --help
mqttui --version
```

### Optional Tools Not Working
```bash
# k9s cannot connect to cluster
export KUBECONFIG=~/.kube/config
k9s

# mqtt-viewer cannot connect to broker
# Check if AIO broker is running
kubectl get svc -n azure-iot-operations aio-broker

# mqttui connection issues
# Test with verbose output
mqttui -h aio-broker.azure-iot-operations.svc.cluster.local -p 18883 --verbose

# Test with mosquitto_sub first
kubectl exec -it -n azure-iot-operations deploy/aio-broker-frontend -- \
  mosquitto_sub -h localhost -p 18883 -t 'factory/#' -v
```

## Best Practices

### Optional Tools
**Development**:
- ✅ Enable k9s - invaluable for debugging and learning
- ✅ Enable mqtt-viewer - essential for MQTT troubleshooting
- ✅ Enable mqttui - powerful for complex MQTT exploration
- Keep tools installed on development machines
- Use mqttui for discovering unknown topic structures

**Production**:
- ❌ Disable k9s unless operators specifically need it
- ❌ Disable mqtt-viewer in production environments
- ❌ Disable mqttui in production environments
- Minimize tools to reduce attack surface
- Use centralized monitoring instead

**CI/CD**:
- Disable optional tools in automated pipelines
- Tools not needed for headless deployments
- Save installation time in CI/CD

### Development
- Enable all modules for comprehensive testing
- Use `hello-flask` to validate basic deployment first
- Enable `edgemqttsim` for data flow testing

### Production
- Only enable modules needed for your use case
- Disable simulators and test applications
- Enable edge processing modules (wasm-quality-filter-python)
- Monitor resource usage and adjust accordingly

### CI/CD
- Use environment variables to control module selection
- Create different config files for dev/staging/production
- Validate module configs before deployment
- Include module status in deployment reports

## Resource Planning

Plan your edge device resources based on modules and tools:

| Configuration | RAM Required | CPU Required | Optional Tools | Use Case |
|--------------|--------------|--------------|----------------|----------|
| Minimal (no modules) | 8GB | 2 cores | None | Infrastructure only |
| Basic testing | 10GB | 2 cores | k9s, mqtt-viewer | Testing, demos |
| Development (all) | 16GB+ | 4 cores | k9s, mqtt-viewer | Full development |
| Production (selective) | 12-14GB | 2-4 cores | None | Optimized workload |
| Production with monitoring | 12-14GB | 2-4 cores | k9s only | Production + operator access |

**Notes**:
- Optional tools add minimal overhead (50MB total)
- k9s only uses RAM when actively running
- mqtt-viewer only uses RAM when actively subscribing
- Base AIO installation requires ~6-8GB RAM before modules

## Module and Tool Status Tracking

After deployment, check `cluster_info.json` to see what was deployed and installed:

```json
{
  "deployed_modules": ["edgemqttsim", "wasm-quality-filter-python"],
  "installed_tools": ["k9s", "mqtt-viewer"],
  "module_status": {
    "edgemqttsim": "running",
    "wasm-quality-filter-python": "running"
  },
  "tool_versions": {
    "k9s": "v0.31.0",
    "mqtt-viewer": "1.2.3"
  }
}
```

This information is used by `external_configurator.sh` to understand the edge configuration.

## Future Enhancements

Planned improvements to the module system:

- [ ] Module versioning support
- [ ] Dependency management (automatic prerequisite detection)
- [ ] Module marketplace (community modules)
- [ ] Hot-reload (add/remove modules without reinstalling K3s)
- [ ] Resource quotas per module
- [ ] Module health monitoring and auto-restart
- [ ] Module configuration validation schema
- [ ] Interactive module selector CLI

## Related Documentation

- [Separation of Concerns Plan](./separation_of_concerns.md) - Overall architecture
- [Quick Reference](./separation_quick_reference.md) - Quick lookup guide
- [Edge MQTT Simulator README](../iotopps/edgemqttsim/README.md) - Detailed edgemqttsim docs
- [WASM Filter README](../iotopps/wasm-quality-filter-python/README.md) - WebAssembly filter details
