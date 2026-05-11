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
    "address": "http://10.0.0.48:2020/onvif/device_service",
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
| Credentials in connector pod | `kubectl debug` ephemeral container + K8s secret hex decode | ✅ `homecamnet` (10 chars, `68 6F 6D 65 63 61 6D 6E 65 74`) and `40z$jiOdg6` (10 chars, `34 30 7A 24 6A 69 4F 64 67 36`) confirmed correct in the connector's own secret `azureiotoperationsconnectorforonvif-8404-612d9fbf` |
| PasswordDigest vs PasswordText | `onvif_auth_test.py` + AIO docs | ✅ Only `PasswordDigest` works; `PasswordText` always rejected. AIO connector defaults to PasswordDigest ("Fallback to username token auth" option defaults to No). |
| Clock skew (Python test) | Python test from same NUC node succeeds → proves NUC clock is fine | ✅ Python `onvif_auth_test.py` with same credentials, same node clock, SUCCEEDS → clock skew is NOT the cause (both test pod and connector use the same node clock) |
| Connector auth flow | tcpdump 2026-05-11 (full capture) | ✅ Connector sends **unauthenticated** `GetDeviceInformation` probe first. If the probe returns `HTTP 400 + ter:NotAuthorized` (IP banned), connector logs `Failed to connect` and **never sends credentials at all**. The `NotAuthorized` in the logs IS the probe failure — not a separate authenticated call. |
| IP lockout — full pod pool exhausted | tcpdump 2026-05-11 (v2 capture, pod `.112` and `.115`) | ❌ **BLOCKER**: Both new pod IPs get `HTTP 400` on the unauthenticated probe. Camera is banning the entire `10.42.0.x` pod CIDR due to hundreds of failed attempts since `2026-05-06`. The connector never gets a chance to send credentials. |
| Camera clock skew | Section 1 of v2 diagnostic log | ✅ Camera UTC `2026-05-11T21:12:23Z`, NUC UTC `21:12:24.4Z`, skew = **+1.4s** — well within ONVIF's 300s window. Not a factor. |

**CONFIRMED ROOT CAUSE: IP ban exhaustion.** The camera has banned the entire `10.42.0.0/24` pod CIDR (or enough of it) that every new connector pod IP also gets `HTTP 400` immediately. The connector never even attempts authentication. The ban list survives power cycles (stored in NVRAM).

**Credentials are confirmed correct** — the only blocker is getting an unban IP to reach the camera.

### Confirmed Correct Credentials

- **Username:** `homecamnet` (lowercase — verified working via direct SOAP test from cluster pod)
- **Password:** `40z$jiOdg6` (10 chars, PasswordDigest — verified working via direct SOAP test)
- Both are set correctly in Key Vault `iot-opps-keys`, synced to K8s SecretSync secret `tapo-desk-secretsync-72f20aa8`, and mounted into the connector pod at `/etc/akri/secrets/device_endpoint_auth/azureiotoperationsconnectorforonvif-8404-612d9fbf/`.

### Current Status (2026-05-11 — RESOLVED ROOT CAUSE)

All infrastructure is correct. Credentials are confirmed working via `onvif_auth_test.py`. The only blocker is **IP ban exhaustion**:

1. Connector has been retrying every ~30s since `2026-05-06` with bad credentials (original issues: wrong username casing, truncated password).
2. Each retry cycle burned the current pod IP. Over hundreds of retries, enough IPs in `10.42.0.0/24` were banned that the camera now returns `HTTP 400 + ter:NotAuthorized` to **every** new pod IP on the first unauthenticated probe.
3. The connector logic: if the unauthenticated probe fails → log error, store endpoint as unhealthy, retry in 5 min. It **does not** attempt an authenticated call after a probe failure.
4. Result: the connector is permanently stuck — each retry burns another IP.

---

## Next Steps

### 1. Stop the connector immediately (prevent burning more IPs)

```powershell
kubectl scale statefulset azureiotoperationsconnectorforonvif-8404-612d9fbf-ss \
  -n azure-iot-operations --replicas=0
```

Verify it's stopped:
```powershell
kubectl get pods -n azure-iot-operations | Select-String onvif
```

### 2. Factory reset the camera to clear the IP ban list

The ban list is stored in camera NVRAM and survives power cycles. The only way to clear it is a **factory reset**:

1. Hold the reset button on the Tapo camera for 10+ seconds until the LED flashes
2. Wait for camera to reboot (~60s)
3. Re-add the camera in the Tapo app
4. Re-create the ONVIF user: **username `homecamnet`, password `40z$jiOdg6`** (case-sensitive)
5. Confirm the camera still responds on `10.0.0.48:2020` (check DHCP lease / static IP)

### 3. Scale the connector back up and verify

```powershell
kubectl scale statefulset azureiotoperationsconnectorforonvif-8404-612d9fbf-ss \
  -n azure-iot-operations --replicas=1
```

Run `collect_onvif_diag.sh` immediately after scale-up to capture the first attempt from a fresh IP:
```bash
bash ~/learn-iothub/issues/collect_onvif_diag.sh
bash ~/learn-iothub/issues/upload_diag.sh
```

Expected result: connector probe succeeds (HTTP 200 device info), followed by authenticated `GetDeviceInformation` with `wsse:UsernameToken`, camera returns success, connector logs endpoint as healthy.

---

## Notes

- Port `2020` is the ONVIF port for Tapo cameras — confirmed correct.
- Camera IP `10.0.0.48` is on home LAN. NUC cluster pods (`10.42.0.x`) can reach it fine.
- `additionalConfiguration: "{}"` — no auth method override. Connector uses PasswordDigest (default).
- Connector pod: `azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0` in `azure-iot-operations` (StatefulSet — restarts automatically if deleted, keeping pod name but getting new IP).
- **IP pool concern**: Every pod restart gets a new IP. If connector continuously retries with wrong auth, the new IP will get banned within minutes. After several restarts for diagnostics, most of the `.10.42.0.x` pool may be banned.
- The connector secret (`azureiotoperationsconnectorforonvif-8404-612d9fbf`) is a DIFFERENT secret from the SecretSync secret (`tapo-desk-secretsync-72f20aa8`). Both have been verified to contain the correct values.
- PowerShell `$` expansion bug: always use single quotes when setting KV secrets with `az keyvault secret set --value '...'`.
