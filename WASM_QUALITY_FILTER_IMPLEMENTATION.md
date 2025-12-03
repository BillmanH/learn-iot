# WASM Quality Filter Module Implementation Plan

## Overview
This document outlines the implementation of a WebAssembly (WASM) module for real-time quality control filtering in the spaceship factory IoT system. The module will filter welding messages based on specific quality and timing criteria, then emit quality control flags.

## Current Infrastructure Analysis

### Existing Setup
- **Azure IoT Operations** running on K3s cluster (`bel-aio-work-cluster`)
- **Resource Group**: `IoT-Operations-Work-Edge-bel-aio`
- **Namespace**: `msft-aiocust-sandbox-edgevm-1`
- **Registry**: Uses Docker Hub or ACR (configurable via GitHub Actions)
- **Message Flow**: MQTT → Azure IoT Operations Data Flow → Processing

### Current Data Flow Architecture
```
Spaceship Factory Simulator → MQTT Broker → Azure IoT Operations Data Flow → Fabric/Processing
                             (Topics: azure-iot-operations/data/welding-stations)
```

### Welding Message Structure
Based on `message_structure.yaml`, welding messages include:
- `quality`: ["good", "scrap", "rework"]
- `last_cycle_time`: Range [6.0, 10.0] seconds
- `status`: ["running", "idle", "cooling", "faulted"]
- `assembly_type`, `assembly_id`, `station_id`

## WASM Module Design

### Module Requirements
**Filter Logic**: 
- **Input**: Welding telemetry messages
- **Condition**: `quality == "scrap" AND cycle_time < 7.0`
- **Output**: Quality control flag message

### Technology Stack
- **Runtime**: WasmTime or Wasmcloud
- **Language**: Rust (for WASM compilation)
- **Integration**: Azure IoT Operations Dataflow with custom processor
- **Deployment**: Container-based deployment to K3s cluster

## Implementation Structure

### Repository Organization
```
iotopps/
├── wasm-quality-filter/
│   ├── src/
│   │   ├── lib.rs              # Main WASM module logic
│   │   ├── message_parser.rs   # JSON message parsing
│   │   └── filter_logic.rs     # Quality control filter implementation
│   ├── Cargo.toml             # Rust dependencies and WASM target
│   ├── build.sh               # Build script for WASM compilation
│   ├── Dockerfile             # Container for WASM runtime
│   ├── deployment.yaml        # K8s deployment manifest
│   ├── dataflow.yaml          # Azure IoT Operations dataflow config
│   └── README.md              # Module documentation
```

### Message Flow Architecture (Proposed)
```
Factory Simulator → MQTT → Azure IoT Operations → WASM Quality Filter → Quality Control Topic
                                                ↓
                                            Fabric RTI (existing)
```

## Step-by-Step Implementation Plan

### Phase 1: WASM Module Development
1. **Initialize Rust Project**
   ```bash
   cd iotopps/
   cargo new --lib wasm-quality-filter
   cd wasm-quality-filter
   ```

2. **Configure for WASM Target**
   - Add `wasm32-wasi` target to Cargo.toml
   - Implement filter logic with timely dataflow concepts
   - Create message parsing for JSON telemetry

3. **Implement Filter Logic**
   ```rust
   // Pseudo-code structure
   pub fn process_welding_message(input: &str) -> Option<String> {
       let message = parse_json(input)?;
       if message.quality == "scrap" && message.cycle_time < 7.0 {
           Some(generate_quality_flag(message))
       } else {
           None
       }
   }
   ```

### Phase 2: Container Runtime Environment
1. **Create WASM Runtime Container**
   - Base image: `wasmtime/wasmtime` or `rust:slim`
   - Include MQTT client capabilities
   - Subscribe to welding station topics

2. **Message Processing Flow**
   ```
   MQTT Subscribe → JSON Parse → WASM Filter → MQTT Publish
   (welding-stations)              ↓           (quality-control)
                               FILTER LOGIC
   ```

### Phase 3: Azure IoT Operations Integration

#### Option A: Custom Dataflow Processor
```yaml
apiVersion: connectivity.iotoperations.azure.com/v1
kind: Dataflow
metadata:
  name: welding-quality-filter
  namespace: azure-iot-operations
spec:
  operations:
    - operationType: Source
      name: welding-source
      sourceSettings:
        endpointRef: default
        dataSources:
          - "azure-iot-operations/data/welding-stations"
    
    - operationType: Transform  # This is where WASM integration would go
      name: quality-filter
      transformSettings:
        # Custom processor configuration for WASM module
        
    - operationType: Destination
      name: quality-alerts
      destinationSettings:
        endpointRef: default
        dataDestination: "azure-iot-operations/alerts/quality-control"
```

#### Option B: Sidecar Container Pattern
- Deploy WASM runtime as sidecar container
- Direct MQTT subscription/publication
- Independent of Azure IoT Operations dataflow

### Phase 4: Deployment Strategy

#### Registry and Build Process
Following existing patterns:
```powershell
# Build WASM module
cd iotopps/wasm-quality-filter
./build.sh

# Build container
docker build -t <YOUR_REGISTRY>/wasm-quality-filter:latest .

# Deploy using existing infrastructure
.\Deploy-ToIoTEdge.ps1 -AppFolder "wasm-quality-filter" -RegistryName "your-registry"
```

#### Deployment Configuration
```yaml
# deployment.yaml (following existing patterns)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wasm-quality-filter
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wasm-quality-filter
  template:
    metadata:
      labels:
        app: wasm-quality-filter
    spec:
      serviceAccountName: mqtt-client  # Reuse existing service account
      containers:
      - name: wasm-quality-filter
        image: <YOUR_REGISTRY>/wasm-quality-filter:latest
        env:
        - name: MQTT_BROKER
          value: "aio-broker.azure-iot-operations.svc.cluster.local"
        - name: INPUT_TOPIC
          value: "azure-iot-operations/data/welding-stations"
        - name: OUTPUT_TOPIC
          value: "azure-iot-operations/alerts/quality-control"
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
```

## Technical Implementation Details

### WASM Module Interface
```rust
// lib.rs - Main module interface
#[no_mangle]
pub extern "C" fn process_message(input_ptr: *const u8, input_len: usize) -> i32 {
    // Message processing logic
}

#[no_mangle]
pub extern "C" fn get_result(output_ptr: *mut u8, output_len: usize) -> i32 {
    // Return processed result
}
```

### Message Schema
**Input (Welding Message)**:
```json
{
  "machine_id": "LINE-1-STATION-C-01",
  "timestamp": "2025-12-02T15:30:00Z",
  "status": "running",
  "last_cycle_time": 6.5,
  "quality": "scrap",
  "assembly_type": "FrameAssembly",
  "assembly_id": "FA-001-2025-001",
  "station_id": "LINE-1-STATION-C"
}
```

**Output (Quality Control Flag)**:
```json
{
  "alert_type": "quality_control",
  "source_machine": "LINE-1-STATION-C-01",
  "timestamp": "2025-12-02T15:30:00Z",
  "trigger_conditions": {
    "quality": "scrap",
    "cycle_time": 6.5,
    "threshold": 7.0
  },
  "assembly_details": {
    "type": "FrameAssembly",
    "id": "FA-001-2025-001"
  },
  "severity": "medium",
  "recommended_action": "investigate_welding_parameters"
}
```

### Performance Considerations
- **Memory**: WASM modules are lightweight (~KB size)
- **Latency**: Sub-millisecond processing time expected
- **Throughput**: Design for 100+ messages/second
- **Resource Usage**: Minimal CPU/memory footprint

## Testing Strategy

### Unit Testing
1. **WASM Module Tests**
   ```bash
   cd wasm-quality-filter
   cargo test --target wasm32-wasi
   ```

2. **Message Processing Tests**
   - Test filter conditions (scrap + cycle_time < 7)
   - Test message parsing and generation
   - Test edge cases and error handling

### Integration Testing
1. **Local Development**
   ```powershell
   .\Deploy-Local.ps1 -AppFolder "wasm-quality-filter"
   ```

2. **Mock Message Testing**
   - Inject test welding messages
   - Verify quality control flag generation
   - Monitor MQTT topics

### Production Testing
1. **Deploy to Development Environment**
   ```powershell
   .\Deploy-ToIoTEdge.ps1 -AppFolder "wasm-quality-filter" -RegistryName "your-registry"
   ```

2. **Monitor Quality Control Alerts**
   ```bash
   # Monitor quality control topic
   kubectl logs -l app=wasm-quality-filter -n default -f
   ```

## Monitoring and Observability

### Metrics to Track
- **Messages Processed**: Total welding messages analyzed
- **Alerts Generated**: Number of quality control flags sent
- **Filter Hit Rate**: Percentage of messages triggering alerts
- **Processing Latency**: Time from message receipt to alert generation
- **Module Health**: WASM runtime status and resource usage

### Logging Strategy
```rust
// Structured logging within WASM module
log::info!("Quality alert triggered: machine={}, cycle_time={}", 
           machine_id, cycle_time);
```

### Dashboard Integration
- Add quality control metrics to existing Fabric RTI dashboard
- Create alerts for unusual quality patterns
- Track welding station performance correlation

## Deployment Checklist

### Pre-Deployment
- [ ] WASM module compiled and tested
- [ ] Container image built and pushed to registry
- [ ] Deployment YAML configured with correct registry
- [ ] Service account permissions verified
- [ ] MQTT broker connectivity tested

### Deployment Steps
1. [ ] Build and push container image
2. [ ] Apply Kubernetes deployment manifest
3. [ ] Verify pod startup and health
4. [ ] Test MQTT topic subscription/publication
5. [ ] Inject test messages and verify output
6. [ ] Monitor logs for processing confirmation

### Post-Deployment
- [ ] Verify integration with existing factory simulation
- [ ] Monitor quality control alert patterns
- [ ] Validate performance metrics
- [ ] Document operational procedures

## Future Enhancements

### Advanced Filtering
- Machine learning-based anomaly detection
- Multi-parameter correlation analysis
- Predictive quality assessment

### Scalability
- Horizontal scaling for high-throughput scenarios
- Redis-based state management for complex filters
- Kafka integration for enterprise messaging

### Integration Expansion
- Integration with maintenance scheduling systems
- Automated workflow triggers
- Real-time dashboard notifications

## Risk Assessment

### Technical Risks
- **WASM Runtime Stability**: Mitigation through thorough testing
- **Message Processing Latency**: Performance monitoring and optimization
- **MQTT Connectivity Issues**: Implement retry logic and circuit breakers

### Operational Risks
- **False Positive Alerts**: Fine-tune filter thresholds through analysis
- **Resource Consumption**: Monitor and limit resource usage
- **Deployment Complexity**: Leverage existing infrastructure patterns

## Success Criteria

### Functional Requirements
- [x] Filter welding messages correctly (quality="scrap" AND cycle_time < 7)
- [x] Generate appropriate quality control alerts
- [x] Integrate with existing MQTT infrastructure
- [x] Deploy using standard container deployment process

### Performance Requirements
- [ ] Process messages with < 10ms latency
- [ ] Handle 100+ messages/second throughput
- [ ] Maintain < 50MB memory footprint
- [ ] Achieve 99.9% uptime

### Integration Requirements
- [x] Compatible with existing Azure IoT Operations setup
- [x] Uses established registry and deployment patterns
- [x] Integrates with current monitoring infrastructure
- [x] Follows existing security and authentication patterns

---

**Next Steps**: 
1. Review and approve this implementation plan
2. Create the WASM module directory structure
3. Begin Phase 1: WASM Module Development
4. Set up local testing environment
5. Implement and test core filtering logic

This plan leverages your existing infrastructure while introducing modern WASM-based edge processing capabilities for real-time quality control in your spaceship factory simulation.