# Copilot Instructions for Azure IoT Operations Learning Repository

## Important Constraints
⚠️ **Cannot Run Bash Scripts Directly**: The edge server (Linux) has no AI access. All bash scripts must be provided as code for the user to manually pull changes to the edge server and execute. Only PowerShell scripts can be run directly on the Windows development machine.

## Project Overview
This repository is focused on learning and implementing Azure IoT Operations (AIO) on edge devices using Kubernetes (K3s). It contains containerized IoT applications, deployment automation, and simulation tools for industrial IoT scenarios.

## Repository Structure

### Core Directories
- **`iotopps/`** - IoT Operations applications (containerized apps for edge deployment)
  - `edgemqttsim/` - Industrial IoT simulator with configurable message generation
  - `sputnik/` - Simple MQTT test publisher
  - `hello-flask/` - REST API example
  - `wasm-quality-filter-python/` - WebAssembly quality control module
- **`linux_build/`** - Azure IoT Operations automated installation system
  - `linuxAIO.sh` - Main installation script with comprehensive error handling
  - `linux_aio_config.json` - Configuration file for customized deployments
  - Diagnostic scripts for K3s troubleshooting (`k3s_troubleshoot.sh`, `diagnose-orchestrator.sh`)
  - Network and port configuration utilities
- **`operations/`** - Azure operations and integration configurationsl
- **`certs/`** - Certificate handling (base64 encoded)

### Key Applications
- **Sputnik** - MQTT publisher sending periodic "beep" messages for testing
- **Edge MQTT Simulator (edgemqttsim)** - Comprehensive industrial IoT simulator with modular message generation
  - Simulates factory equipment (CNC, 3D printers, welding, painting, testing rigs)
  - Configurable via YAML (`message_structure.yaml`) for message types, frequencies, and distributions
  - Supports business events (customer orders, dispatch notifications)
  - Intelligent topic routing and queue management
  - Built-in statistics tracking
- **Hello-Flask** - Simple REST API demonstrating containerized deployment
- **WASM Quality Filter** - WebAssembly module for real-time quality control filtering

## Technology Stack

### Primary Technologies
- **Azure IoT Operations** - Microsoft's edge computing platform
- **Kubernetes (K3s)** - Lightweight Kubernetes for edge devices
- **MQTT** - Message queuing protocol for IoT communication
- **Docker** - Containerization for edge applications
- **Python** - Primary development language with `uv` package manager
- **PowerShell** - Deployment automation scripts

### Azure Services
- **Azure IoT Hub** - Cloud IoT device management
- **Azure Arc** - Hybrid cloud management
- **Microsoft Fabric Real-Time Intelligence** - Analytics and visualization
- **Azure Container Registry** - Container image storage

## Development Patterns

### Deployment Approach
- **Prefer ARM Templates over Azure CLI** - ARM templates provide more stable and reliable deployments
  - Use ARM templates for: assets, asset endpoints, dataflows, and other Azure resources
  - ARM deployments are declarative and can be version-controlled
  - CLI commands are acceptable for ad-hoc queries and troubleshooting
  - Example: Use `az deployment group create --template-file` instead of `az iot ops dataflow create`

### Authentication
- **Preferred**: ServiceAccountToken (K8S-SAT) for in-cluster applications
- **Alternative**: X.509 certificates for external clients
- Applications should use MQTT v5 with enhanced authentication

### Container Deployment
- Applications follow standard Docker + Kubernetes pattern
- Each app includes: `Dockerfile`, `deployment.yaml`, `requirements.txt`, `README.md`
- Use unified deployment scripts: `Deploy-ToIoTEdge.ps1`, `Deploy-Local.ps1`, `Deploy-Check.ps1`

### MQTT Message Structure
- JSON format with consistent schema
- Required fields: `timestamp` (ISO 8601), `machine_id`, `station_id`, `status`
- Equipment-specific fields: `part_type`, `part_id`, `cycle_time`, `assembly_type`, `progress`
- Quality metrics: `good`, `scrap`, or `null` (for in-progress operations)
- Support for OEE calculations (Availability, Performance, Quality)
- Business event messages: order placement, dispatch/fulfillment

## Coding Guidelines

### File Naming Conventions
- Application folders: lowercase with hyphens (e.g., `hello-flask`)
- Python files: snake_case (e.g., `asset_creation.py`)
- Configuration files: kebab-case (e.g., `deployment.yaml`)
- Documentation: UPPERCASE for important docs (e.g., `README.md`)

### Python Development
- Use `uv` for dependency management instead of pip/poetry
- Include `pyproject.toml` for project configuration
- Follow containerized development pattern with Dockerfile
- Include health check endpoints for web applications

### PowerShell Scripts
- Modular deployment scripts with clear parameter documentation
- Support both Docker Hub and Azure Container Registry
- Include error handling and status checking
- Use consistent parameter naming across scripts

## Common Operations

### Azure IoT Operations Installation (Linux)
```bash
# Configure installation (optional but recommended)
cd linux_build
cp linux_aio_config.template.json linux_aio_config.json
# Edit linux_aio_config.json with your Azure settings

# Run automated installation
chmod +x linuxAIO.sh
./linuxAIO.sh

# The script handles:
# - System prerequisites and updates
# - K3s cluster installation and configuration
# - Azure CLI and IoT Operations CLI setup
# - Azure Arc connection
# - Azure IoT Operations deployment
# - Post-deployment verification
```

### Local Development
```bash
# Setup Python environment
uv sync

# Run application locally
.\Deploy-Local.ps1 -AppFolder "app-name" -Mode python

# For simulator: configure message generation
cd iotopps/edgemqttsim
# Edit message_structure.yaml to adjust message types and frequencies
```

### Edge Deployment
```powershell
# Deploy to remote IoT Operations cluster
.\Deploy-ToIoTEdge.ps1 -AppFolder "edgemqttsim" -RegistryName "username"

# Check deployment status
.\Deploy-Check.ps1 -AppFolder "edgemqttsim"
```

### MQTT Testing
```bash
# View MQTT messages
kubectl logs -n default -l app=mosquitto-sub -f

# Check Sputnik status
kubectl get pods -l app=sputnik
```

## Key Concepts to Understand

### Azure IoT Operations
- Edge-first platform running on Kubernetes
- Local MQTT broker for device communication
- Data flow processing and transformation
- Integration with Azure cloud services

### Industrial IoT Simulation (Edge MQTT Simulator)
- **Modular Architecture**: Separate `app.py` (MQTT client) and `messages.py` (message generation)
- **YAML Configuration**: All message types, frequencies, and parameters in `message_structure.yaml`
- **Equipment Types**: CNC machines, 3D printers, welding stations, painting booths, testing rigs
- **Business Events**: Customer orders and dispatch notifications
- **Topic Routing**: Intelligent routing to type-specific topics (e.g., `factory/cnc`, `factory/welding`)
- **State Management**: Realistic machine state tracking across cycles
- **Quality & OEE**: Configurable quality distributions supporting OEE calculations
- **Real-time Processing**: WASM modules for quality filtering
- **Analytics Integration**: Microsoft Fabric for visualization and insights

### Edge Computing Workflow
1. Devices/simulators → MQTT broker (edge)
2. Data flow processing → transformation/filtering
3. Cloud integration → Azure services
4. Analytics/visualization → Fabric Real-Time Intelligence

## Project-Specific Notes

### Certificate Management
- Certificates stored in base64 format in `certs/` directory
- Automated certificate setup scripts in `iotopps/`
- ServiceAccountToken preferred over X.509 for simplicity

### Troubleshooting Resources
- **K3s Diagnostics**: `k3s_troubleshoot.sh`, `k3s_advanced_diagnostics.sh`, `diagnose-orchestrator.sh`
- **Network Tools**: `test_network.sh`, `fix_k3s_ports.sh`, `fix_port_6443.sh`
- **Resource Discovery**: `find-namespace-resource.sh`, `check_discovery.sh`
- **IoT-Specific**: `IOT_TROUBLESHOOTING.md` in edgemqttsim, `fix-mqtt-connection.sh`
- **Installation Logs**: Detailed logging in `linuxAIO_*.log` files

### Quality Assurance
- **WASM Filtering**: Real-time quality control filtering at the edge
- **Configurable Quality**: Defect rates and quality distributions in `message_structure.yaml`
- **Quality Metrics**: Good/scrap tracking with part and assembly IDs
- **OEE Support**: Messages structured to calculate Availability, Performance, and Quality metrics
- **State Tracking**: Machine state management for accurate availability calculations

## Avoid These Patterns
- Don't use plain MQTT without authentication
- Don't deploy without containerization
- Don't hardcode certificates or connection strings
- Don't ignore health check implementations
- Don't use deprecated MQTT v3.1.1 (prefer v5)

## When Helping with Code
1. Follow the established containerized deployment pattern
2. Use ServiceAccountToken authentication for in-cluster apps
3. Include proper error handling and logging
4. Add health check endpoints for web services
5. Follow the modular PowerShell deployment script pattern
6. Include comprehensive README documentation
7. Use `uv` for Python dependency management
8. Consider real-time processing requirements for IoT data