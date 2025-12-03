# 🚀 SpaceShip Factory Simulator

A comprehensive IoT simulator for a spaceship manufacturing facility, designed to send realistic telemetry to Azure IoT Operations MQTT Broker.

## Overview

This simulator generates telemetry from multiple types of manufacturing equipment:
- **CNC Machines** - Precision part manufacturing
- **3D Printers** - Additive manufacturing for complex components
- **Welding Stations** - Assembly welding operations
- **Painting Booths** - Surface finishing operations
- **Testing Rigs** - Quality assurance and testing

Plus business events:
- **Customer Orders** - Order placement events
- **Dispatch Events** - Fulfillment and shipping notifications

## Architecture

The simulator is built with a modular architecture:

```
app.py                    # Main MQTT client application
messages.py               # Message generation logic
message_structure.yaml    # Configuration for message types and cadence
```

### Key Features

- **Configurable Message Patterns** - All message types, frequencies, and parameters defined in YAML
- **Realistic State Management** - Machines maintain state across cycles
- **K8S-SAT Authentication** - Native Kubernetes ServiceAccountToken authentication
- **MQTT v5 Support** - Modern MQTT protocol with enhanced features
- **Message Routing** - Intelligent topic routing based on message type
- **Queue Management** - Buffered message queue with overflow protection
- **Statistics Tracking** - Real-time monitoring of message throughput

## Message Topics

Messages are routed to different MQTT topics based on type:

| Topic | Description |
|-------|-------------|
| `factory/cnc` | CNC machine telemetry |
| `factory/3dprinter` | 3D printer telemetry |
| `factory/welding` | Welding station telemetry |
| `factory/painting` | Painting booth telemetry |
| `factory/testing` | Testing rig telemetry |
| `factory/orders` | Customer order events |
| `factory/dispatch` | Dispatch/fulfillment events |
| `factory/telemetry` | Default topic for other messages |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MQTT_BROKER` | `localhost` | MQTT broker hostname |
| `MQTT_PORT` | `18883` | MQTT broker port (MQTTS) |
| `MQTT_TOPIC_PREFIX` | `factory` | Topic prefix for all messages |
| `MQTT_CLIENT_ID` | `factory-sim-{pid}` | MQTT client identifier |
| `MQTT_AUTH_METHOD` | `K8S-SAT` | Authentication method |
| `SAT_TOKEN_PATH` | `/var/run/secrets/tokens/broker-sat` | Path to SAT token |
| `MESSAGE_CONFIG_PATH` | `message_structure.yaml` | Path to message config |
| `PYTHONUNBUFFERED` | `1` | Python output buffering |

### Message Configuration

The `message_structure.yaml` file controls all aspects of message generation:

- **Global Settings** - Base interval, machine counts
- **Message Types** - Enable/disable message types
- **Frequency Weights** - Relative frequency of each message type
- **Quality Distributions** - Percentage of good/bad parts
- **Status Distributions** - Machine operational states
- **Part/Assembly Types** - Product variety
- **Business Event Rates** - Orders and dispatches per hour

## Deployment

### Prerequisites

- Kubernetes cluster with Azure IoT Operations installed
- Service account `mqtt-client` with appropriate permissions
- Container registry access

### Build and Push

```bash
# Build the container
docker build -t <YOUR_REGISTRY>/spaceshipfactorysim:latest .

# Push to registry
docker push <YOUR_REGISTRY>/spaceshipfactorysim:latest
```

### Deploy to Kubernetes

1. Update `deployment.yaml` with your container registry
2. Apply the deployment:

```bash
kubectl apply -f deployment.yaml
```

### Register Assets in Azure IoT Operations

After deployment, register the factory assets in Azure IoT Operations for monitoring and management:

**📋 See the comprehensive guide: [AZURE_ASSET_REGISTRATION.md](./AZURE_ASSET_REGISTRATION.md)**

This guide provides:
- Complete asset definitions for all factory equipment
- Datapoint configurations and event mappings
- MQTT topic structure recommendations
- Step-by-step registration process

### Verify Deployment

```bash
# Check pod status
kubectl get pods -l app=spaceshipfactorysim

# View logs
kubectl logs -l app=spaceshipfactorysim -f

# Check MQTT messages (if you have a subscriber)
kubectl logs -l app=spaceshipfactorysim --tail=100
```

## OEE (Overall Equipment Effectiveness) Support

The simulator generates data to support OEE calculation:

### 🟢 Availability
- `status` field tracks machine state (running, idle, maintenance, faulted)
- `timestamp` enables uptime/downtime calculation
- Status distributions configurable per machine type

### 🟡 Performance
- `cycle_time` tracks actual operation duration
- Compare against configured `cycle_time_range` for ideal time
- `progress` field for 3D printers shows pacing

### 🔴 Quality
- `quality` field indicates part quality (good, scrap, rework)
- `test_result` from testing rigs (pass, fail)
- `issues_found` quantifies defects
- Quality distributions configurable per machine type

## Customization

### Adjust Message Frequency

Edit `message_structure.yaml`:

```yaml
global:
  base_interval: 1.0  # Seconds between generation cycles

message_types:
  cnc_machine:
    frequency_weight: 3  # Higher = more frequent
```

### Add New Machine Types

1. Define machine in `message_structure.yaml`
2. Add generation method in `messages.py`
3. Update topic routing in `app.py` if needed

### Change Quality Distributions

```yaml
message_types:
  cnc_machine:
    quality_distribution:
      good: 0.95   # 95% good parts
      scrap: 0.05  # 5% scrap
```

## Monitoring

The simulator outputs periodic statistics:

```
📊 Statistics (Uptime: 120s)
   Messages Sent: 450
   Messages Failed: 2
   Queue Depth: 5
   Message Rate: 3.75 msg/sec
```

## Troubleshooting

### Connection Issues

Check broker service:
```bash
kubectl get service -n azure-iot-operations aio-broker
```

Verify SAT token:
```bash
kubectl exec -it <pod-name> -- cat /var/run/secrets/tokens/broker-sat
```

### Message Not Appearing

1. Check topic subscriptions match the prefix
2. Verify QoS settings on subscriber
3. Check broker logs for errors

### Performance Issues

- Reduce `frequency_weight` values in config
- Increase `base_interval`
- Reduce machine counts
- Increase resource limits in deployment

## Architecture Diagram

```
┌─────────────────────────────────────────────────────┐
│  message_structure.yaml                             │
│  (Configuration)                                    │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│  messages.py                                        │
│  ├─ FactoryMessageGenerator                        │
│  ├─ Machine state management                       │
│  ├─ Message generation logic                       │
│  └─ Business event generation                      │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│  app.py                                             │
│  ├─ MQTT Client (K8S-SAT auth)                     │
│  ├─ Message queue management                       │
│  ├─ Topic routing                                  │
│  └─ Statistics & monitoring                        │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│  Azure IoT Operations MQTT Broker                  │
│  Topics: factory/cnc, factory/3dprinter, etc.      │
└─────────────────────────────────────────────────────┘
```

## References

- [Factory Simulation Spec](../../Factory_Simulation_Spec.md) - Detailed message specifications
- [Sputnik Module](../sputnik/) - Reference implementation for MQTT connectivity
- [Azure IoT Operations Documentation](https://learn.microsoft.com/azure/iot-operations/)

## License

See repository root for license information.
