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
    "additionalConfiguration": "{\"acceptInvalidHostnames\":true,\"acceptInvalidCertificates\":true,\"fallbackToUsernameTokenAuth\":true}",
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

**The critical field is `additionalConfiguration`:**
- `fallbackToUsernameTokenAuth: true` — tells the connector to send credentials even if the unauthenticated probe fails
- `acceptInvalidHostnames: true` — tolerates hostname mismatches (useful for IP-addressed cameras)
- `acceptInvalidCertificates: true` — tolerates self-signed certs

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
| IP lockout — full pod pool exhausted | tcpdump 2026-05-11 (v2 capture, pod `.112` and `.115`) | ✅ **Cleared by factory reset.** Was: both IPs got `HTTP 400` on unauthenticated probe. After reset: camera returns `HTTP 200`. |
| Camera clock skew | Section 1 of v2 diagnostic log | ✅ Camera UTC `2026-05-11T21:12:23Z`, NUC UTC `21:12:24.4Z`, skew = **+1.4s** — well within ONVIF's 300s window. Not a factor. |
| K8s secret correct post-reset | PowerShell base64 decode: `NDB6JGppT2RnNg==` / `aG9tZWNhbW5ldA==` | ✅ Connector secret contains `homecamnet` / `40z$jiOdg6` — correct. |
| Authenticated request from connector pod IP `.126` | `kubectl debug` ephemeral + `onvif_auth_test.py` run from inside connector pod network namespace | ✅ **`homecamnet`/`40z$jiOdg6` PasswordDigest from IP `10.42.0.126` → SUCCESS.** Camera accepts credentials from the connector's own IP. |
| Connector unauthenticated probe rejection | Connector log timing: error at `22:06:55.648Z`, startup at `22:06:55.560Z` — 88ms | ❌ **CURRENT BLOCKER**: Connector sends unauthenticated `GetDeviceInformation` first. Camera requires auth for ALL requests. Camera returns `ter:NotAuthorized` on the unauthenticated probe. Connector marks endpoint unhealthy and never attempts authenticated call. This camera's security policy is incompatible with the connector's probe-first design. |

**ROOT CAUSE (updated 2026-05-11):** The AIO ONVIF connector v1.3.4 unconditionally sends an unauthenticated `GetDeviceInformation` probe on startup. This Tapo camera (post-factory-reset, default security settings) requires authentication for **all** ONVIF requests including `GetDeviceInformation`. The connector never gets past the probe stage. Credentials are confirmed 100% correct — the problem is architectural.

### Confirmed Correct Credentials

- **Username:** `homecamnet` (lowercase — verified working via direct SOAP test from cluster pod)
- **Password:** `40z$jiOdg6` (10 chars, PasswordDigest — verified working via direct SOAP test)
- Both are set correctly in Key Vault `iot-opps-keys`, synced to K8s SecretSync secret `tapo-desk-secretsync-72f20aa8`, and mounted into the connector pod at `/etc/akri/secrets/device_endpoint_auth/azureiotoperationsconnectorforonvif-8404-612d9fbf/`.

### Current Status (2026-05-11 — Architectural Mismatch Confirmed)

**All credentials and networking are confirmed correct.** The problem is a mismatch between the connector's design and this camera's security policy:

- Factory reset cleared the IP ban list ✅
- K8s secret contains correct `homecamnet` / `40z$jiOdg6` ✅
- Authenticated PasswordDigest request from connector pod IP `10.42.0.126` → **SUCCESS** ✅
- Connector sends **unauthenticated** probe first → camera rejects it → connector never attempts authenticated call ❌

**The connector (AIO ONVIF v1.3.4) always sends an unauthenticated `GetDeviceInformation` before attempting authenticated calls.** This Tapo camera (default post-reset security settings) requires auth for ALL requests. The probe will always fail, the connector will always mark the endpoint unhealthy.

**Possible fixes (to investigate):**
1. **Camera setting**: Check Tapo app for an ONVIF security level or "unauthenticated access" option that would allow the probe to succeed.
2. **Connector `additionalConfiguration`**: Check if the AIO ONVIF connector supports a flag to skip the unauthenticated probe or always send credentials.
3. **AIO portal device endpoint settings**: May have an auth behaviour override.

---

## Next Steps

### ✅ 1. Stop the connector (DONE)

Connector scaled to 0, then pod deleted to force fresh backoff reset.

### ✅ 2. Factory reset the camera (DONE 2026-05-11)

Camera reset, re-added to Tapo app, ONVIF user re-created.
IP ban confirmed cleared — camera now returns `HTTP 200` on unauthenticated probe.

### ✅ 3. Credentials verified correct (DONE 2026-05-11)

- `onvif_auth_test.py` run from pod IP `10.42.0.126` (same IP as connector): `homecamnet`/`40z$jiOdg6` PasswordDigest → **SUCCESS**
- K8s connector secret decoded: `homecamnet` / `40z$jiOdg6` — exact match
- `onvif_auth_test.py` had a stale `username = "Homecamnet"` (capital H) hardcoded — fixed to lowercase

### ✅ 4. Fix unauthenticated probe rejection (RESOLVED 2026-05-11)

**Fix**: Set `fallbackToUsernameTokenAuth: true` in the endpoint's `additionalConfiguration` via the AIO portal.

Full working `additionalConfiguration`:
```json
{"acceptInvalidHostnames":true,"acceptInvalidCertificates":true,"fallbackToUsernameTokenAuth":true}
```

This tells the connector to send credentials even when the unauthenticated probe fails with `ter:NotAuthorized`. The connector immediately retried, connected successfully, and the endpoint became `Available`.

**Connector log on success:**
```
22:34:20.218Z - Device endpoint updated: tapo-desk/tapo-onvif-desk
22:34:20.287Z - Successfully connected to endpoint: tapo-onvif-desk
22:34:20.320Z - Discovered 7 ONVIF services for endpoint 'tapo-desk/tapo-onvif-desk'
22:34:20.361Z - Discovered device: tp-link Tapo C210 (746157d0)
22:34:20.997Z - Discovery completed: manufacturer: tp-link, model: Tapo C210
22:34:21.613Z - Endpoint status reported: tapo-desk_tapo-onvif-desk
```

**Endpoint health status:** `Available` ✅

### ✅ RESOLVED — Camera is tp-link Tapo C210, endpoint healthy

---

## Notes

- Port `2020` is the ONVIF port for Tapo cameras — confirmed correct.
- Camera IP `10.0.0.48` is on home LAN. NUC cluster pods (`10.42.0.x`) can reach it fine.
- `additionalConfiguration: "{}"` — no auth method override. Connector uses PasswordDigest (default).
- Connector pod: `azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0` in `azure-iot-operations` (StatefulSet — restarts automatically if deleted, keeping pod name but getting new IP).
- **IP pool concern**: Every pod restart gets a new IP. If connector continuously retries with wrong auth, the new IP will get banned within minutes. After several restarts for diagnostics, most of the `.10.42.0.x` pool may be banned.
- The connector secret (`azureiotoperationsconnectorforonvif-8404-612d9fbf`) is a DIFFERENT secret from the SecretSync secret (`tapo-desk-secretsync-72f20aa8`). Both have been verified to contain the correct values.
- PowerShell `$` expansion bug: always use single quotes when setting KV secrets with `az keyvault secret set --value '...'`.
