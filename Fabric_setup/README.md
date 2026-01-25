# Fabric Setup Configuration Files

This directory contains configuration files for deploying Microsoft Fabric Real-Time Intelligence endpoints.

## Configuration Files

### `fabric_config.json` ⚠️ **DO NOT COMMIT**
Your actual configuration with sensitive connection strings. This file is in `.gitignore`.

### `fabric_config.template.json` ✅ Safe to commit
Template file showing the structure and required fields. Copy this to `fabric_config.json` and fill in your values.

## Quick Start

1. **Copy the template:**
   ```powershell
   Copy-Item fabric_config.template.json fabric_config.json
   ```

2. **Edit `fabric_config.json` and fill in your Fabric Event Stream details:**
   - `bootstrapServer`: From Fabric Event Stream → Custom endpoint → Kafka protocol
   - `connectionString`: From Fabric Event Stream → Custom endpoint → Shared access key → Connection string-primary key
   - `topicName`: From Fabric Event Stream → Custom endpoint (format: `es_<guid>`)

3. **Run the deployment:**
   ```powershell
   .\Deploy-FabricEndpoint.ps1
   ```

## Configuration Structure

```json
{
  "fabric": {
    "bootstrapServer": "Your Fabric bootstrap server:9093",
    "connectionString": "Full connection string from Fabric",
    "topicName": "Event Stream topic name"
  },
  "endpoint": {
    "name": "fabric-endpoint",
    "namespace": "azure-iot-operations",
    "consumerGroupId": "iot-operations-consumer",
    "compression": "None",
    "copyMqttProperties": true,
    "cloudEventAttributes": "Propagate"
  },
  "azure": {
    "keyVault": {
      "name": "iot-opps-keys",
      "secretName": "fabric-connection-string"
    },
    "cluster": {
      "name": "iot-ops-cluster",
      "resourceGroup": "IoT-Operations",
      "namespace": "azure-iot-operations"
    }
  },
  "deployment": {
    "skipPrereqCheck": false,
    "validateOnly": false
  }
}
```

## Alternative: Command-Line Parameters

You can also run the script with command-line parameters instead of using the config file:

```powershell
.\Deploy-FabricEndpoint.ps1 `
  -BootstrapServer "server.servicebus.windows.net:9093" `
  -ConnectionString "Endpoint=sb://..." `
  -EndpointName "fabric-endpoint" `
  -KeyVaultName "iot-opps-keys" `
  -SecretName "fabric-connection-string"
```

## Files

- `fabric_config.json` - Your actual config (gitignored)
- `fabric_config.template.json` - Template for configuration
- `fabric-endpoint.yaml` - Kubernetes endpoint YAML template
- `Deploy-FabricEndpoint.ps1` - Deployment script
- `fabric-realtime-intelligence-setup.md` - Complete setup guide

## Security Note

⚠️ **Never commit `fabric_config.json`** - it contains sensitive connection strings and keys. Always use the template file for sharing and documentation.
