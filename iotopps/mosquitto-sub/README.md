# Mosquitto Subscriber

A simple MQTT subscriber pod that listens to topics on the Azure IoT Operations MQTT broker.

## Purpose

This pod allows you to:
- Subscribe to MQTT topics and view messages in real-time
- Test and verify that publishers (like Sputnik) are working correctly
- Debug MQTT message flow in your Azure IoT Operations deployment
- Monitor specific topics for troubleshooting

## Features

- ✅ **ServiceAccountToken (K8S-SAT) Authentication** - Same as Sputnik
- ✅ **Subscribes to any topic** - Configurable via environment variable
- ✅ **Real-time message display** - See messages as they arrive
- ✅ **Verbose output** - Shows topic name with each message
- ✅ **Automatic reconnection** - Built into mosquitto_sub

## Quick Start

### 1. Deploy the Subscriber

The subscriber is automatically deployed via GitHub Actions when you push to the `dev` branch.

Or deploy manually:
```bash
kubectl apply -f deployment.yaml
```

### 2. View the Messages

Check the pod logs to see incoming messages:
```bash
kubectl logs -n default -l app=mosquitto-sub -f
```

You should see messages from Sputnik and any other publishers appearing like:
```
sputnik/beep {"timestamp": "2024-10-28T...", "beep_number": 1, "message": "beep!"}
devices/sensor-01/temperature {"value": 22.5, "unit": "celsius"}
myapp/status {"status": "running"}
```

### 3. Subscribe to Specific Topics

To monitor only specific topics, update the `MQTT_TOPIC` environment variable in `deployment.yaml`:

```yaml
env:
- name: MQTT_TOPIC
  value: "your/topic/here"  # Change this
```

Use wildcards:
- `sputnik/#` - All topics under sputnik/
- `#` - All topics (careful, can be very verbose!)
- `devices/+/telemetry` - All device telemetry

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MQTT_BROKER` | `aio-broker.azure-iot-operations.svc.cluster.local` | MQTT broker hostname |
| `MQTT_PORT` | `18883` | MQTT broker port (TLS) |
| `MQTT_TOPIC` | `#` | Topic to subscribe to (default: all topics) |
| `MQTT_QOS` | `1` | Quality of Service level (0, 1, or 2) |

### Service Account

Uses the same `mqtt-client` service account as Sputnik for authentication.

## Architecture

```
┌─────────────────────┐
│  mosquitto-sub Pod  │
│                     │
│  ┌──────────────┐   │
│  │ mosquitto_sub│   │
│  │   client     │   │
│  └──────┬───────┘   │
│         │           │
│    ┌────▼─────┐     │
│    │ K8S-SAT  │     │
│    │  Token   │     │
│    └──────────┘     │
└──────────┬──────────┘
           │
           │ TLS + SAT Auth
           │
    ┌──────▼───────┐
    │  AIO MQTT    │
    │   Broker     │
    └──────────────┘
```

## Files

- `deployment.yaml` - Kubernetes deployment manifest
- `Dockerfile` - Container image (uses official eclipse-mosquitto)
- `README.md` - This file
- `TROUBLESHOOTING.md` - Common issues and solutions

## Deployment via GitHub Actions

This subscriber is automatically deployed when:
1. You push changes to the `dev` branch
2. GitHub Actions workflow runs
3. The workflow applies `deployment.yaml` to your Arc-enabled cluster

No Docker image build needed - uses the official `eclipse-mosquitto` image from Docker Hub.

## Common Use Cases

### 1. Verify Sputnik is Publishing

```bash
# Default deployment subscribes to sputnik/beep
kubectl logs -n default -l app=mosquitto-sub -f
```

### 2. Monitor All Device Messages

Update `deployment.yaml`:
```yaml
- name: MQTT_TOPIC
  value: "devices/#"
```

### 3. Debug Specific Device

```yaml
- name: MQTT_TOPIC
  value: "devices/device-123/telemetry"
```

### 4. Monitor Everything (use carefully!)

```yaml
- name: MQTT_TOPIC
  value: "#"
```

## Security

- **Authentication**: Uses Kubernetes ServiceAccountToken (K8S-SAT)
- **Encryption**: TLS 1.2+ for all connections
- **Authorization**: Limited to topics allowed by BrokerAuthorization policies
- **Token Lifecycle**: Automatically renewed by Kubernetes every 24 hours

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues.

Quick checks:
```bash
# Check if pod is running
kubectl get pods -n default -l app=mosquitto-sub

# View logs
kubectl logs -n default -l app=mosquitto-sub --tail=50

# Check service account
kubectl get serviceaccount mqtt-client -n default

# Verify broker is accessible
kubectl get service -n azure-iot-operations aio-broker
```

## Differences from Sputnik

| Feature | Sputnik | Mosquitto-Sub |
|---------|---------|---------------|
| **Purpose** | Publisher | Subscriber |
| **Language** | Python | Shell (mosquitto_sub) |
| **Image** | Custom built | Official eclipse-mosquitto |
| **Sends Messages** | ✅ Yes | ❌ No |
| **Receives Messages** | ❌ No | ✅ Yes |
| **Use Case** | IoT device simulator | Message monitoring/debugging |

## Next Steps

- View messages: `kubectl logs -n default -l app=mosquitto-sub -f`
- Change topic: Edit `MQTT_TOPIC` in `deployment.yaml`
- Add more subscribers: Copy and rename deployment with different topics
- Set up alerts: Forward logs to Azure Monitor

## References

- [Mosquitto Documentation](https://mosquitto.org/man/mosquitto_sub-1.html)
- [Azure IoT Operations MQTT Broker](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/)
- [K8S ServiceAccountToken Auth](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication#kubernetes-service-account-tokens)
