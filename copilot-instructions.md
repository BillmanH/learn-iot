# Copilot Instructions for Azure IoT Operations Learning Repository

## Project Overview
This repository is focused on learning and implementing Azure IoT Operations (AIO) on edge devices using Kubernetes (K3s). It contains containerized IoT applications, deployment automation, and simulation tools for industrial IoT scenarios.

## Repository Structure

### Core Directories
- **`iotopps/`** - IoT Operations applications (containerized apps for edge deployment)
- **`linux_build/`** - Azure IoT Operations setup scripts and K3s cluster configuration
- **`operations/`** - Azure operations and integration configurations
- **`devices/` & `certs/`** - Device management and certificate handling

### Key Applications
- **Sputnik** - MQTT publisher sending periodic "beep" messages for testing
- **Spaceship Factory Simulator** - Complex IoT simulation generating factory telemetry
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
- Include: `timestamp`, `machine_id`/`station_id`, `status`, telemetry data
- Support for quality metrics (good/scrap/rework) and OEE calculations

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

### Local Development
```bash
# Setup Python environment
uv sync

# Run application locally
.\Deploy-Local.ps1 -AppFolder "app-name" -Mode python
```

### Edge Deployment
```powershell
# Deploy to remote IoT Operations cluster
.\Deploy-ToIoTEdge.ps1 -AppFolder "app-name" -RegistryName "username"

# Check deployment status
.\Deploy-Check.ps1 -AppFolder "app-name"
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

### Industrial IoT Simulation
- Factory equipment telemetry (CNC, welding, painting)
- Quality control and OEE metrics
- Real-time data processing with WASM modules
- Integration with Microsoft Fabric for analytics

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
- K3s troubleshooting guide with diagnostic scripts
- IoT-specific troubleshooting documentation
- Network and port configuration helpers

### Quality Assurance
- WASM-based real-time quality filtering
- Factory simulation with configurable defect rates
- Quality metrics integration with telemetry data

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