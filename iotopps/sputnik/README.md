# Sputnik - MQTT Beeper

Sputnik is a simple IoT application that sends periodic "beep" messages to an MQTT broker. It's designed to be deployed to your Azure IoT Operations Kubernetes cluster on an edge device.

## 🛰️ What Does It Do?

Sputnik continuously publishes JSON messages to an MQTT topic with the following format:

```json
{
  "message": "beep",
  "timestamp": "2025-10-20T12:34:56.789Z",
  "hostname": "sputnik-pod-xyz",
  "beep_count": 42
}
```

## 🚀 Quick Start

### Prerequisites

- An MQTT broker running in your Kubernetes cluster
- Docker registry access (Docker Hub or Azure Container Registry)
- Kubernetes cluster with kubectl configured

### Local Development.

To test locally before deploying:

**Windows:**
```cmd
run-local.bat
```

**Linux/Mac:**
```bash
chmod +x run-local.sh
./run-local.sh
```

**Note:** Make sure you have an MQTT broker running locally (e.g., Mosquitto on localhost:1883)

### Deploy to IoT Edge

1. **Edit the configuration file** `sputnik_config.json`:
   ```json
   {
     "registry": {
       "type": "dockerhub",
       "name": "your-docker-username"
     },
     "mqtt": {
       "broker": "mqtt-broker-service",
       "port": 1883,
       "topic": "sputnik/beep"
     }
   }
   ```

2. **Build and push the Docker image**:
   ```bash
   docker build -t your-registry/sputnik:latest .
   docker push your-registry/sputnik:latest
   ```

3. **Update deployment.yaml** with your registry name and MQTT broker details

4. **Deploy to Kubernetes**:
   ```bash
   kubectl apply -f deployment.yaml
   ```

## ⚙️ Configuration

### Finding Your MQTT Broker Service Name

Before deploying, you need to find your MQTT broker's service name in the cluster.

#### Using k9s (Recommended)

1. **Launch k9s**:
   ```bash
   k9s
   ```

2. **Navigate to Services**:
   - Press `:` to open the command prompt
   - Type `svc` and press Enter
   - Or press `:services` and Enter

3. **Find your MQTT broker**:
   - Look for services with names like:
     - `mqtt-broker`
     - `mosquitto`
     - `aio-mq-dmqtt-frontend` (Azure IoT Operations)
     - `emqx`
   - Note the **NAME** column (this is your `MQTT_BROKER` value)
   - Note the **PORT(S)** column (typically `1883` for MQTT)

4. **Get service details**:
   - Navigate to your MQTT service using arrow keys
   - Press `d` to describe the service
   - Look for the port and namespace information

#### Using kubectl

**List all services**:
```bash
kubectl get svc --all-namespaces
```

**Search for MQTT services**:
```bash
kubectl get svc --all-namespaces | grep -i mqtt
```

**Get service details**:
```bash
kubectl describe svc <service-name> -n <namespace>
```

**Common MQTT service patterns**:
- `mqtt-broker-service`
- `mosquitto-service`
- `aio-mq-dmqtt-frontend` (for Azure IoT Operations)
- `emqx-service`

#### Example Configuration

If k9s shows a service named `aio-mq-dmqtt-frontend` in namespace `azure-iot-operations` on port `1883`:

```json
{
  "mqtt": {
    "broker": "aio-mq-dmqtt-frontend.azure-iot-operations.svc.cluster.local",
    "port": 1883,
    "topic": "sputnik/beep"
  }
}
```

**Note**: For services in different namespaces, use the full DNS name:
`<service-name>.<namespace>.svc.cluster.local`

For services in the same namespace as Sputnik, you can use just the service name:
`<service-name>`

### Environment Variables

- `MQTT_BROKER`: MQTT broker hostname (default: `localhost`)
- `MQTT_PORT`: MQTT broker port (default: `1883`)
- `MQTT_TOPIC`: Topic to publish to (default: `sputnik/beep`)
- `MQTT_CLIENT_ID`: MQTT client identifier (default: `sputnik`)
- `BEEP_INTERVAL`: Seconds between beeps (default: `5`)

### Deployment Configuration

Edit `deployment.yaml` to customize:
- MQTT broker connection details
- Beep interval
- Resource limits
- Number of replicas

## 📊 Monitoring

### View Logs

```bash
kubectl logs -l app=sputnik -f
```

### Check Status

```bash
kubectl get pods -l app=sputnik
kubectl describe deployment sputnik
```

### Subscribe to MQTT Messages

Using mosquitto_sub:
```bash
mosquitto_sub -h <mqtt-broker-host> -t "sputnik/beep"
```

## 🔧 Troubleshooting

### Connection Issues

If Sputnik can't connect to the MQTT broker:

1. Verify the MQTT broker service is running:
   ```bash
   kubectl get svc | grep mqtt
   ```

2. Check the broker hostname in deployment.yaml matches your MQTT service name

3. Verify network connectivity from the pod:
   ```bash
   kubectl exec -it <sputnik-pod> -- ping mqtt-broker-service
   ```

### View Application Logs

```bash
kubectl logs -l app=sputnik --tail=50
```

## 🎯 Use Cases

- **Testing MQTT Infrastructure**: Verify your MQTT broker is working correctly
- **IoT Edge Simulation**: Simulate simple IoT devices sending telemetry
- **Monitoring**: Use as a heartbeat signal to monitor edge connectivity
- **Load Testing**: Deploy multiple replicas to test MQTT broker capacity

## 📦 Docker Image

The application uses:
- Python 3.11 slim base image
- `uv` for fast package installation
- `paho-mqtt` for MQTT communication

Image size: ~150MB

## 🔐 Security Notes

- The current configuration uses unencrypted MQTT (port 1883)
- For production, consider using MQTT over TLS (port 8883)
- Add authentication credentials if your MQTT broker requires them

## 📝 License

This is a demonstration application for IoT Edge learning purposes.
