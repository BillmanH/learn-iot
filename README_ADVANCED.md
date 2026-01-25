# Azure IoT Operations - Advanced Guide

Comprehensive technical documentation for Azure IoT Operations deployment, troubleshooting, and operations.

## Table of Contents

- [Detailed Installation](#detailed-installation)
- [Certificate Management](#certificate-management)
- [Creating Assets and Dataflows](#creating-assets-and-dataflows)
- [Deploying Edge Applications](#deploying-edge-applications)
- [Monitoring and Observability](#monitoring-and-observability)
- [Fabric Integration](#fabric-integration)
- [Troubleshooting](#troubleshooting)
- [Advanced Topics](#advanced-topics)

---

## Detailed Installation

### Phase 1: Edge Device Setup

The `linux_installer.sh` script automates the full edge infrastructure setup:

```bash
cd linux_build

# Optional: Customize configuration
cp linux_aio_config.template.json linux_aio_config.json
# Edit linux_aio_config.json with your settings

# Run installer
bash linux_installer.sh
```

#### What linux_installer.sh Does

1. **System Preparation**
   - Validates Ubuntu 24.04+ environment
   - Installs system dependencies (curl, jq, unzip)
   - Configures network settings

2. **K3s Installation**
   - Installs K3s v1.34.3+k3s1 (or latest stable)
   - Configures kubeconfig at `~/.kube/config`
   - Sets up containerd runtime

3. **Kubernetes Tools**
   - kubectl (matches K3s version)
   - Helm v3 (latest stable)
   - Optional: k9s, mqtt-viewer, mqttui (if enabled in config)

4. **CSI Secret Store Driver**
   - Installs CSI driver for Kubernetes secrets
   - Deploys Azure Key Vault provider (for Arc-connected clusters)

5. **Output Generation**
   - Creates `edge_configs/cluster_info.json` with:
     - Cluster name and FQDN
     - Resource group information
     - Kubeconfig data
     - System information

#### Configuration Options

Edit `linux_aio_config.json`:

```json
{
  "subscription_id": "your-subscription-id",
  "resource_group": "IoT-Operations",
  "cluster_name": "iot-ops-cluster",
  "location": "eastus",
  "optional_tools": {
    "k9s": true,
    "mqtt_viewer": false,
    "mqttui": true
  },
  "edge_modules": {
    "edgemqttsim": true,
    "demohistorian": true,
    "sputnik": false
  },
  "fabric_integration": {
    "enabled": true,
    "event_stream_connection_string": ""
  }
}
```

**Important Notes:**
- Script may trigger system restart for kernel updates
- After restart, rerun the script - it will continue from where it left off
- Installation takes ~10-15 minutes on typical hardware

### Phase 2: Azure Configuration

The `External-Configurator.ps1` script connects the edge cluster to Azure and deploys AIO:

```powershell
# From Windows machine with Azure CLI
az login

cd linux_build
.\External-Configurator.ps1 -ConfigFile ".\edge_configs\cluster_info.json"
```

#### What External-Configurator.ps1 Does

1. **Azure Arc Connection**
   - Registers cluster with Azure Arc
   - Enables OIDC issuer (required for workload identity)
   - Enables custom locations and cluster-connect features
   - Creates Arc extensions namespace

2. **Resource Group Setup**
   - Creates or validates resource group
   - Configures location-specific settings
   - Sets up RBAC permissions

3. **Azure IoT Operations Deployment**
   - Deploys AIO instance via Arc extension
   - Configures MQTT broker and frontend
   - Sets up Schema Registry
   - Deploys dataflow processors

4. **Secret Management**
   - Creates managed identity for Key Vault access
   - Configures SecretProviderClass
   - **Arc Cluster Workaround**: Detects Arc clusters and shows manual secret creation steps (CSI secret sync doesn't work on Arc without full workload identity infrastructure)

5. **Asset Synchronization**
   - Deploys ARM templates from `arm_templates/` directory
   - Creates assets in Azure Device Registry
   - Configures MQTT endpoints

#### Arc Cluster Authentication Notes

**⚠️ Known Issue**: Azure Key Vault CSI driver requires full workload identity infrastructure on Arc-connected clusters, which is complex to configure. The script detects this and provides manual workaround steps.

**Manual Secret Creation Workaround**:

```powershell
# Connect to cluster
az connectedk8s proxy --name iot-ops-cluster --resource-group IoT-Operations

# In separate terminal, create secret manually
kubectl create secret generic fabric-connection-string `
  --from-literal=username='$ConnectionString' `
  --from-literal=password='<your-connection-string>'
```

See [BUG_REPORT_FABRIC_ENDPOINT_DEPLOYMENT.md](operations/BUG_REPORT_FABRIC_ENDPOINT_DEPLOYMENT.md) for full details.

---

## Certificate Management

### Importing Certificates

Certificates are stored base64-encoded in the `certs/` directory.

#### Add New Certificate

```bash
# Encode certificate
base64 -w 0 mycert.pem > certs/mycert.base64

# Import to Kubernetes
kubectl create secret tls my-tls-secret \
  --cert=<(base64 -d certs/mycert.base64) \
  --key=<(base64 -d certs/mykey.base64) \
  -n azure-iot-operations
```

#### Using Certificates in Applications

Reference in deployment YAML:

```yaml
spec:
  containers:
  - name: myapp
    volumeMounts:
    - name: tls-cert
      mountPath: /etc/ssl/certs
      readOnly: true
  volumes:
  - name: tls-cert
    secret:
      secretName: my-tls-secret
```

### Service Account Token (SAT) Authentication

**Preferred method** for in-cluster MQTT authentication:

```bash
# Run setup script
cd iotopps
bash setup-sat-auth.sh
```

This creates:
- ServiceAccount with MQTT permissions
- Token for authentication
- BrokerAuthorization rules

**Using SAT in Python**:

```python
import paho.mqtt.client as mqtt

# Read token
with open('/var/run/secrets/tokens/mqtt-client-token', 'r') as f:
    token = f.read().strip()

client = mqtt.Client(protocol=mqtt.MQTTv5)
client.username_pw_set("K8S-SAT", token)
client.connect("aio-broker", 18883)
```

### X.509 Certificate Authentication

For external clients:

```bash
# Generate client certificate (if needed)
openssl req -new -x509 -days 365 -key client-key.pem -out client-cert.pem

# Configure broker listener for X.509
kubectl apply -f operations/broker-listener-external.yaml
```

See [CERT_MANAGEMENT.md](iotopps/CERT_MANAGEMENT.md) for complete guide.

---

## Creating Assets and Dataflows

### MQTT Assets

#### Method 1: ARM Templates (Recommended)

ARM templates provide declarative, version-controlled asset definitions.

```powershell
# Deploy asset via ARM template
az deployment group create `
  --resource-group IoT-Operations `
  --template-file linux_build/arm_templates/mqtt-asset.json `
  --parameters location=eastus `
               assetName=cnc-machine-01 `
               endpointProfile=/subscriptions/.../endpointProfiles/mqtt-endpoint
```

**Example ARM Template** (`linux_build/arm_templates/mqtt-asset.json`):

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "assetName": { "type": "string" },
    "location": { "type": "string" },
    "endpointProfile": { "type": "string" }
  },
  "resources": [
    {
      "type": "Microsoft.DeviceRegistry/assets",
      "apiVersion": "2024-09-01-preview",
      "name": "[parameters('assetName')]",
      "location": "[parameters('location')]",
      "extendedLocation": {
        "type": "CustomLocation",
        "name": "[concat('/subscriptions/', subscription().subscriptionId, '/resourceGroups/', resourceGroup().name, '/providers/Microsoft.ExtendedLocation/customLocations/aio-custom-location')]"
      },
      "properties": {
        "assetEndpointProfileRef": "[parameters('endpointProfile')]",
        "dataPoints": [
          {
            "name": "temperature",
            "dataSource": "factory/cnc/temperature",
            "dataPointConfiguration": "{\"samplingInterval\":1000}"
          },
          {
            "name": "cycle_time",
            "dataSource": "factory/cnc/cycle_time",
            "dataPointConfiguration": "{\"samplingInterval\":5000}"
          }
        ]
      }
    }
  ]
}
```

#### Method 2: Kubernetes Manifests

For edge-only deployments:

```yaml
apiVersion: deviceregistry.microsoft.com/v1beta1
kind: Asset
metadata:
  name: cnc-machine-01
  namespace: azure-iot-operations
spec:
  displayName: "CNC Machine 01"
  assetEndpointProfileRef: mqtt-endpoint
  dataPoints:
  - name: temperature
    dataSource: factory/cnc/temperature
    dataPointConfiguration: '{"samplingInterval":1000}'
```

Apply:
```bash
kubectl apply -f asset.yaml
```

**Important**: Assets created via kubectl won't appear in Azure Portal (no ARM annotations).

### Creating Dataflows

Dataflows route messages between sources and destinations (MQTT, Fabric, ADX, etc.).

#### MQTT to Fabric Dataflow

**Example** (`operations/fabric-factory-dataflows.yaml`):

```yaml
apiVersion: connectivity.iotoperations.azure.com/v1beta1
kind: Dataflow
metadata:
  name: factory-to-fabric
  namespace: azure-iot-operations
spec:
  profileRef: default
  mode: Enabled
  operations:
  - operationType: Source
    sourceSettings:
      endpointRef: default
      dataSources:
      - factory/+/+  # All factory topics
  
  - operationType: Destination
    destinationSettings:
      endpointRef: fabric-endpoint
      dataDestination: es_e526de3f-6433-4a35-8f07-521f30abe1c5  # EntityPath from connection string
```

**Deploy**:
```bash
kubectl apply -f operations/fabric-factory-dataflows.yaml
```

#### Fabric Endpoint Configuration

**Prerequisites**:
1. Create Fabric Event Stream in Microsoft Fabric
2. Get connection string (includes EntityPath)
3. Create Kubernetes secret with connection string

**Extract EntityPath from Connection String**:

```powershell
$connString = "Endpoint=sb://....servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...;EntityPath=es_abc123xyz"

# Extract EntityPath
if ($connString -match 'EntityPath=([^;]+)') {
    $entityPath = $matches[1]
    Write-Host "Use this as dataDestination: $entityPath"
}
```

**Create Secret**:

```bash
kubectl create secret generic fabric-connection-string \
  --from-literal=username='$ConnectionString' \
  --from-literal=password='<full-connection-string>' \
  -n azure-iot-operations
```

**Create Endpoint**:

```yaml
apiVersion: connectivity.iotoperations.azure.com/v1beta1
kind: DataflowEndpoint
metadata:
  name: fabric-endpoint
  namespace: azure-iot-operations
spec:
  endpointType: Kafka
  kafkaSettings:
    host: esehmtcyb1tve3fs2la76yiy.servicebus.windows.net:9093
    authentication:
      method: Sasl
      saslSettings:
        saslType: Plain
        secretRef: fabric-connection-string
    tls:
      mode: Enabled
```

**Verify Data Flow**:

```bash
# Check dataflow status
kubectl get dataflow -n azure-iot-operations

# View dataflow logs
kubectl logs -n azure-iot-operations -l app=aio-dataflow-processor --tail=50

# Check message rate
kubectl logs -n azure-iot-operations -l app=aio-dataflow-processor | grep -i "published"
```

#### ADX (Azure Data Explorer) Endpoint

```yaml
apiVersion: connectivity.iotoperations.azure.com/v1beta1
kind: DataflowEndpoint
metadata:
  name: adx-endpoint
  namespace: azure-iot-operations
spec:
  endpointType: DataExplorer
  dataExplorerSettings:
    host: https://mycluster.eastus.kusto.windows.net
    database: iot-operations
    authentication:
      method: SystemAssignedManagedIdentity
    batching:
      latencySeconds: 10
      maxMessages: 100
```

---

## Deploying Edge Applications

### Using Unified Deployment Scripts

All applications in `iotopps/` use standard deployment pattern:

```powershell
# Deploy to Docker Hub
.\Deploy-ToIoTEdge.ps1 -AppFolder "edgemqttsim" -RegistryName "dockerhubusername"

# Deploy to Azure Container Registry
.\Deploy-ToIoTEdge.ps1 -AppFolder "edgemqttsim" -RegistryName "myacr" -UseACR

# Check deployment status
.\Deploy-Check.ps1 -AppFolder "edgemqttsim"

# Local development
.\Deploy-Local.ps1 -AppFolder "edgemqttsim" -Mode python
```

### Edge MQTT Simulator

Comprehensive factory equipment simulator with configurable message generation.

#### Configuration

Edit `iotopps/edgemqttsim/message_structure.yaml`:

```yaml
equipment_types:
  cnc_machine:
    base_cycle_time: 45.0
    cycle_time_variation: 0.15
    failure_rate: 0.02
    scrap_rate: 0.03
    message_interval: 5  # seconds
    topics:
      - factory/cnc
      - factory/machining
    
  welding_station:
    base_cycle_time: 30.0
    cycle_time_variation: 0.20
    failure_rate: 0.03
    scrap_rate: 0.05
    message_interval: 3

machines:
  - machine_id: CNC-001
    station_id: STN-01
    equipment_type: cnc_machine
    
  - machine_id: WELD-001
    station_id: STN-02
    equipment_type: welding_station
```

#### Deployment

```bash
cd iotopps/edgemqttsim

# Build and deploy
docker build -t username/edgemqttsim:latest .
docker push username/edgemqttsim:latest

kubectl apply -f deployment.yaml
```

#### Monitoring

```bash
# View simulator logs
kubectl logs -l app=edgemqttsim -f

# View generated messages
kubectl exec -it deploy/mosquitto-sub -- \
  mosquitto_sub -h aio-broker-frontend -p 18883 -t 'factory/#' -v
```

### Demo Historian

SQL-based MQTT historian with HTTP API for querying historical data.

#### Features
- Subscribes to all topics (`#`)
- Stores in PostgreSQL with 30-day retention
- HTTP API for queries
- Health metrics endpoint

#### Deployment

```bash
cd iotopps/demohistorian

# Deploy with unified script
cd ../..
.\Deploy-ToIoTEdge.ps1 -AppFolder "demohistorian" -RegistryName "username"
```

#### Querying Data

```bash
# Get recent messages
curl http://demohistorian:8080/messages?limit=10

# Query specific topic
curl http://demohistorian:8080/messages?topic=factory/cnc&limit=50

# Time range query
curl "http://demohistorian:8080/messages?start=2024-01-01T00:00:00Z&end=2024-01-31T23:59:59Z"

# Health check
curl http://demohistorian:8080/health
```

See [demohistorian README](iotopps/demohistorian/README.md) for full API documentation.

---

## Monitoring and Observability

### Monitoring MQTT Traffic

#### Using mosquitto_sub

```bash
# All topics
kubectl exec -it -n azure-iot-operations deploy/aio-broker-frontend -- \
  mosquitto_sub -h localhost -p 18883 -t '#' -v

# Specific topic pattern
kubectl exec -it -n azure-iot-operations deploy/aio-broker-frontend -- \
  mosquitto_sub -h localhost -p 18883 -t 'factory/+/temperature' -v
```

#### Using mqtt-viewer (if installed)

```bash
mqtt-viewer -h aio-broker-frontend.azure-iot-operations -p 18883 -t '#'
```

#### Using mqttui (if installed)

```bash
mqttui -h aio-broker-frontend.azure-iot-operations -p 18883
```

### Kubernetes Monitoring

#### Using k9s (if installed)

```bash
k9s -n azure-iot-operations
```

Navigate with:
- `:pods` - View pods
- `:logs` - View logs
- `:events` - View cluster events

#### Using kubectl

```bash
# Pod status
kubectl get pods -n azure-iot-operations

# Detailed pod info
kubectl describe pod <pod-name> -n azure-iot-operations

# Logs
kubectl logs -n azure-iot-operations <pod-name> --tail=100 -f

# Events
kubectl get events -n azure-iot-operations --sort-by='.lastTimestamp'
```

### Azure Portal Monitoring

#### Kubernetes Resources in Portal

To view K8s resources in Azure Portal, you need a bearer token:

```bash
cd linux_build
bash get-k8s-bearer-token.sh
```

Then in Azure Portal:
1. Navigate to Arc-enabled Kubernetes cluster
2. Click "Kubernetes resources (preview)"
3. Enter bearer token when prompted

#### Azure IoT Operations Metrics

In Azure Portal → IoT Operations instance:
- **Overview** - Message rates, connection status
- **Assets** - Device registry and asset list
- **Dataflows** - Data pipeline status
- **Diagnostics** - Logs and metrics

---

## Fabric Integration

### Setting Up Microsoft Fabric Real-Time Intelligence

Full guide: [fabric-realtime-intelligence-setup.md](Fabric_setup/fabric-realtime-intelligence-setup.md)

#### Quick Setup

1. **Create Event Stream in Fabric**
   - Navigate to Real-Time Intelligence workspace
   - Create new Event Stream
   - Note the connection string

2. **Extract EntityPath**

```powershell
# Connection string format:
# Endpoint=sb://xxx.servicebus.windows.net/;SharedAccessKeyName=xxx;SharedAccessKey=xxx;EntityPath=es_abc123

$connString = "<your-connection-string>"
if ($connString -match 'EntityPath=([^;]+)') {
    $entityPath = $matches[1]
    Write-Host "EntityPath: $entityPath"
}
```

3. **Create Kubernetes Secret**

```bash
kubectl create secret generic fabric-connection-string \
  --from-literal=username='$ConnectionString' \
  --from-literal=password='<full-connection-string>' \
  -n azure-iot-operations
```

4. **Deploy Endpoint and Dataflow**

```bash
# Deploy endpoint
kubectl apply -f Fabric_setup/fabric-endpoint.yaml

# Deploy dataflow
kubectl apply -f Fabric_setup/fabric-realtime-dataflow.yaml
```

5. **Verify in Fabric**
   - Open Event Stream in Fabric
   - View "Data Insights" tab
   - Should see incoming messages

### Troubleshooting Fabric Connection

```bash
# Check endpoint status
kubectl get dataflowEndpoint fabric-endpoint -o yaml

# Check dataflow status
kubectl get dataflow -o yaml

# View processor logs
kubectl logs -n azure-iot-operations -l app=aio-dataflow-processor --tail=100

# Common issues and solutions in next section
```

---

## Troubleshooting

### Common Issues

#### 1. No Pods Running After Installation

**Symptoms**: `kubectl get pods -n azure-iot-operations` shows no pods

**Diagnosis**:
```bash
# Check if namespace exists
kubectl get namespace azure-iot-operations

# Check Arc extensions
az k8s-extension list --cluster-name iot-ops-cluster \
  --resource-group IoT-Operations --cluster-type connectedClusters

# Check Arc connection
az connectedk8s show --name iot-ops-cluster --resource-group IoT-Operations
```

**Solutions**:
```bash
# Reconnect to Arc
az connectedk8s connect --name iot-ops-cluster \
  --resource-group IoT-Operations \
  --enable-oidc-issuer --enable-workload-identity \
  --custom-locations-oid <service-principal-id>

# Redeploy AIO extension
az k8s-extension create --cluster-name iot-ops-cluster \
  --resource-group IoT-Operations \
  --cluster-type connectedClusters \
  --extension-type microsoft.iotoperations \
  --name aio --version latest
```

#### 2. Fabric Endpoint Shows "Failed" in Portal

**Root Cause**: CSI secret sync doesn't work on Arc clusters without workload identity infrastructure.

**Solution**: Manual secret creation (see [Fabric Integration](#fabric-integration))

**Details**: See [BUG_REPORT_FABRIC_ENDPOINT_DEPLOYMENT.md](operations/BUG_REPORT_FABRIC_ENDPOINT_DEPLOYMENT.md)

#### 3. Dataflow Not Sending Messages

**Diagnosis**:
```bash
# Check dataflow status
kubectl get dataflow -n azure-iot-operations -o yaml

# Check logs for errors
kubectl logs -n azure-iot-operations -l app=aio-dataflow-processor --tail=200 | grep -i error

# Verify source endpoint
kubectl get dataflowEndpoint default -n azure-iot-operations -o yaml

# Verify destination endpoint
kubectl get dataflowEndpoint fabric-endpoint -n azure-iot-operations -o yaml
```

**Common Fixes**:

```yaml
# Fix 1: Wrong topic name (use EntityPath from connection string)
spec:
  operations:
  - operationType: Destination
    destinationSettings:
      dataDestination: es_e526de3f-6433-4a35-8f07-521f30abe1c5  # EntityPath, not custom name

# Fix 2: Wrong authentication method
spec:
  kafkaSettings:
    authentication:
      method: Sasl  # Not SystemAssignedManagedIdentity for Fabric
      saslSettings:
        saslType: Plain
        secretRef: fabric-connection-string

# Fix 3: Missing secret keys
# Secret must have 'username' and 'password' keys, not 'connectionString'
```

#### 4. K3s Cluster Issues

```bash
# Check K3s service
sudo systemctl status k3s

# Restart K3s
sudo systemctl restart k3s

# View K3s logs
sudo journalctl -u k3s -f

# Check cluster health
kubectl cluster-info
kubectl get nodes
```

**Advanced K3s Diagnostics**:
```bash
cd linux_build
bash k3s_troubleshoot.sh
bash diagnose-orchestrator.sh
```

#### 5. MQTT Connection Refused

**Symptoms**: Applications can't connect to MQTT broker

**Diagnosis**:
```bash
# Check broker pods
kubectl get pods -n azure-iot-operations | grep broker

# Check broker service
kubectl get svc -n azure-iot-operations | grep broker

# Test connection from inside cluster
kubectl run mqtt-test --rm -it --image=eclipse-mosquitto:latest -- \
  mosquitto_sub -h aio-broker-frontend -p 18883 -t 'test' -v
```

**Solutions**:
```bash
# Fix broker authentication
cd iotopps/edgemqttsim
bash fix-mqtt-connection.sh

# Check broker listener
kubectl get brokerlisten -n azure-iot-operations -o yaml
```

See [IOT_TROUBLESHOOTING.md](iotopps/edgemqttsim/IOT_TROUBLESHOOTING.md) for MQTT-specific issues.

#### 6. Application Pod CrashLoopBackOff

**Diagnosis**:
```bash
# Get pod status
kubectl get pods -l app=<app-name>

# View pod events
kubectl describe pod <pod-name>

# View logs
kubectl logs <pod-name> --previous
```

**Common causes**:
- Missing environment variables
- Incorrect secret references
- Network connectivity issues
- Resource constraints (CPU/memory)

#### 7. Secret Not Found

**Symptoms**: Pods fail with "secret not found" error

**Check secrets**:
```bash
# List secrets
kubectl get secrets -n azure-iot-operations

# Describe SecretProviderClass
kubectl describe secretproviderclass -n azure-iot-operations

# Check CSI driver logs
kubectl logs -n kube-system -l app=csi-secrets-store
```

**For Arc Clusters**:
Use manual secret creation instead of CSI driver (see [Arc Cluster Authentication Notes](#arc-cluster-authentication-notes))

### Diagnostic Scripts

Located in `linux_build/`:

```bash
# K3s cluster diagnostics
bash k3s_troubleshoot.sh
bash k3s_advanced_diagnostics.sh
bash diagnose-orchestrator.sh

# Network diagnostics
bash test_network.sh
bash fix_k3s_ports.sh

# Resource discovery
bash find-namespace-resource.sh
bash check_discovery.sh

# Verify secret management
bash verify-csi-secret-store.sh
```

### Getting Help

1. **Check logs**: Always start with `kubectl logs` and `kubectl describe pod`
2. **Review documentation**: Check app-specific READMEs in `iotopps/`
3. **Known issues**: Review `operations/BUG_REPORT_*.md` files
4. **Azure docs**: [Azure IoT Operations Troubleshooting](https://learn.microsoft.com/azure/iot-operations/troubleshoot/)

---

## Advanced Topics

### Multi-Cluster Management

Deploy AIO to multiple edge clusters from single management machine:

```powershell
# Cluster 1
.\External-Configurator.ps1 -ConfigFile ".\edge_configs\cluster1_info.json"

# Cluster 2
.\External-Configurator.ps1 -ConfigFile ".\edge_configs\cluster2_info.json"
```

### GitOps with Flux

Install Flux for declarative cluster management:

```bash
# Install Flux
flux bootstrap github \
  --owner=<github-user> \
  --repository=iot-ops-config \
  --path=clusters/production

# Deploy applications via GitOps
flux create source git iot-apps \
  --url=https://github.com/<user>/learn-iothub \
  --branch=main \
  --interval=1m

flux create kustomization iot-apps \
  --source=iot-apps \
  --path=./iotopps \
  --prune=true
```

### Custom MQTT Broker Configuration

Modify broker settings:

```yaml
apiVersion: mqttbroker.iotoperations.azure.com/v1beta1
kind: Broker
metadata:
  name: default
  namespace: azure-iot-operations
spec:
  cardinality:
    backendChain:
      partitions: 2
      redundancyFactor: 2
  memoryProfile: Medium
```

### Performance Tuning

#### K3s Tuning

Edit `/etc/rancher/k3s/config.yaml`:

```yaml
# Increase limits for IoT workloads
kube-apiserver-arg:
  - max-requests-inflight=400
  - max-mutating-requests-inflight=200
  
kube-controller-manager-arg:
  - node-monitor-period=2s
  - node-monitor-grace-period=16s
```

#### MQTT Broker Tuning

```yaml
spec:
  memoryProfile: High  # Low, Medium, High
  cardinality:
    backendChain:
      partitions: 4  # More partitions for higher throughput
      workers: 2
```

### Security Hardening

#### Network Policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mqtt-broker-ingress
  namespace: azure-iot-operations
spec:
  podSelector:
    matchLabels:
      app: aio-broker-backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: azure-iot-operations
    ports:
    - protocol: TCP
      port: 18883
```

#### RBAC for Applications

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: mqtt-client
  namespace: azure-iot-operations
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
  resourceNames: ["mqtt-credentials"]
```

### Backup and Disaster Recovery

#### Backup AIO Configuration

```bash
cd linux_build
bash backup_aio_configs.sh
```

Backs up:
- Kubernetes manifests
- Secrets (encrypted)
- ConfigMaps
- Custom resources

#### Restore from Backup

```bash
# Reinstall K3s and AIO
bash linux_installer.sh
.\External-Configurator.ps1 -ConfigFile cluster_info.json

# Restore applications
kubectl apply -f backups/manifests/
```

### Development Workflows

#### Local Testing Without Kubernetes

```powershell
# Run application locally
cd iotopps/edgemqttsim
.\Deploy-Local.ps1 -Mode python

# Test with local MQTT broker
docker run -d -p 1883:1883 eclipse-mosquitto:latest
$env:MQTT_HOST="localhost"
$env:MQTT_PORT="1883"
python app.py
```

#### Hot Reload in Kubernetes

```bash
# Use Skaffold for live reload
skaffold dev --port-forward
```

---

## Additional Resources

### Documentation
- [Azure IoT Operations Docs](https://learn.microsoft.com/azure/iot-operations/)
- [K3s Documentation](https://docs.k3s.io/)
- [MQTT Protocol](https://mqtt.org/)
- [Kubernetes Docs](https://kubernetes.io/docs/)

### Repository Documentation
- [Linux Build Steps](linux_build/linux_build_steps.md)
- [K3s Troubleshooting](linux_build/K3S_TROUBLESHOOTING_GUIDE.md)
- [Certificate Management](iotopps/CERT_MANAGEMENT.md)
- [Authentication Comparison](iotopps/AUTH_COMPARISON.md)
- [Fabric Setup](Fabric_setup/fabric-realtime-intelligence-setup.md)
- [Bug Reports](operations/)

### Tools
- [K9s - Terminal UI for K8s](https://k9scli.io/)
- [MQTTUI - Terminal UI for MQTT](https://github.com/EdJoPaTo/mqttui)
- [Lens - Kubernetes IDE](https://k8slens.dev/)

---

## Contributing

Contributions welcome! Areas of focus:

- Additional edge application examples
- Enhanced troubleshooting scripts
- Integration examples (ADX, Cosmos DB, Functions)
- Performance optimization guides
- Security hardening procedures

Please follow the existing patterns for:
- Application structure (Dockerfile, deployment.yaml, README.md)
- PowerShell script conventions
- Documentation formatting
