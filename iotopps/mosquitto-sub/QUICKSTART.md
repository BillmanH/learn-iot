# Mosquitto Subscriber Quick Start

## What is this?

Mosquitto-sub is a simple MQTT message viewer that lets you see messages being published to the Azure IoT Operations MQTT broker in real-time.

## Quick Deploy

### 1. Automatic Deployment (Recommended)

Push to the `dev` branch and GitHub Actions will automatically deploy both Sputnik and mosquitto-sub:

```bash
git add iotopps/mosquitto-sub/
git commit -m "Add mosquitto subscriber"
git push origin dev
```

### 2. Manual Deployment

If you have kubectl access to the cluster:

```bash
kubectl apply -f deployment.yaml
```

## View Messages

Once deployed, view the incoming messages:

```bash
kubectl logs -n default -l app=mosquitto-sub -f
```

You should see Sputnik's beep messages and any other MQTT messages:

```
==================================================
Mosquitto MQTT Subscriber
==================================================

Configuration:
  Broker: aio-broker.azure-iot-operations.svc.cluster.local:18883
  Topic: #
  QoS: 1
  Auth: K8S-SAT (ServiceAccountToken)

Connecting to broker...

sputnik/beep {"timestamp": "2024-10-28T10:15:30Z", "beep_number": 1, "message": "beep!"}
devices/sensor-01/temp {"value": 22.5, "unit": "celsius"}
sputnik/beep {"timestamp": "2024-10-28T10:15:35Z", "beep_number": 2, "message": "beep!"}
myapp/status {"status": "running"}
```

## Change Subscribed Topic

By default, mosquitto-sub listens to **ALL topics** (`#`). To filter to specific topics:

### Method 1: Edit deployment.yaml

1. Open `deployment.yaml`
2. Find the `MQTT_TOPIC` environment variable
3. Change the value:
   ```yaml
   - name: MQTT_TOPIC
     value: "your/new/topic"  # Change this
   ```
4. Redeploy:
   ```bash
   kubectl apply -f deployment.yaml
   ```

### Method 2: Use kubectl set env

```bash
kubectl set env deployment/mosquitto-sub MQTT_TOPIC="new/topic" -n default
```

## Common Topics to Monitor

### Monitor All Topics (Default)
```yaml
- name: MQTT_TOPIC
  value: "#"
```

### Monitor Only Sputnik
```yaml
- name: MQTT_TOPIC
  value: "sputnik/beep"
```

### Monitor All Sputnik Topics
```yaml
- name: MQTT_TOPIC
  value: "sputnik/#"
```

### Monitor All Device Telemetry
```yaml
- name: MQTT_TOPIC
  value: "devices/+/telemetry"
```

### Monitor Everything (Verbose!)
```yaml
- name: MQTT_TOPIC
  value: "#"
```
**Note:** This is now the default - you'll see ALL messages!

## MQTT Topic Wildcards

- `+` = Single-level wildcard (e.g., `devices/+/temp` matches `devices/device1/temp`, `devices/device2/temp`)
- `#` = Multi-level wildcard (e.g., `sputnik/#` matches `sputnik/beep`, `sputnik/status/online`)

## Troubleshooting

### No messages appearing?

1. Check if mosquitto-sub is running:
   ```bash
   kubectl get pods -n default -l app=mosquitto-sub
   ```

2. Check the logs for errors:
   ```bash
   kubectl logs -n default -l app=mosquitto-sub
   ```

3. Verify Sputnik is publishing:
   ```bash
   kubectl logs -n default -l app=sputnik --tail=20
   ```

4. Check topic name matches:
   - Sputnik publishes to: `sputnik/beep`
   - Mosquitto-sub subscribes to: Check `MQTT_TOPIC` in deployment

### Connection errors?

See the detailed [TROUBLESHOOTING.md](TROUBLESHOOTING.md) guide.

### Want to test with a different publisher?

Deploy another app that publishes to a different topic, then update mosquitto-sub's `MQTT_TOPIC` to match.

## Architecture

```
┌─────────────┐         ┌──────────────────┐
│   Sputnik   │-------->│   AIO MQTT       │
│  Publisher  │ publish │    Broker        │
└─────────────┘         └────────┬─────────┘
                                 │
                                 │ subscribe
                                 │
                         ┌───────▼──────────┐
                         │  Mosquitto-Sub   │
                         │    Subscriber    │
                         └──────────────────┘
```

## What's Next?

- **Add more publishers**: Create other IoT apps that publish to different topics
- **Filter messages**: Use topic wildcards to view specific message types
- **Process messages**: Add a Python app that subscribes and processes messages
- **Forward to cloud**: Configure Azure IoT Operations data flows

## Files

- `deployment.yaml` - Kubernetes deployment manifest
- `README.md` - Full documentation
- `TROUBLESHOOTING.md` - Detailed troubleshooting guide
- `QUICKSTART.md` - This file

## Learn More

- [Full README](README.md) - Complete documentation
- [Troubleshooting Guide](TROUBLESHOOTING.md) - Solve common issues
- [Sputnik Publisher](../sputnik/README.md) - The message sender
