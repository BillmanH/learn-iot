# Local Testing Instructions for Edge Historian

## Prerequisites
- Python 3.11+
- PostgreSQL (or Docker)
- Access to MQTT broker (local or remote)

## Setup

### 1. Install Dependencies
```bash
cd iotopps/demohistorian
pip install -r requirements.txt
```

### 2. Start PostgreSQL (using Docker)
```bash
# Quick PostgreSQL container
docker run --name historian-postgres -d \
  -e POSTGRES_DB=mqtt_historian \
  -e POSTGRES_USER=historian \
  -e POSTGRES_PASSWORD=changeme \
  -p 5432:5432 \
  postgres:16-alpine

# Wait for it to start
sleep 5
```

### 3. Set Environment Variables

**Option A: For testing with LOCAL MQTT broker (Mosquitto)**
```bash
export POSTGRES_HOST=localhost
export POSTGRES_PORT=5432
export POSTGRES_DB=mqtt_historian
export POSTGRES_USER=historian
export POSTGRES_PASSWORD=changeme

# Use local Mosquitto broker (no authentication)
export MQTT_BROKER=localhost
export MQTT_PORT=1883
export MQTT_AUTH_METHOD=none  # Disable K8S-SAT for local testing
export LOG_LEVEL=DEBUG
```

**Option B: For testing with REMOTE AIO broker (via kubectl port-forward)**
```powershell
# In separate PowerShell window - forward AIO broker
kubectl port-forward -n azure-iot-operations svc/aio-broker 18883:18883

# Then set these:
$env:POSTGRES_HOST="localhost"
$env:POSTGRES_PASSWORD="changeme"
$env:MQTT_BROKER="localhost"
$env:MQTT_PORT="18883"
$env:MQTT_AUTH_METHOD="none"  # Can't use K8S-SAT locally
$env:LOG_LEVEL="DEBUG"
```

### 4. Run the Application
```bash
python app.py
```

You should see:
```
======================================================================
Edge Historian - Azure IoT Operations MQTT Message Historian
======================================================================

[1/3] Initializing database...
✓ Database connection pool created
✓ Database schema initialized

[2/3] Initializing MQTT subscriber...
✓ Connected to MQTT broker at localhost:1883
✓ Subscribed to topic: # (QoS 0)

[3/3] Starting cleanup task...
✓ All systems initialized
✓ HTTP API starting on 0.0.0.0:8080
======================================================================
```

### 5. Test the API

In another terminal:
```bash
# Health check
curl http://localhost:8080/health

# Get statistics
curl http://localhost:8080/api/v1/stats

# Publish test message (if using local Mosquitto)
mosquitto_pub -h localhost -t "factory/test" -m '{"machine_id":"TEST-01","status":"running","timestamp":"2026-01-12T10:00:00Z"}'

# Query the message
curl http://localhost:8080/api/v1/last-value/factory/test
```

## Simplified Local Testing (No MQTT)

If you just want to test the HTTP API and database:

### 1. Modify app.py temporarily
Comment out MQTT initialization in the `main()` function:

```python
# Initialize MQTT
# logger.info("\n[2/3] Initializing MQTT subscriber...")
# mqtt_subscriber = MQTTSubscriber(app_config, db_manager)
# mqtt_subscriber.initialize()
# mqtt_subscriber.connect()
```

### 2. Run with just HTTP API
```bash
python app.py
```

### 3. Manually insert test data
```bash
# Connect to database
docker exec -it historian-postgres psql -U historian -d mqtt_historian

# Insert test messages
INSERT INTO mqtt_history (timestamp, topic, payload, qos) VALUES
  (NOW(), 'factory/cnc', '{"machine_id":"CNC-01","status":"running","part_id":"P123"}', 0),
  (NOW(), 'factory/welding', '{"machine_id":"WELD-01","status":"idle"}', 0);

# Exit
\q
```

### 4. Test queries
```bash
curl http://localhost:8080/api/v1/last-value/factory/cnc
curl http://localhost:8080/api/v1/stats
```

## Using Local Mosquitto MQTT Broker

### Install Mosquitto
```bash
# macOS
brew install mosquitto
mosquitto

# Windows (via Chocolatey)
choco install mosquitto
```

### Start Mosquitto with no authentication
```bash
mosquitto -v
```

### Publish test messages
```bash
# Terminal 1: Subscribe to see all messages
mosquitto_sub -h localhost -t "#" -v

# Terminal 2: Publish test messages
mosquitto_pub -h localhost -t "factory/cnc" -m '{"machine_id":"CNC-01","status":"running","timestamp":"2026-01-12T10:00:00Z"}'
mosquitto_pub -h localhost -t "factory/welding" -m '{"machine_id":"WELD-01","status":"running","timestamp":"2026-01-12T10:00:05Z"}'
mosquitto_pub -h localhost -t "factory/3dprinter" -m '{"machine_id":"3DP-01","status":"running","progress":0.45,"timestamp":"2026-01-12T10:00:10Z"}'
```

## Cleanup

```bash
# Stop PostgreSQL container
docker stop historian-postgres
docker rm historian-postgres

# Stop Mosquitto
# Ctrl+C in the terminal
```

## Troubleshooting

### Database Connection Failed
```bash
# Check PostgreSQL is running
docker ps | grep historian-postgres

# Check logs
docker logs historian-postgres

# Verify connection
docker exec -it historian-postgres psql -U historian -d mqtt_historian -c "SELECT 1"
```

### MQTT Connection Failed
```bash
# Test Mosquitto is running
mosquitto_sub -h localhost -t "test" -v

# Check port is open
netstat -an | grep 1883  # Linux/Mac
netstat -an | findstr 1883  # Windows
```

### Module Import Errors
```bash
# Reinstall dependencies
pip install --upgrade -r requirements.txt

# Check Python version
python --version  # Should be 3.11+
```

## Notes

- Local testing **cannot use K8S-SAT authentication** (requires Kubernetes)
- For AIO broker testing, use `kubectl port-forward` but note TLS/auth limitations
- Best local testing: PostgreSQL (Docker) + Mosquitto (local) + app.py
- The app will automatically create the database schema on first run
