# Azure IoT Operations Asset Registration

## Overview

This directory contains asset definitions and registration guidance for Azure IoT Operations integration with factory simulation data. The **recommended approach** is to use the OPC UA bridge for full portal integration with asset registration, dashboards, and data flows.

## Recommended Approach: OPC UA Bridge Integration

### Why OPC UA Bridge?
- **Full Portal Integration**: Register assets in Azure IoT Operations portal
- **Asset Endpoints**: Create proper asset endpoints with `opc.tcp://` URLs
- **Rich Dashboards**: Use built-in Azure IoT Operations dashboards and analytics
- **Data Flows**: Configure data processing flows through the portal UI
- **Asset Management**: Complete asset lifecycle management through Azure portal

### Architecture
```
Factory MQTT Data → MQTT-to-OPC-UA Bridge → OPC UA Server → Azure IoT Operations Asset Endpoints
        ↓                      ↓                    ↓                        ↓
- Raw telemetry          - Protocol conversion   - OPC UA address space  - Portal asset registration
- MQTT v5 topics         - Data mapping          - Standardized nodes    - Dashboard integration
- JSON payloads          - Type conversion       - opc.tcp protocol      - Data flow configuration
```

## Factory Asset Categories

Based on the SpaceShip Factory simulation message structure:

### 1. Manufacturing Equipment Assets
- **CNC Manufacturing Stations**: CNC-01, CNC-02, CNC-03, CNC-04
  - Topics: `factory/cnc`
  - Parts: Hull panels, frame struts, engine mounts, wing sections, door panels

- **3D Printing Stations**: 3DP-01, 3DP-05, 3DP-07
  - Topics: `factory/3dprinter`
  - Parts: Gearbox casings, sensor mounts, pipe connectors, bracket assemblies, cooling fins

- **Welding Stations**: WELD-02, WELD-03, WELD-04, WELD-06
  - Topics: `factory/welding`
  - Operations: Hull welding, frame joining, component attachment

- **Painting Booths**: PAINT-01, PAINT-02, PAINT-05
  - Topics: `factory/painting`
  - Finishes: Primer, base coat, clear coat, specialty finishes

- **Testing Stations**: TEST-01, TEST-02, TEST-03
  - Topics: `factory/testing`
  - Tests: Pressure, electrical, mechanical, integration

### 2. Business Process Assets
- **Order Management System**: Customer order processing
- **Dispatch System**: Logistics and shipping coordination

## Implementation Workflow

### Phase 1: Deploy OPC UA Bridge
1. Deploy OPC PLC simulator (see `opc-ua-bridge.md`)
2. Configure MQTT-to-OPC-UA data mapping
3. Verify `opc.tcp://` endpoint accessibility

### Phase 2: Portal Configuration
1. Create Asset Endpoint in Azure IoT Operations portal
2. Register assets using provided definitions (see `asset-examples.md`)
3. Configure asset datapoints and events
4. Set up asset relationships and metadata

### Phase 3: Dashboard and Analytics
1. Configure dashboards in Azure IoT Operations portal
2. Set up data processing flows
3. Create alerts and monitoring rules
4. Implement OEE analytics and reporting

## Key Data Points

### Common Machine Metrics
- `machine_id`: Unique identifier
- `status`: running, idle, maintenance, faulted
- `quality`: good, rework, scrap
- `cycle_time`: Operation duration
- `parts_completed`: Production count
- `timestamp`: Event timestamp

### Specialized Metrics
- **3D Printers**: progress, layer_count, temperature
- **Welding**: power_level, wire_feed_rate, temperature
- **Painting**: pressure, flow_rate, humidity, temperature
- **Testing**: test_result, pressure_reading, voltage, torque

## OEE Calculations

The portal will automatically calculate Overall Equipment Effectiveness (OEE):

```
OEE = Availability × Performance × Quality

Where:
- Availability: Equipment uptime ratio
- Performance: Speed efficiency ratio  
- Quality: Good parts ratio
```

## Alternative: Direct MQTT Pipeline

If you prefer to bypass portal asset registration and work directly with MQTT data, see `../pipelines/mqtt-data-pipeline.md`. However, this approach does **not** provide:
- Portal asset registration
- Built-in Azure IoT Operations dashboards
- Asset lifecycle management through portal

## Integration Files

- `opc-ua-bridge.md` - Complete OPC UA server setup guide
- `asset-examples.md` - Ready-to-use asset definitions for portal registration
- `AZURE_ASSET_REGISTRATION.md` - Detailed asset registration procedures
- `ASSET_ENDPOINT_SETUP.md` - Asset endpoint configuration guide

## Getting Started

**Recommended Path (Full Portal Integration):**
1. Follow `opc-ua-bridge.md` to deploy OPC PLC simulator
2. Create Asset Endpoint with `opc.tcp://opc-plc-service.azure-iot-operations.svc.cluster.local:50000`
3. Register assets using definitions from `asset-examples.md`
4. Configure dashboards and data flows in Azure IoT Operations portal

This approach gives you the full Azure IoT Operations experience with portal-based asset management, built-in dashboards, and integrated data flow configuration.