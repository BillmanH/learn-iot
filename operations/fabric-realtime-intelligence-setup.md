# Azure IoT Operations to Fabric Real-Time Intelligence

This guide shows how to route MQTT messages from Azure IoT Operations directly to Microsoft Fabric Real-Time Intelligence for real-time monitoring, analytics, and visualization.

## Architecture

```
Azure IoT Operations MQTT Broker
  └─> Data Flow (filter/transform)
      └─> Fabric Real-Time Intelligence Endpoint
          └─> Event Stream (Fabric)
              └─> KQL Database (Real-Time Intelligence)
                  └─> Dashboards & Analytics
```

## Prerequisites

- Azure IoT Operations instance deployed and running
- Microsoft Fabric workspace (Premium capacity required)
- Azure subscription with permissions to create resources
- Sputnik (or other MQTT publishers) sending messages to the broker

## Step 1: Create Fabric Workspace and Event Stream

### 1.1 Create a Fabric Workspace

1. Go to [Microsoft Fabric](https://app.fabric.microsoft.com/)
2. Click **Workspaces** > **New workspace**
3. Name your workspace (e.g., `iot-operations-workspace`)
4. Select **Premium** capacity (required for Event Streams)
5. Click **Apply**

### 1.2 Create an Event Stream

1. In your Fabric workspace, click **+ New** > **Eventstream**
2. Name it (e.g., `iot-operations-stream`)
3. Click **Create**

### 1.3 Add Custom Endpoint as Source

1. In the Event Stream editor, click **Add source** > **Custom endpoint**
2. Configure the custom endpoint:
   - **Source name**: `iot-operations-data`
   - **Protocol**: Select **Kafka**
   - **Authentication**: Select **SASL** (recommended for production)
3. Click **Add**

### 1.4 Retrieve Connection Details

After creating the custom endpoint, you'll see the connection details:

**For SASL Authentication:**
- **Bootstrap server**: `<your-eventhub>.servicebus.windows.net:9093`
- **Topic name**: `es_<guid>` (format: `es_aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb`)
- **Connection string**: Copy the full connection string with primary key

**Save these values** - you'll need them in Step 2.

## Step 2: Create Azure IoT Operations Data Flow Endpoint

### 2.1 Create Kubernetes Secret for SASL Authentication

On your cluster, create a secret with the connection string:

```bash
kubectl create secret generic fabric-realtime-secret \
  -n azure-iot-operations \
  --from-literal=username='$ConnectionString' \
  --from-literal=password='<YOUR_CONNECTION_STRING_FROM_FABRIC>'
```

**Important**: 
- The username must be exactly `$ConnectionString` (literal string, not a variable)
- The password is the full connection string from Fabric

### 2.2 Apply the Fabric Endpoint Configuration

Apply the YAML file `fabric-realtime-endpoint.yaml`:

```bash
kubectl apply -f operations/fabric-realtime-endpoint.yaml
```

This creates a data flow endpoint named `fabric-realtime` that Azure IoT Operations will use to send data to Fabric.

### 2.3 Verify the Endpoint

```bash
kubectl get dataflowEndpoint fabric-realtime -n azure-iot-operations
```

You should see the endpoint in a `Running` state.

## Step 3: Create Data Flow to Route MQTT Messages

### 3.1 Apply the Data Flow Configuration

Apply the YAML file `fabric-realtime-dataflow.yaml`:

```bash
kubectl apply -f operations/fabric-realtime-dataflow.yaml
```

This creates a data flow that:
- Subscribes to all MQTT topics (`#`)
- Routes messages to the Fabric Real-Time Intelligence endpoint
- Applies transformations (optional)

### 3.2 Verify the Data Flow

```bash
kubectl get dataflow iot-to-fabric -n azure-iot-operations
```

## Step 4: Verify Data Flow in Fabric

### 4.1 Check Event Stream

1. Go back to your Event Stream in Fabric
2. Click on the custom endpoint source
3. Click **Data preview** and **Refresh**
4. You should see messages from Sputnik appearing in JSON format

### 4.2 Create KQL Database (Optional)

For advanced analytics and querying:

1. In your Fabric workspace, click **+ New** > **Eventhouse**
2. Name it (e.g., `iot-operations-eventhouse`)
3. Create a KQL database inside the Eventhouse
4. Add the Event Stream as a destination:
   - In Event Stream, click **Add destination** > **KQL Database**
   - Select your database and table

### 4.3 Query Your Data

In the KQL database, you can query your data:

```kql
// View all messages from last hour
MqttMessages
| where ingestion_time() > ago(1h)
| project timestamp, topic, payload
| order by timestamp desc

// Count messages by topic
MqttMessages
| summarize count() by topic

// Filter Sputnik beeps
MqttMessages
| where topic == "sputnik/beep"
| extend beep_count = toint(parse_json(payload).beep_count)
| project timestamp, beep_count, payload
```

## Step 5: Create Dashboards (Optional)

1. In your Fabric workspace, click **+ New** > **Real-Time Dashboard**
2. Add tiles with KQL queries to visualize your data
3. Examples:
   - **Time series chart**: Message volume over time
   - **Pie chart**: Messages by topic
   - **Scalar**: Latest beep count from Sputnik

## Troubleshooting

### No data appearing in Event Stream

1. **Check the dataflow endpoint**:
   ```bash
   kubectl describe dataflowEndpoint fabric-realtime -n azure-iot-operations
   ```

2. **Check the dataflow**:
   ```bash
   kubectl describe dataflow iot-to-fabric -n azure-iot-operations
   ```

3. **Check data flow pods**:
   ```bash
   kubectl logs -n azure-iot-operations -l app=aio-dataflow
   ```

4. **Verify MQTT messages are being published**:
   ```bash
   kubectl logs -n default -l app=sputnik
   ```

### Authentication errors

- Verify the secret contains the correct connection string
- Ensure username is exactly `$ConnectionString`
- Check that the connection string includes the primary key

### Connection errors

- Verify the bootstrap server hostname is correct
- Ensure port 9093 is accessible (check firewall rules)
- Verify TLS is enabled in the endpoint configuration

## Configuration Details

### MQTT Topics Monitored

By default, the data flow subscribes to **all topics** (`#`). To filter specific topics:

Edit `fabric-realtime-dataflow.yaml` and change the source topics:

```yaml
source:
  topics:
    - "sputnik/#"      # Only Sputnik messages
    - "devices/+/temp" # Temperature from all devices
```

### Data Transformation

To transform messages before sending to Fabric, add transformations:

```yaml
transformations:
  - type: Enrich
    enrichSettings:
      path: ".metadata"
      value: 
        cluster: "edge-cluster-01"
        location: "factory-floor"
```

## Next Steps

- **Add more publishers**: Deploy additional IoT devices or simulators
- **Create alerts**: Use Fabric Activator to trigger alerts on specific conditions
- **Build dashboards**: Visualize your real-time data with Power BI
- **Archive data**: Route data to OneLake for long-term storage
- **Machine learning**: Use Fabric ML capabilities for predictive analytics

## References

- [Azure IoT Operations Documentation](https://learn.microsoft.com/en-us/azure/iot-operations/)
- [Configure Fabric Real-Time Intelligence Endpoint](https://learn.microsoft.com/en-us/azure/iot-operations/connect-to-cloud/howto-configure-fabric-real-time-intelligence)
- [Microsoft Fabric Real-Time Intelligence](https://learn.microsoft.com/en-us/fabric/real-time-intelligence/)
- [Event Streams in Fabric](https://learn.microsoft.com/en-us/fabric/real-time-intelligence/event-streams/overview)
