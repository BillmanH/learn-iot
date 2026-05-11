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
| IP lockout — full pod pool exhausted | tcpdump 2026-05-11 (v2 capture, pod `.112` and `.115`) | ❌ **BLOCKER**: Both new pod IPs get `HTTP 400 Bad Request` + `ter:NotAuthorized` on the unauthenticated probe. Earlier "fresh" IP `.34` got `HTTP 200` with device info on the same unauthenticated probe — same request, different HTTP status based on source IP. This is inferred as Tapo's brute-force protection (no specific "banned" error code — the `HTTP 400` vs `HTTP 200` discrepancy on the same unauthenticated request from different source IPs is the evidence; TP-Link does not publish a formal spec for this behavior but it is widely reported in [community forums](https://community.tp-link.com/en/home/forum/topic/686042)). The connector never gets a chance to send credentials. |
| Camera clock skew | Section 1 of v2 diagnostic log | ✅ Camera UTC `2026-05-11T21:12:23Z`, NUC UTC `21:12:24.4Z`, skew = **+1.4s** — well within ONVIF's 300s window. Not a factor. |

**CONFIRMED ROOT CAUSE: IP ban exhaustion.** The camera has banned the entire `10.42.0.0/24` pod CIDR (or enough of it) that every new connector pod IP also gets `HTTP 400` immediately. The connector never even attempts authentication. The ban list survives power cycles (stored in NVRAM).

**Credentials are confirmed correct** — the only blocker is getting an unban IP to reach the camera.

### Confirmed Correct Credentials

- **Username:** `homecamnet` (lowercase — verified working via direct SOAP test from cluster pod)
- **Password:** `40z$jiOdg6` (10 chars, PasswordDigest — verified working via direct SOAP test)
- Both are set correctly in Key Vault `iot-opps-keys`, synced to K8s SecretSync secret `tapo-desk-secretsync-72f20aa8`, and mounted into the connector pod at `/etc/akri/secrets/device_endpoint_auth/azureiotoperationsconnectorforonvif-8404-612d9fbf/`.

### Current Status (2026-05-11 — Factory Reset Done, New Auth Failure)

All infrastructure is correct. Credentials were confirmed working via `onvif_auth_test.py` against the **pre-reset** camera. The only blocker was **IP ban exhaustion**.

**Factory reset performed 2026-05-11 ~22:00Z.** Result:
- Camera rebooted and re-added to Tapo app.
- ONVIF user re-created (username `homecamnet`, password `40z$jiOdg6`).
- Connector pod deleted to force fresh start (the `--replicas=0/1` scale did not reset the backoff timer — pod deletion was required).
- **IP ban is cleared**: connector now receives `HTTP 200` on the unauthenticated probe (no more `HTTP 400` rejection).
- **New blocker**: connector now receives `HTTP 200 + SOAP ter:NotAuthorized` fault — a genuine credential rejection. This means the camera is accepting the connection but rejecting the username/password.

**Possible causes:**
1. ONVIF user was re-created with a different username or password than what is in K8s secrets.
2. Username was entered with wrong casing (camera is case-sensitive — must be exactly `homecamnet`).
3. Password contained a typo (watch for special chars like `$` which Tapo app may render oddly).

**Next action**: re-run `onvif_auth_test.py` from a cluster pod to confirm whether credentials in K8s secrets still work against the freshly reset camera. If they fail, the ONVIF user on the camera needs to be re-created to match exactly.

---

## Next Steps

### ✅ 1. Stop the connector (DONE)

Connector scaled to 0, then pod deleted to force fresh backoff reset.

### ✅ 2. Factory reset the camera (DONE 2026-05-11)

Camera reset, re-added to Tapo app, ONVIF user re-created.
IP ban confirmed cleared — camera now returns `HTTP 200` on unauthenticated probe.

### ⚠️ 3. Verify credentials and fix auth failure (IN PROGRESS)

Connector is connecting but getting `ter:NotAuthorized` — credentials don't match.

**Step 3a — Test credentials directly from a cluster pod:**
```bash
# SSH to NUC, then:
kubectl delete pod onvif-test -n azure-iot-operations --ignore-not-found
kubectl run onvif-test --rm -it --restart=Never --image=python:3.11-slim \
  -n azure-iot-operations -- python3 /path/to/onvif_auth_test.py
```
Or copy the script to the NUC and run:
```bash
kubectl cp ~/learn-iothub/issues/onvif_auth_test.py \
  azure-iot-operations/onvif-test:/tmp/test.py 2>/dev/null || true
```

**Step 3b — If test fails, re-create ONVIF user on camera:**
1. Open Tapo app → camera → Settings → Advanced Settings → ONVIF Account
2. Delete existing ONVIF account
3. Create new account:
   - Username: `homecamnet` (all lowercase, exactly 10 chars)
   - Password: `40z$jiOdg6` (mixed case + special chars, exactly 10 chars)
4. Confirm no auto-capitalisation applied (Tapo app may capitalise first letter)

**Step 3c — Confirm connector picks up and goes healthy:**
```powershell
kubectl logs -f azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0 \
  -n azure-iot-operations 2>&1 | Select-String -NotMatch "OnvifConnector is running"
```
Expected: `Endpoint tapo-desk/tapo-onvif-desk is now healthy` (or similar)

**Note:** A stale `onvif-test` pod may be left running. Clean it up first:
```powershell
kubectl delete pod onvif-test -n azure-iot-operations --ignore-not-found
```

---

## Notes

- Port `2020` is the ONVIF port for Tapo cameras — confirmed correct.
- Camera IP `10.0.0.48` is on home LAN. NUC cluster pods (`10.42.0.x`) can reach it fine.
- `additionalConfiguration: "{}"` — no auth method override. Connector uses PasswordDigest (default).
- Connector pod: `azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0` in `azure-iot-operations` (StatefulSet — restarts automatically if deleted, keeping pod name but getting new IP).
- **IP pool concern**: Every pod restart gets a new IP. If connector continuously retries with wrong auth, the new IP will get banned within minutes. After several restarts for diagnostics, most of the `.10.42.0.x` pool may be banned.
- The connector secret (`azureiotoperationsconnectorforonvif-8404-612d9fbf`) is a DIFFERENT secret from the SecretSync secret (`tapo-desk-secretsync-72f20aa8`). Both have been verified to contain the correct values.
- PowerShell `$` expansion bug: always use single quotes when setting KV secrets with `az keyvault secret set --value '...'`.
