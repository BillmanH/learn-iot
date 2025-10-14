# IoT Sending Device Setup Guide for Azure IoT Operations

## Overview
This guide outlines the steps to set up a Raspberry Pi device that generates telemetry signals using a modified version of `thermostat.py` and sends them via MQTT to Azure IoT Operations (AIO) instead of using Azure IoT Device messages.

## Prerequisites
- Working Raspberry Pi with Docker installed
- Azure IoT Operations (AIO) deployed on Ubuntu Server
- Local MQTT broker configured and accessible (if using local broker setup)
- Network connectivity between Raspberry Pi and AIO MQTT broker

## Architecture
```
Raspberry Pi (Docker Container) → Azure IoT Operations MQTT Broker → Event Grid → Data Lake/Analytics
```

## Step 1: Create MQTT-Enabled Thermostat Module

### 1.1 Create Modified Thermostat Class
Create a new file `mqtt_thermostat.py` that replaces Azure IoT Device messaging with MQTT:

```python
import time
import uuid
import json
import numpy as np
from paho.mqtt import client as mqtt


class MQTTThermostat:
    def __init__(self, aio_broker_host, aio_broker_port=1883, device_id=None, username=None, password=None):
        self.guid = str(uuid.uuid4())
        self.device_id = device_id or f"thermostat-{self.guid[:8]}"
        self.temperature = 65
        self.aio_broker_host = aio_broker_host
        self.aio_broker_port = aio_broker_port
        
        # MQTT client setup for AIO
        self.client = mqtt.Client(client_id=self.device_id)
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_publish = self._on_publish
        
        # Set credentials if provided (for AIO authentication)
        if username and password:
            self.client.username_pw_set(username, password)
        
        # Connect to AIO MQTT broker
        self.client.connect(self.aio_broker_host, self.aio_broker_port, 60)
        self.client.loop_start()
    
    def _on_connect(self, client, userdata, flags, rc):
        print(f"Device {self.device_id} connected to AIO with result code: {rc}")
    
    def _on_disconnect(self, client, userdata, rc):
        print(f"Device {self.device_id} disconnected from AIO with result code: {rc}")
    
    def _on_publish(self, client, userdata, mid):
        print(f"Device {self.device_id} sent message to AIO")
    
    def monitor_temp(self, bias=0):
        """Monitor temperature with optional bias for trending"""
        dieroll = np.random.normal() + bias
        if dieroll <= 0.5:
            self.temperature -= 1
        else:
            self.temperature += 1
    
    def post_data(self, topic="azure-iot-operations/data/thermostat"):
        """Send temperature data via MQTT to AIO"""
        message_data = {
            "device_id": self.device_id,
            "temperature": self.temperature,
            "timestamp": time.time(),
            "guid": self.guid,
            "message_type": "telemetry"
        }
        
        message_json = json.dumps(message_data)
        result = self.client.publish(topic, message_json)
        
        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            print(f"Temperature data sent to AIO: {self.temperature}°F")
        else:
            print(f"Failed to send data to AIO: {result.rc}")
    
    def sleep(self, n):
        time.sleep(n)
    
    def disconnect(self):
        """Clean disconnect from AIO MQTT broker"""
        self.client.loop_stop()
        self.client.disconnect()
```

### 1.2 Environment Configuration
Create a `config.yaml` file for device configuration:

```yaml
aio_mqtt:
  broker_host: "192.168.1.XXX"  # Your AIO MQTT broker IP (Ubuntu Server)
  broker_port: 1883
  username: "aio-user"  # AIO MQTT username (if authentication required)
  password: "aio-password"  # AIO MQTT password (if authentication required)
  topics:
    telemetry: "azure-iot-operations/data/thermostat"
    status: "azure-iot-operations/status/thermostat"
    commands: "azure-iot-operations/commands/thermostat"

device:
  id: "rpi-thermostat-001"
  update_interval: 5  # seconds
  temperature_bias: 0.0  # bias for temperature trending
  
aio_config:
  edge_location: "factory-floor"
  asset_group: "hvac-systems"
  asset_type: "thermostat"
```

## Step 2: Create Docker Container

### 2.1 Application File
Create `app.py` for the containerized application:

```python
import time
import yaml
import signal
import sys
from mqtt_thermostat import MQTTThermostat


def signal_handler(sig, frame):
    print('Shutting down gracefully...')
    if 'device' in globals():
        device.disconnect()
    sys.exit(0)


def main():
    # Load configuration
    with open('config.yaml', 'r') as file:
        config = yaml.safe_load(file)
    
    # Setup signal handling for graceful shutdown
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Initialize device for AIO
    global device
    device = MQTTThermostat(
        aio_broker_host=config['aio_mqtt']['broker_host'],
        aio_broker_port=config['aio_mqtt']['broker_port'],
        device_id=config['device']['id'],
        username=config['aio_mqtt'].get('username'),
        password=config['aio_mqtt'].get('password')
    )
    
    print(f"Starting AIO IoT device: {config['device']['id']}")
    print(f"Connecting to AIO at: {config['aio_mqtt']['broker_host']}:{config['aio_mqtt']['broker_port']}")
    
    try:
        while True:
            # Monitor temperature
            device.monitor_temp(bias=config['device']['temperature_bias'])
            
            # Send telemetry to AIO
            device.post_data(topic=config['aio_mqtt']['topics']['telemetry'])
            
            # Wait before next reading
            device.sleep(config['device']['update_interval'])
            
    except KeyboardInterrupt:
        print("Received interrupt signal")
    finally:
        device.disconnect()


if __name__ == "__main__":
    main()
```

### 2.2 Dependencies Installation
Install required Python packages directly in the container:

```bash
pip install paho-mqtt==1.6.1 numpy==1.21.0 pyyaml==6.0
```

### 2.3 Dockerfile
Create `Dockerfile`:

```dockerfile
FROM python:3.9-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies directly
RUN pip install --no-cache-dir \
    paho-mqtt==1.6.1 \
    numpy==1.21.0 \
    pyyaml==6.0

# Copy application files
COPY . .

# Create non-root user for security
RUN useradd -m -u 1001 iotuser
USER iotuser

# Run the application
CMD ["python3", "app.py"]
```

### 2.4 Docker Compose (Optional)
Create `docker-compose.yml` for easier management:

```yaml
version: '3.8'

services:
  mqtt-thermostat:
    build: .
    container_name: rpi-thermostat
    restart: unless-stopped
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    environment:
      - PYTHONUNBUFFERED=1
    networks:
      - iot-network

networks:
  iot-network:
    driver: bridge
```

## Step 3: Deployment Steps

### 3.1 Prepare Raspberry Pi Directory Structure
```bash
mkdir -p ~/iot-thermostat
cd ~/iot-thermostat
```

### 3.2 Copy Files to Raspberry Pi
Transfer the following files to the Raspberry Pi:
- `mqtt_thermostat.py`
- `app.py`
- `config.yaml` (with your AIO Ubuntu Server IP address and credentials)
- `Dockerfile`
- `docker-compose.yml` (optional)

### 3.3 Update Configuration
Edit `config.yaml` with your specific AIO settings:
- Replace `192.168.1.XXX` with your AIO Ubuntu Server IP address
- Update username/password for AIO MQTT authentication (if required)
- Adjust device ID, update interval, and MQTT topics as needed

### 3.4 Build and Run Container

#### Option A: Using Docker directly
```bash
# Build the image
docker build -t rpi-thermostat .

# Run the container
docker run -d \
  --name rpi-thermostat \
  --restart unless-stopped \
  -v $(pwd)/config.yaml:/app/config.yaml:ro \
  rpi-thermostat
```

#### Option B: Using Docker Compose
```bash
docker-compose up -d
```

## Step 4: Verification and Testing

### 4.1 Check Container Status
```bash
# Check if container is running
docker ps

# Check container logs
docker logs rpi-thermostat -f
```

### 4.2 Test MQTT Connectivity to AIO
On your Ubuntu Server running AIO, monitor the MQTT broker for incoming messages:

```bash
# If using mosquitto client on AIO server
mosquitto_sub -v -t 'azure-iot-operations/data/thermostat'

# Or use AIO-specific monitoring tools
kubectl get mqttbroker -n azure-iot-operations
kubectl logs -n azure-iot-operations deployment/aio-mq-dmqtt-frontend
```

You should see JSON messages with temperature data from your Raspberry Pi.

### 4.3 Monitor Device Performance
```bash
# Check container resource usage
docker stats rpi-thermostat

# Access container shell for debugging
docker exec -it rpi-thermostat /bin/bash
```

## Step 5: Integration with Azure IoT Operations

### 5.1 AIO Asset Discovery and Management
Configure your device as an AIO asset for better management:

```bash
# Connect to your AIO Ubuntu Server
kubectl apply -f - <<EOF
apiVersion: deviceregistry.microsoft.com/v1beta1
kind: Asset
metadata:
  name: rpi-thermostat-001
  namespace: azure-iot-operations
spec:
  assetEndpointProfileRef: thermostat-profile
  attributes:
    manufacturer: "Custom"
    model: "RaspberryPi-Thermostat"
    deviceType: "Thermostat"
  tags:
    location: "factory-floor"
    department: "hvac"
EOF
```

### 5.2 AIO Topic Structure
Recommended AIO MQTT topic structure:
- `azure-iot-operations/data/thermostat` - Temperature readings
- `azure-iot-operations/status/thermostat` - Device status messages  
- `azure-iot-operations/commands/thermostat` - Command topic (for future bidirectional communication)
- `azure-iot-operations/alerts/thermostat` - Alert messages

### 5.3 AIO Message Format
Standard JSON message format for AIO:
```json
{
  "device_id": "rpi-thermostat-001",
  "temperature": 72,
  "timestamp": 1634567890.123,
  "guid": "12345678-1234-1234-1234-123456789012",
  "message_type": "telemetry",
  "asset_metadata": {
    "location": "factory-floor",
    "asset_type": "thermostat",
    "edge_location": "factory-floor"
  }
}
```

### 5.4 Data Processing Pipeline
Configure AIO data processing:

```yaml
# aio-dataflow.yaml
apiVersion: connectivity.iotoperations.azure.com/v1beta1
kind: Dataflow
metadata:
  name: thermostat-dataflow
  namespace: azure-iot-operations
spec:
  profileRef: default-dataflow-profile
  operations:
    - operationType: source
      sourceSettings:
        endpointRef: aio-mq-endpoint
        dataSources:
          - azure-iot-operations/data/thermostat
    - operationType: transform
      transformSettings:
        datasets:
          - key: temperature
            expression: .temperature
          - key: device_id  
            expression: .device_id
          - key: timestamp
            expression: .timestamp
    - operationType: destination
      destinationSettings:
        endpointRef: event-grid-endpoint
```

## Step 6: Maintenance and Monitoring

### 6.1 Log Management
```bash
# View recent logs
docker logs rpi-thermostat --tail 50

# Follow logs in real-time
docker logs rpi-thermostat -f
```

### 6.2 Updates and Restarts
```bash
# Stop container
docker stop rpi-thermostat

# Update code and rebuild
docker build -t rpi-thermostat .

# Restart with new image
docker run -d \
  --name rpi-thermostat \
  --restart unless-stopped \
  -v $(pwd)/config.yaml:/app/config.yaml:ro \
  rpi-thermostat
```

### 6.3 Backup Configuration
Regularly backup your configuration files and any persistent data.

## Troubleshooting

### Common Issues:
1. **AIO MQTT Connection Failed**: Check network connectivity and AIO broker IP address
2. **Authentication Error**: Verify AIO MQTT username/password in config.yaml
3. **Container Won't Start**: Check Docker logs for Python errors
4. **No Data in AIO**: Verify MQTT topic names and AIO dataflow configuration
5. **High CPU Usage**: Adjust update interval in configuration

### Debug Commands:
```bash
# Test MQTT connectivity to AIO from Raspberry Pi
mosquitto_pub -h [AIO_SERVER_IP] -t 'azure-iot-operations/test' -m 'test message'

# Check AIO MQTT broker status
kubectl get mqttbroker -n azure-iot-operations
kubectl describe mqttbroker aio-mq-dmqtt-frontend -n azure-iot-operations

# Check AIO dataflow status
kubectl get dataflow -n azure-iot-operations
kubectl logs -n azure-iot-operations deployment/aio-dataflow-processor

# Check network connectivity
ping [AIO_SERVER_IP]

# Check Docker network
docker network ls
docker network inspect bridge
```

### AIO-Specific Troubleshooting:
```bash
# Check AIO overall status
kubectl get pods -n azure-iot-operations

# Monitor AIO MQTT logs
kubectl logs -n azure-iot-operations deployment/aio-mq-dmqtt-frontend -f

# Check asset registry
kubectl get assets -n azure-iot-operations

# Verify dataflow processing
kubectl logs -n azure-iot-operations deployment/aio-dataflow-processor -f
```

## Security Considerations
- Use strong authentication for AIO MQTT broker
- Implement TLS encryption for MQTT communication with AIO
- Run containers with non-root users
- Regularly update base images and dependencies
- Implement proper firewall rules
- Use AIO's built-in security features and role-based access control (RBAC)
- Configure proper network policies in Kubernetes

## Future Enhancements
- Add bidirectional communication using AIO command topics
- Implement device health monitoring through AIO asset management
- Add data persistence for offline scenarios
- Create AIO dashboards for device monitoring using Grafana integration
- Implement automatic device discovery through AIO asset endpoints
- Configure alerting rules in AIO for temperature thresholds
- Set up data export to Azure Data Lake or Event Grid for analytics