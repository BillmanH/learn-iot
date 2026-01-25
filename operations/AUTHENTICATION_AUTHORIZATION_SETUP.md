# Edge Module Authentication & Authorization Setup

## Overview
This document describes the authentication and authorization setup for edge modules communicating with Azure IoT Operations MQTT broker.

## Authentication Method
**Kubernetes Service Account Token (SAT)** - Preferred method for in-cluster applications

### Service Account Configuration
- **Name**: `mqtt-client`
- **Namespace**: `default`
- **Annotation**: `aio-broker-auth/group=edge-apps`

### Create/Update Service Account
```bash
kubectl annotate serviceaccount mqtt-client -n default aio-broker-auth/group=edge-apps --overwrite
```

## Authorization Policy
**BrokerAuthorization Resource**: `edge-apps-authz`

### Policy Configuration
Located at: `operations/broker-authorization-edge-apps.yaml`

```yaml
apiVersion: mqttbroker.iotoperations.azure.com/v1
kind: BrokerAuthorization
metadata:
  name: edge-apps-authz
  namespace: azure-iot-operations
spec:
  authorizationPolicies:
    cache: Enabled
    rules:
      - principals:
          attributes:
            - group: "edge-apps"
        brokerResources:
          - method: Connect
          - method: Publish
            topics:
              - "factory/#"
              - "historian/#"
              - "telemetry/#"
          - method: Subscribe
            topics:
              - "factory/#"
              - "commands/#"
              - "config/#"
```

### Permissions Granted
**Connect**: All edge apps with `group=edge-apps` attribute can connect to the broker

**Publish to**:
- `factory/#` - Factory equipment messages
- `historian/#` - Historical data
- `telemetry/#` - Telemetry data

**Subscribe to**:
- `factory/#` - Factory equipment messages
- `commands/#` - Command messages
- `config/#` - Configuration updates

### Apply Authorization Policy
```bash
kubectl apply -f operations/broker-authorization-edge-apps.yaml
```

## Edge Module Configuration

### edgemqttsim Deployment
**Service Account**: Uses `mqtt-client` service account
**Authentication**: K8S-SAT with token mounted at `/var/run/secrets/tokens/broker-sat`
**Environment Variables**:
- `MQTT_AUTH_METHOD=K8S-SAT`
- `SAT_TOKEN_PATH=/var/run/secrets/tokens/broker-sat`
- `MQTT_HOST=aio-broker.azure-iot-operations.svc.cluster.local`
- `MQTT_PORT=18883`

### demohistorian Deployment
**Service Account**: Uses `mqtt-client` service account
**Authentication**: K8S-SAT with token mounted at `/var/run/secrets/tokens/broker-sat`
**Environment Variables**:
- Same SAT configuration as edgemqttsim

## Verification

### Check Service Account
```bash
kubectl get serviceaccount mqtt-client -n default -o yaml
```

### Check Authorization Policy
```bash
kubectl get brokerauthorization -n azure-iot-operations
```

### Check Edge Module Logs
```bash
# Check edgemqttsim
kubectl logs -n default -l app=edgemqttsim --tail=20

# Check demohistorian
kubectl logs -n default -l app=demohistorian -c historian --tail=20
```

### Expected Results
- edgemqttsim: Should show messages being published (e.g., "Batch 1231: Generated 2 messages")
- demohistorian: Should show messages being stored (e.g., "Stored 3700 messages")

## Troubleshooting

### Connection Denied
If edge modules cannot connect:
1. Verify service account annotation:
   ```bash
   kubectl describe serviceaccount mqtt-client -n default
   ```
2. Check if annotation includes `aio-broker-auth/group: edge-apps`

### Publish/Subscribe Denied
If connection works but publish/subscribe fails:
1. Check authorization policy is applied:
   ```bash
   kubectl get brokerauthorization edge-apps-authz -n azure-iot-operations -o yaml
   ```
2. Verify topic patterns match your application topics
3. Check broker frontend logs for authorization denials:
   ```bash
   kubectl logs -n azure-iot-operations -l app=aio-broker-frontend --tail=50
   ```

### Token Refresh
Service account tokens expire but are automatically refreshed by Kubernetes. Edge modules should:
- Reload token from `/var/run/secrets/tokens/broker-sat` on new connections
- Handle MQTT unauthorized errors by fetching latest token and reconnecting

## Reference Documentation
- [Configure MQTT Broker Authentication](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication)
- [Configure MQTT Broker Authorization](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-authorization)
- [Kubernetes Service Account Tokens](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/)

## Status
✅ **Service Account**: Configured with `group=edge-apps` annotation
✅ **Authorization Policy**: Created and applied
✅ **edgemqttsim**: Publishing factory messages successfully
✅ **demohistorian**: Storing messages successfully (3700+ messages)
