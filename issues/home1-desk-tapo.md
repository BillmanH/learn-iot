# Troubleshooting: tapo-onvif-desk ONVIF Connector Auth Failure

## Error

```
healthState:
  status: Unavailable
  reasonCode: OnvifConnectorInboundEndpointConnectivityTestFailed
  message: >
    Connection failed: Fault { code: Faultcode { value: FaultcodeEnum("SOAP-ENV:Sender"),
    subcode: Some(Subcode { value: "ter:NotAuthorized" }) }, reason: Faultreason {
    text: [Reasontext { lang: "en", value: "Authority failure" }] }, ... }
```

**SOAP fault `ter:NotAuthorized` / "Authority failure"** means the ONVIF service on the camera is rejecting the credentials being presented.

---

## ARM Configuration

**Resource:** `Microsoft.DeviceRegistry/namespaces/iot-operations-ns/devices/tapo-desk`
**Endpoint name:** `tapo-onvif-desk` (inbound)

```json
{
  "tapo-onvif-desk": {
    "additionalConfiguration": "{}",
    "address": "http://10.0.0.48:2020",
    "authentication": {
      "method": "UsernamePassword",
      "usernamePasswordCredentials": {
        "passwordSecretName": "tapo-desk-secretsync-72f20aa8/tapo-onvif-desk-password",
        "usernameSecretName": "tapo-desk-secretsync-72f20aa8/tapo-onvif-desk-username"
      }
    },
    "endpointType": "Microsoft.Onvif"
  }
}
```

**Secret sync status:** `SecretSynchronized: True` — K8s secret is being populated successfully.  
Credentials sourced from Key Vault secrets:
- `homecamnet` → username key `tapo-onvif-desk-username`
- `homecamnetpass` → password key `tapo-onvif-desk-password`

---

## Investigation Log (2026-05-07)

### Ruled Out

| Check | Method | Result |
|---|---|---|
| Secret sync healthy | `az resource show` on SecretSync | ✅ `SecretSynchronized: True`, last sync `18:37:06Z` |
| Credentials reach connector | K8s secret decoded via PowerShell | ✅ Both values present, 10 bytes each |
| Trailing whitespace/newline in secrets | `$val.Contains([char]10)` + `$val[-1] -match '\s'` | ✅ Clean — no newlines or trailing spaces |
| Node clock skew | kubelet last heartbeat vs. local clock | ✅ <4 min delta, well within ONVIF's 5-min WS-Security window |
| Camera unreachable from cluster | `kubectl run curlimages/curl` pod → `curl http://10.0.0.48:2020` | ✅ TCP connects immediately, camera returns SOAP faults (not timeouts) |

**Clock skew notes:** The ONVIF WS-UsernameToken spec rejects tokens with a timestamp >5 minutes from the server clock. Node heartbeat was checked on `2026-05-07T18:57:45Z` vs. local `19:01:42Z` — delta ~237s (< 5 min). Node clock is fine. The connector receives proper SOAP faults with `ter:NotAuthorized`, not connection timeouts — confirming the issue is auth rejection, not a network or timing problem. **Do not re-investigate clock skew unless the error changes to a timeout or the NUC has been offline/rebooted without NTP.**

### Root Cause Analysis

All infrastructure (secret sync, K8s plumbing, network) is working correctly. The ONVIF service on the camera is actively receiving and rejecting the credentials.

### Remaining Suspects (in order)

1. **Tapo ONVIF account lockout** — The connector retries every 30s. After hundreds of failed attempts since May 6, some Tapo firmware versions temporarily or permanently lock the ONVIF account. **Fix: power-cycle the camera** to reset the lockout, then verify credentials before the connector starts retrying again.

2. **Tapo local ONVIF credentials ≠ Key Vault values** — Tapo cameras have a **separate ONVIF account** from the Tapo cloud login. It is configured via the camera's **local web UI** (`http://10.0.0.48`), not the Tapo app. If this password was changed on the camera or was never set to match what's in Key Vault, auth will always fail regardless of secret sync health.

---

## Next Steps (requires physical/local access to NUC or camera)

### 1. Power-cycle the camera to clear any ONVIF lockout

Unplug and replug the Tapo camera at `10.0.0.48`. Wait ~60s for it to come back online, then watch the connector health:

```powershell
# Watch for health state to change
while ($true) {
    $status = az resource show --ids "/subscriptions/5c043aac-3d88-43d5-aec8-cd02ee6c914a/resourceGroups/IoT-Operations/providers/Microsoft.DeviceRegistry/namespaces/iot-operations-ns/devices/tapo-desk" --query "properties.status.endpoints.inbound.\"tapo-onvif-desk\".healthState" -o json | ConvertFrom-Json
    Write-Host "$(Get-Date -Format 'HH:mm:ss')  status=$($status.status)  reason=$($status.reasonCode)"
    Start-Sleep 15
}
```

### 2. Verify/reset ONVIF credentials on the camera

From the NUC (or any machine on the `10.0.0.x` network), open the camera's local web UI:

```
http://10.0.0.48
```

Navigate to **Settings → Advanced Settings → ONVIF** (exact path varies by firmware). Confirm or reset the ONVIF username/password. Then update Key Vault to match:

```powershell
$kvName = "<your-keyvault-name>"
az keyvault secret set --vault-name $kvName --name "homecamnet" --value "<onvif-username>"
az keyvault secret set --vault-name $kvName --name "homecamnetpass" --value "<onvif-password>"
```

Secret sync polls ~every 30s — confirm it picks up the new values:

```powershell
kubectl get secretsync tapo-desk-secretsync-72f20aa8 -n azure-iot-operations -o jsonpath='{.status.conditions[0].lastTransitionTime}'
```

### 3. Restart the connector after credentials are fixed

```powershell
kubectl delete pod azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0 -n azure-iot-operations
# Pod will be recreated automatically by the StatefulSet
```

---

## Notes

- Port `2020` is the standard ONVIF port for Tapo cameras — this is correct.
- The camera IP `10.0.0.48` is on the home LAN (`10.0.0.x`), not reachable from this Windows dev machine. The NUC cluster pod network (`10.42.0.x`) can reach it fine — confirmed via temporary curl pod.
- `additionalConfiguration: "{}"` is empty, which is valid for basic ONVIF connectivity.
- Connector pod: `azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0` in `azure-iot-operations` (StatefulSet, restarts automatically if deleted).
- The connector has been retrying every 30s since at least `2026-05-06T13:34:28Z` — hundreds of failed auth attempts, making lockout the most likely current state even if credentials were originally correct.
