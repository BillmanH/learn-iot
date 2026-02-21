# Tracking: Fabric RTI Event Stream — No Entra ID Auth for Custom Kafka Endpoints

**Tag**: `fabric-entra-id-gap`  
**Status**: Open (Fabric-side feature gap)  
**Opened**: February 2026

---

## Summary

Fabric Real-Time Intelligence Event Stream custom endpoints **only support SAS key (SASL/Plain) authentication** for Kafka-protocol ingestion. Microsoft Entra ID / Managed Identity is not available for external clients as of early 2026.

This forces this repo to use a SAS connection string stored in Azure Key Vault and synced to the cluster via the CSI Secret Store driver — adding operational complexity (secret rotation, SecretProviderClass, UA-MI for secret sync) that would be unnecessary if Fabric exposed Entra auth.

**This is a Fabric-side limitation, not an AIO or architecture limitation.** AIO's dataflow engine fully supports `SystemAssignedManagedIdentity` for Kafka endpoints (it works with standard Azure Event Hubs). The WILF/OIDC/SAMI stack is already in place and proven.

---

## Code Locations Tagged

Grep for `fabric-entra-id-gap` to find all tagged locations:

- `arc_build_linux/installer.sh` → `install_csi_secret_store()` — CSI driver installation
- `arc_build_linux/arc_enable.ps1` → `Create-FabricSecretPlaceholders` — Key Vault secret seeding
- `external_configuration/External-Configurator.ps1` → Step 3/6 (Key Vault ARM deploy) and `secretsync enable` call

---

## Files to Update When Fabric Adds Entra ID Support

- [ ] `fabric_setup/fabric-endpoint.yaml` — change `method: Sasl` → `method: SystemAssignedManagedIdentity`, remove `saslSettings` block
- [ ] `fabric_setup/Deploy-FabricEndpoint.ps1` — remove Key Vault secret storage / retrieval logic
- [ ] `fabric_setup/fabric-realtime-intelligence-setup.md` — update auth instructions; remove SAS key steps
- [ ] `fabric_setup/fabric_config.template.json` — remove `connectionString` field
- [ ] `modules/setup-SAS-for-RTI.sh` — delete or archive (no longer needed)
- [ ] `README_ADVANCED.md` — update Fabric endpoint YAML example; remove `# Not SystemAssignedManagedIdentity for Fabric` comments
- [ ] `docs/VERIFY_SECRET_MANAGEMENT.md` — most of this file becomes unnecessary; simplify or archive
- [ ] `external_configuration/External-Configurator.ps1` — remove Step 3/6 (Key Vault) and `secretsync enable` from the Fabric-specific path; remove the Key Vault "Next Steps" prompt
- [ ] `arc_build_linux/arc_enable.ps1` — remove or repurpose `Create-FabricSecretPlaceholders`; remove Key Vault placeholder seeding from `Main`
- [ ] `arc_build_linux/installer.sh` — `install_csi_secret_store()` becomes optional (Key Vault sync no longer required for the Fabric RTI path)
- [ ] `.github/copilot-instructions.md` — update Fabric RTI auth section to show `SystemAssignedManagedIdentity` as the correct method

---

## Fabric UserVoice / Feedback Template

Use the following as a starting point when filing a Fabric feedback item:

> **Title**: Support Microsoft Entra ID / Managed Identity authentication for Event Stream custom Kafka endpoints
>
> **Description**:
> Fabric Real-Time Intelligence Event Stream custom endpoints currently only offer SAS key (Shared Access Signature) authentication when using the Kafka protocol. There is no option for Managed Identity or Microsoft Entra ID authentication in the custom endpoint configuration UI.
>
> For customers using Azure IoT Operations (or any Kafka-protocol producer running on Azure with a Managed Identity), this forces the use of shared secrets (SAS connection strings), which must be stored, rotated, and managed. This adds unnecessary operational complexity given that the full OIDC/WILF/SAMI infrastructure is already available in Azure.
>
> AIO's dataflow engine already supports `SystemAssignedManagedIdentity` for Kafka endpoints — it works today with standard Azure Event Hub namespaces. The gap is specifically on the Fabric side: the Kafka bootstrap server for Fabric Event Stream custom endpoints does not accept Entra ID tokens.
>
> **Request**: Expose Microsoft Entra ID / Managed Identity as an authentication option for Fabric Event Stream custom Kafka endpoints, so producers can authenticate without SAS keys.

---

## Verification Checklist (When Closing This Issue)

Before removing the `fabric-entra-id-gap` TODOs and performing the "Files to Update" changes above, verify:

- [ ] Fabric release notes confirm Entra ID / Managed Identity support for custom Kafka endpoints
- [ ] The Fabric Event Stream custom endpoint configuration UI shows a "Managed Identity" or "Microsoft Entra ID" auth option
- [ ] Test: create a Fabric RTI DataflowEndpoint with `method: SystemAssignedManagedIdentity` and confirm AIO can authenticate and send messages without any Key Vault secret
- [ ] Confirm the bootstrap server format has not changed (or update connection string docs accordingly)
- [ ] Confirm that existing RBAC role assignments (`Azure Event Hubs Data Sender/Receiver` granted by `grant_entra_id_roles.ps1`) are sufficient, or document any additional roles required
