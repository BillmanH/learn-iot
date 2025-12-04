# WASM Quality Filter (Python)

A Python-based replacement for the WASM quality control filtering module. This service provides the same functionality with easier debugging and maintenance, including **Azure IoT Operations security protocols**.

## 📂 Files Overview

| File | Purpose | Description |
|------|---------|-------------|
| `app.py` | Main Application | Complete Python service with MQTT handling, quality filtering, and health endpoints |
| `requirements.txt` | Dependencies | Python package requirements |
| `Dockerfile` | Container Build | Multi-stage build for Python service |
| `deployment.yaml` | Kubernetes Deploy | Production deployment manifest with security and health checks |
| `config.yaml` | Configuration | YAML configuration file (optional, uses env vars by default) |
| `README.md` | Documentation | This file |

## 🔐 Security Features

This implementation follows **Azure IoT Operations security best practices**:

### Authentication
- **🔑 K8S-SAT Authentication**: Uses Kubernetes ServiceAccountToken for secure MQTT access
- **🏷️ Service Account**: Dedicated `mqtt-client` service account with appropriate permissions
- **🎫 Token Management**: Automatic token rotation with 24-hour expiration

### Encryption
- **🔒 TLS/SSL**: Encrypted MQTTS connection on port 18883
- **🛡️ Certificate Handling**: Configured for Azure IoT Operations self-signed certificates
- **🚫 Insecure Connections**: No plain-text MQTT communication

### Container Security
- **👤 Non-Root User**: Runs as non-privileged user (UID/GID 1000)
- **📁 Read-Only Filesystem**: Immutable container filesystem
- **⛔ Capability Dropping**: Removes all unnecessary Linux capabilities
- **🔒 Security Context**: Comprehensive pod and container security restrictions

## 🎯 Functionality

### Quality Filter Logic
- **Subscribes** to `azure-iot-operations/data/welding-stations`
- **Filters** messages where `quality == "scrap"` AND `cycle_time < 7.0` seconds
- **Publishes** alerts to `azure-iot-operations/alerts/quality-control`
- **Provides** health and metrics endpoints on port 8080

### Key Features
- ✅ **Structured Logging** with JSON output for easy parsing
- ✅ **Health Endpoints** for Kubernetes probes
- ✅ **Metrics Collection** for monitoring and observability
- ✅ **Configuration** via environment variables
- ✅ **Graceful Shutdown** handling
- ✅ **Error Handling** with retry logic
- ✅ **Type Safety** with Pydantic models

## 🏃 Quick Start

### Local Testing
```bash
# Install dependencies
pip install -r requirements.txt

# Set environment variables
export MQTT_BROKER="localhost"
export LOG_LEVEL="DEBUG"

# Run the service
python app.py
```

### Container Build
```bash
# Build container
docker build -t wasm-quality-filter-python:latest .

# Run container
docker run -p 8080:8080 \
  -e MQTT_BROKER="your-mqtt-broker" \
  -e LOG_LEVEL="INFO" \
  wasm-quality-filter-python:latest
```

## 🔧 Configuration

All configuration is done via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `MQTT_BROKER` | `aio-broker.azure-iot-operations.svc.cluster.local` | MQTT broker hostname |
| `MQTT_PORT` | `18883` | MQTTS broker port (encrypted) |
| `MQTT_CLIENT_ID` | `python-quality-filter` | MQTT client identifier |
| `MQTT_AUTH_METHOD` | `K8S-SAT` | Authentication method (K8S-SAT) |
| `SAT_TOKEN_PATH` | `/var/run/secrets/tokens/broker-sat` | ServiceAccountToken file path |
| `INPUT_TOPIC` | `azure-iot-operations/data/welding-stations` | Input topic to subscribe to |
| `OUTPUT_TOPIC` | `azure-iot-operations/alerts/quality-control` | Output topic for alerts |
| `HEALTH_PORT` | `8080` | Port for health and metrics endpoints |
| `LOG_LEVEL` | `INFO` | Logging level (DEBUG, INFO, WARNING, ERROR) |
| `QUALITY_THRESHOLD` | `scrap` | Quality value that triggers filtering |
| `CYCLE_TIME_THRESHOLD` | `7.0` | Maximum cycle time for quality issues |

## 📊 Endpoints

### Health Check
```bash
GET /health
```
Returns service health status and checks.

### Metrics
```bash
GET /metrics
```
Returns processing metrics and counters.

### Configuration
```bash
GET /config
```
Returns current configuration (non-sensitive values).

## 🔍 Message Flow

```
Welding Station → MQTT Broker → Python Filter → Quality Control Topic
                     ↓              ↓               ↓
              welding-stations  Filter Logic   quality-control
```

### Input Message Format
```json
{
  "machine_id": "LINE-1-STATION-C-01",
  "station_id": "STATION-C-01", 
  "operator_id": "OP001",
  "part_id": "WING-SECTION-A-001",
  "quality": "scrap",
  "last_cycle_time": 6.5,
  "temperature": 1650.0,
  "current": 220.0,
  "voltage": 24.5,
  "timestamp": "2024-12-03T10:30:45Z",
  "shift": "day",
  "maintenance_status": "normal"
}
```

### Output Alert Format
```json
{
  "alert_id": "qa_LINE-1-STATION-C-01_1701598245123",
  "machine_id": "LINE-1-STATION-C-01",
  "station_id": "STATION-C-01",
  "part_id": "WING-SECTION-A-001",
  "alert_type": "quality_control",
  "severity": "high",
  "description": "Quality issue detected: scrap part with fast cycle time (6.50s)",
  "trigger_conditions": {
    "quality": "scrap",
    "cycle_time": 6.5,
    "cycle_time_threshold": 7.0,
    "time_difference": 0.5
  },
  "original_message": { ... },
  "timestamp": "2024-12-03T10:30:45.123Z",
  "impact_assessment": {
    "production_impact": "medium",
    "recommendation": "Investigate machine speed and quality correlation",
    "priority": "high"
  }
}
```

## 🚀 Deployment

### GitHub Actions
The service will automatically deploy via the existing GitHub Actions pipeline:

- **Manual**: Actions → "Deploy IoT Edge Application" → Select `wasm-quality-filter-python`
- **Automatic**: Push changes to `dev` branch under `iotopps/wasm-quality-filter-python/`

### Manual Deployment
```bash
# Apply to Kubernetes
kubectl apply -f deployment.yaml

# Check deployment
kubectl get pods -l app=wasm-quality-filter-python
kubectl logs -l app=wasm-quality-filter-python -f
```

## 📈 Monitoring

### Health Checks
```bash
# Direct health check
curl http://localhost:8080/health

# Kubernetes health check
kubectl exec -it deployment/wasm-quality-filter-python -- curl http://localhost:8080/health
```

### Metrics
```bash
# Get metrics
curl http://localhost:8080/metrics

# Example response
{
  "messages_processed": 1524,
  "alerts_generated": 23,
  "errors_count": 0,
  "uptime_seconds": 3600.5,
  "last_message_timestamp": "2024-12-03T10:30:45.123Z"
}
```

### Logs
```bash
# View logs
kubectl logs -l app=wasm-quality-filter-python -f

# Example structured log output
{"level": "info", "logger": "mqtt_handler", "timestamp": "2024-12-03T10:30:45.123Z", "event": "Quality alert published", "alert_id": "qa_LINE-1-STATION-C-01_1701598245123"}
```

## 🐛 Troubleshooting

### Common Issues

**MQTT Connection Failed**
- Check `MQTT_BROKER` environment variable
- Verify network connectivity to broker on port 18883 (MQTTS)
- Check service account permissions for MQTT access
- Verify ServiceAccountToken is mounted at `/var/run/secrets/tokens/broker-sat`
- Check K8S-SAT authentication configuration

**Authentication Issues**
- Verify `mqtt-client` service account exists and is configured
- Check ServiceAccountToken audience matches broker configuration (`aio-internal`)
- Ensure token file is readable and not expired (24-hour rotation)
- Review MQTT v5 CONNACK error codes in logs

**No Messages Processing**
- Verify `INPUT_TOPIC` subscription
- Check MQTT broker topic configuration  
- Review structured logs for connection issues

**Alerts Not Publishing**
- Check `OUTPUT_TOPIC` configuration
- Verify MQTT publish permissions
- Review error counters in metrics

### Debug Mode
```bash
# Enable debug logging
export LOG_LEVEL=DEBUG
python app.py
```

### Local Testing with Mock MQTT
```bash
# Install mosquitto for testing
# Subscribe to output topic
mosquitto_sub -h localhost -t "azure-iot-operations/alerts/quality-control"

# Publish test message
mosquitto_pub -h localhost -t "azure-iot-operations/data/welding-stations" -m '{
  "machine_id": "TEST-01",
  "station_id": "TEST",
  "operator_id": "OP001", 
  "part_id": "TEST-PART",
  "quality": "scrap",
  "last_cycle_time": 5.0,
  "temperature": 1650.0,
  "current": 220.0,
  "voltage": 24.5,
  "timestamp": "2024-12-03T10:30:45Z",
  "shift": "day",
  "maintenance_status": "normal"
}'
```

## ✨ Advantages over WASM Version

- ✅ **Easier Debugging**: Standard Python debugging tools
- ✅ **Faster Development**: No compilation step required
- ✅ **Better Observability**: Rich structured logging
- ✅ **Simpler Dependencies**: No Rust toolchain required
- ✅ **Dynamic Configuration**: Environment variables without rebuild
- ✅ **Native JSON Handling**: Built-in JSON processing
- ✅ **Rich Ecosystem**: Leverage Python's extensive libraries

## 📄 License

MIT License - See LICENSE file for details