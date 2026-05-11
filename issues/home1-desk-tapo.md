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

## Investigation Log

### Ruled Out

| Check | Method | Result |
|---|---|---|
| Secret sync healthy | `az resource show` on SecretSync | ✅ `SecretSynchronized: True`, last sync `18:37:06Z` |
| Credentials reach connector | K8s secret + connector pod secret decoded via PowerShell | ✅ Both values present, 10 bytes each, correct hex |
| Trailing whitespace/newline in secrets | `$val.Contains([char]10)` + `$val[-1] -match '\s'` | ✅ Clean — no newlines or trailing spaces |
| Node clock skew | kubelet last heartbeat vs. local clock | ✅ ~4 min delta (node `20:07:50Z`, local `20:12:15Z`), within ONVIF's 5-min window |
| Camera unreachable from cluster | curl pod → `curl http://10.0.0.48:2020` | ✅ TCP connects, camera returns SOAP faults (not timeouts) |
| IP-based lockout | Tested from multiple fresh pod IPs (`.27`, `.28`, `.29`, `.30`, `.32`) | ✅ Ruled out — all fail; test pod on different IP also succeeded |
| Correct username casing | `onvif_auth_test.py` from cluster pod | ✅ **`homecamnet` (lowercase) succeeds. `Homecamnet` (capital H) fails.** Camera is case-sensitive. |
| Credentials in connector pod | `kubectl debug` ephemeral container reading `/etc/akri/secrets/device_endpoint_auth/.../tapo-desk_tapo-onvif-desk_username` | ✅ Reads `homecamnet` — correct |
| PasswordDigest vs PasswordText | `onvif_auth_test.py` | ✅ Only `PasswordDigest` works; `PasswordText` always rejected |

**Clock skew notes:** The ONVIF WS-UsernameToken spec rejects tokens with a timestamp >5 minutes from the server clock. Confirmed still within window on 2026-05-11. **Do not re-investigate clock skew unless the error changes to a timeout or the NUC has been offline/rebooted without NTP.**

### Confirmed Correct Credentials

- **Username:** `homecamnet` (lowercase — verified working via direct SOAP test from cluster pod)
- **Password:** `40z$jiOdg6` (10 chars, PasswordDigest — verified working via direct SOAP test)
- Both are set correctly in Key Vault `iot-opps-keys`, synced to K8s SecretSync secret `tapo-desk-secretsync-72f20aa8`, and mounted into the connector pod at `/etc/akri/secrets/device_endpoint_auth/azureiotoperationsconnectorforonvif-8404-612d9fbf/`.

### Current Mystery (2026-05-11)

All infrastructure is correct and credentials are verified working via a Python SOAP test pod on the same cluster. Yet the connector pod still gets `ter:NotAuthorized` immediately on startup. The connector behavior:
- Fails on `Device endpoint created` (~startup)
- Fails again on `Device endpoint updated` (~5s later, triggered by ARM sync)
- Then silently retries every ~5 minutes (only logs the first failure per retry cycle)

Suspect the AIO ONVIF connector (`akri-connectors/onvif:1.3.4`) may be reading credentials differently (e.g. from a different path, or building the WS-Security token incorrectly). Need to capture the actual SOAP request the connector sends.

---

## Next Steps

### Capture the actual SOAP request the connector sends

Run a local HTTP interceptor on the cluster to see what the connector is actually sending. Spin up a simple Python HTTP proxy on the camera's port:

```powershell
# On the cluster — redirect 10.0.0.48:2020 to a debug pod that logs then forwards
# OR: check AIO telemetry/OTLP traces for the outgoing SOAP body
```

Alternatively, if the NUC has `tcpdump` available, capture traffic from the NUC:
```bash
sudo tcpdump -i any -s 0 -A host 10.0.0.48 and port 2020 -w /tmp/onvif.pcap
```

### Quick diagnostic: run `onvif_auth_test.py` from the connector pod namespace

File is at [issues/onvif_auth_test.py](onvif_auth_test.py). Run from cluster:

```powershell
kubectl delete pod onvif-test -n azure-iot-operations --ignore-not-found
kubectl run onvif-test --image=python:3.11-slim --restart=Never -n azure-iot-operations --command -- sleep 120
kubectl wait pod onvif-test -n azure-iot-operations --for=condition=Ready --timeout=30s
kubectl cp issues/onvif_auth_test.py azure-iot-operations/onvif-test:/tmp/test.py
kubectl exec onvif-test -n azure-iot-operations -- python3 /tmp/test.py
# Expected: homecamnet/PasswordDigest = SUCCESS
```

### Update credentials (if camera password was changed)

```powershell
# NOTE: Use single quotes or backtick-escape $ to prevent PowerShell variable expansion
az keyvault secret set --vault-name iot-opps-keys --name homecamnet --value 'homecamnet'
az keyvault secret set --vault-name iot-opps-keys --name homecamnetpass --value '40z$jiOdg6'
# Wait ~40s for SecretSync, then restart pod
kubectl delete pod azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0 -n azure-iot-operations
```

---

## Notes

- Port `2020` is the standard ONVIF port for Tapo cameras — this is correct.
- The camera IP `10.0.0.48` is on the home LAN (`10.0.0.x`), not reachable from this Windows dev machine. The NUC cluster pod network (`10.42.0.x`) can reach it fine — confirmed via temporary curl pod.
- `additionalConfiguration: "{}"` is empty, which is valid for basic ONVIF connectivity.
- Connector pod: `azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0` in `azure-iot-operations` (StatefulSet, restarts automatically if deleted).
- The connector has been retrying every 30s since at least `2026-05-06T13:34:28Z` — hundreds of failed auth attempts, making lockout the most likely current state even if credentials were originally correct.
