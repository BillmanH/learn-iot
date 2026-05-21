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
   - **Source name**: `iot-operations-data` (or any name you prefer)
   - Click **Add** (this creates the endpoint with just the name)
3. After the endpoint is created, click **Publish** in the Event Stream editor
4. Once published, click on the custom endpoint to configure protocol and authentication

### 1.4 Configure Protocol and Authentication

After publishing the endpoint, configure the connection protocol:

1. Click on the custom endpoint you just created
2. Select **Protocol**: **Kafka**
3. Select **Authentication**: **Microsoft Entra ID** (Managed Identity)

4. Copy the connection details that appear:
   - **Bootstrap server**: (e.g., `<namespace>.servicebus.windows.net:9093`)
   - **Topic name**: `es_<guid>` (format: `es_aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb`)

**Save these values** — you'll need them when creating the dataflow endpoint in the Azure Portal.

> **No credentials to copy**: With Managed Identity, Azure IoT Operations authenticates using its system-assigned identity. There are no keys, connection strings, or Kubernetes secrets to manage.

## Step 2: Create Azure IoT Operations Dataflow Endpoint

All configuration is done in the **Azure Portal** — no YAML files or `kubectl` commands required.

### 2.1 Open the AIO Instance in the Azure Portal

1. Navigate to your Azure IoT Operations instance in the [Azure Portal](https://portal.azure.com)
2. Select **Dataflow endpoints** from the left menu
3. Click **+ Create endpoint**

### 2.2 Configure the Kafka Endpoint

1. **Endpoint type**: Kafka
2. **Name**: `fabric-endpoint` (or any descriptive name)
3. **Bootstrap server**: paste the bootstrap server from step 1.4 (e.g., `<namespace>.servicebus.windows.net:9093`)
4. **Authentication**: System-assigned managed identity
5. **TLS**: Enabled
6. Leave other settings at their defaults (or configure as needed)
7. Click **Create**

> No secrets or credentials are needed — the AIO managed identity is automatically used for authentication.

### 2.3 Verify the Endpoint

After creation, the endpoint should appear as **Running** in the portal. You can also check via CLI:

```bash
kubectl get dataflowEndpoint fabric-endpoint -n azure-iot-operations
```

## Step 3: Create a Dataflow to Route MQTT Messages

Create the dataflow in the **Azure Portal** alongside the endpoint.

### 3.1 Create the Dataflow

1. In your AIO instance, select **Dataflows** from the left menu
2. Click **+ Create dataflow**
3. **Name**: `factory-to-fabric` (or descriptive name)
4. **Source**: MQTT broker (default endpoint), topics: `factory/#` (or `#` for all topics)
5. **Destination**: select the `fabric-endpoint` you created in Step 2
6. **Data destination (topic/entity)**: paste the Fabric topic name from step 1.4 (e.g., `es_aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb`)
7. Click **Create**

### 3.2 Verify the Dataflow

```bash
kubectl get dataflow factory-to-fabric -n azure-iot-operations
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

- Confirm the AIO instance has a system-assigned managed identity enabled (Azure Portal → AIO instance → Identity)
- Confirm the managed identity has sufficient permissions on the Fabric Event Stream resource
- Check that the bootstrap server and topic name are correct

### Connection errors

- Verify the bootstrap server hostname is correct (from Fabric Kafka protocol details)
- Ensure the port in the bootstrap server is accessible (check firewall rules)
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
