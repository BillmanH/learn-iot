# Quick MQTT Subscriber Pod for AIO Testing

A fast way to verify MQTT messages are flowing through the AIO broker without external tools.

## Quick Subscriber (Interactive)

Run a temporary pod that subscribes to a topic and displays messages:

```bash
# Subscribe to a specific topic
kubectl run mqtt-sub --rm -it --restart=Never \
  --image=eclipse-mosquitto:latest \
  -n azure-iot-operations \
  -- mosquitto_sub -h aio-broker -p 18883 -t "historian/health" -v

# Subscribe to all topics under a prefix
kubectl run mqtt-sub --rm -it --restart=Never \
  --image=eclipse-mosquitto:latest \
  -n azure-iot-operations \
  -- mosquitto_sub -h aio-broker -p 18883 -t "factory/#" -v

# Subscribe to ALL topics (verbose - lots of output)
kubectl run mqtt-sub --rm -it --restart=Never \
  --image=eclipse-mosquitto:latest \
  -n azure-iot-operations \
  -- mosquitto_sub -h aio-broker -p 18883 -t "#" -v
```

**Flags:**
- `--rm`: Delete pod when you exit (Ctrl+C)
- `-it`: Interactive terminal
- `--restart=Never`: Don't restart if it exits
- `-v`: Verbose (shows topic name with each message)

## Quick Publisher (Testing)

Send a test message to verify the broker is working:

```bash
# Send a single test message
kubectl run mqtt-pub --rm -it --restart=Never \
  --image=eclipse-mosquitto:latest \
  -n azure-iot-operations \
  -- mosquitto_pub -h aio-broker -p 18883 -t "test/hello" -m '{"msg":"hello from test pod"}'
```

## Using k9s to Monitor

1. Open k9s: `k9s -n azure-iot-operations`
2. Watch dataflow processing:
   - Type `/dataflow` to filter pods
   - Select `aio-dataflow-default-0`
   - Press `l` for logs
3. Watch broker activity:
   - Type `/broker` to filter
   - Select `aio-broker-*` pods
   - Press `l` for logs

## Dataflow Worker Logs

Check if the dataflow is processing messages:

```bash
# View recent dataflow activity
kubectl logs -n azure-iot-operations aio-dataflow-default-0 --tail=50

# Follow logs in real-time
kubectl logs -n azure-iot-operations aio-dataflow-default-0 -f

# Filter for specific dataflow
kubectl logs -n azure-iot-operations aio-dataflow-default-0 -f | grep "health-flow"
```

## Create a Local Test Dataflow

Route messages from one topic to another on the local broker:

### Via Portal
1. Go to [iotoperations.azure.com](https://iotoperations.azure.com)
2. Create a new dataflow:
   - Source: `default` endpoint, topic `data/health`
   - Destination: `default` endpoint, topic `test/health-copy`

### Via CLI
```bash
az iot ops dataflow create \
  --name test-local-flow \
  --instance bel-aio-work-cluster-aio \
  -g IoT-Operations-Work-Edge-bel-aio \
  --profile default \
  --source-endpoint default \
  --source-asset-or-topic "data/health" \
  --destination-endpoint default \
  --destination-topic "test/health-copy"
```

## Troubleshooting

### Pod can't connect to broker
```bash
# Check broker service exists
kubectl get svc -n azure-iot-operations | grep broker

# Check broker pods are running
kubectl get pods -n azure-iot-operations | grep broker
```

### No messages appearing
```bash
# Verify topic has traffic (check dataflow logs)
kubectl logs -n azure-iot-operations aio-dataflow-default-0 --tail=100 | grep -i "message\|topic"

# Check if source is publishing
kubectl logs -n azure-iot-operations <source-pod> --tail=20
```

### Wildcard Topics
- `#` matches all levels: `factory/#` matches `factory/cnc/1` and `factory/welding/2/status`
- `+` matches one level: `factory/+/status` matches `factory/cnc/status` but not `factory/cnc/1/status`
