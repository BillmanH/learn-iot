# Fabric Setup — Reference Documentation

This directory contains reference documentation for connecting Azure IoT Operations to Microsoft Fabric Real-Time Intelligence.

> **Configuration is done in the Azure Portal.** Fabric Event Stream now supports **Managed Identity** authentication, so there are no connection strings or Kubernetes secrets to manage. The files here are informational only.

## Files

- `fabric-realtime-intelligence-setup.md` — Complete step-by-step setup guide
- `RTI_Dashboard_queries.md` — KQL queries for OEE dashboards

## Quick Summary

The integration uses **System-Assigned Managed Identity** for authentication — the same approach as other Azure endpoints (ADX, Event Hubs). No secrets, no Key Vault setup, no `kubectl` commands.

| Step | Where | What |
|------|-------|------|
| 1 | Fabric portal | Create Workspace + Event Stream with a custom endpoint |
| 2 | Azure Portal (AIO) | Create a Kafka dataflow endpoint pointing at the Fabric bootstrap server |
| 3 | Azure Portal (AIO) | Create a dataflow routing MQTT topics to the Fabric endpoint |
| 4 | Fabric portal | Verify messages arriving in the Event Stream |

See [fabric-realtime-intelligence-setup.md](fabric-realtime-intelligence-setup.md) for the full walkthrough.
