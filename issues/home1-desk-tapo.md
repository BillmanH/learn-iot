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
| Connector two-phase auth | tcpdump capture 2026-05-11 | ✅ Connector sends **unauthenticated** `GetDeviceInformation` first, then a second **authenticated** request. The `NotAuthorized` in the logs comes from this second authenticated call, NOT the probe. |
| IP lockout behavior | tcpdump: `.32` banned (unauthenticated probe also fails), `.34` fresh (unauthenticated probe succeeds but authenticated follow-up fails) | ✅ Camera bans IPs that make many failed auth attempts. Bans survive power cycle (stored in NVRAM). |

**Clock skew notes:** Ruled out. The Python `onvif_auth_test.py` using the SAME node clock succeeds with the same credentials. Clock skew cannot explain why the connector fails.

**IP lockout notes:** Pod IPs `.27`, `.28`, `.29`, `.30`, `.32` are known to be banned. Pod IP `.34` got through the unauthenticated probe but still failed on the authenticated call — this means the failure is NOT just IP lockout. Something about the connector's authenticated WS-Security token is wrong.

### Confirmed Correct Credentials

- **Username:** `homecamnet` (lowercase — verified working via direct SOAP test from cluster pod)
- **Password:** `40z$jiOdg6` (10 chars, PasswordDigest — verified working via direct SOAP test)
- Both are set correctly in Key Vault `iot-opps-keys`, synced to K8s SecretSync secret `tapo-desk-secretsync-72f20aa8`, and mounted into the connector pod at `/etc/akri/secrets/device_endpoint_auth/azureiotoperationsconnectorforonvif-8404-612d9fbf/`.

### Current Mystery (2026-05-11)

All infrastructure is correct and credentials are verified working via a Python SOAP test pod on the same cluster using the same node clock. Yet the connector pod still gets `ter:NotAuthorized` immediately on startup. The connector behavior:
- Sends unauthenticated `GetDeviceInformation` probe first (succeeds on fresh IPs)
- Then sends an authenticated follow-up request with WS-Security → gets `NotAuthorized`
- Logs "Failed to connect: ter:NotAuthorized" and retries every ~5 minutes
- Only logs the first failure per retry cycle

Remaining unknown: **what exactly is in the connector's WS-Security `UsernameToken` block?** Specifically:
- Is the `wsse:Username` value exactly `homecamnet`?
- Is the `PasswordDigest` computed correctly?
- Is there any encoding or transformation happening to the password before hashing?

The pcap from 2026-05-11 captured the unauthenticated probe but the full response body to `.34` was truncated (only first 1398 bytes = namespace declarations). The authenticated follow-up was not captured. Need `collect_onvif_diag2.sh` to get a full, untruncated capture.

---

## Next Steps

### 1. Capture the authenticated SOAP body (highest priority)

Run the diagnostic script [issues/collect_onvif_diag.sh](collect_onvif_diag.sh) on the NUC:

```bash
cd ~/learn-iothub
git pull
chmod +x issues/collect_onvif_diag.sh
bash issues/collect_onvif_diag.sh
```

Then upload and retrieve:
```bash
# The script prints the upload command at the end. Copy and run it.
kubectl create configmap onvif-diag-log --from-file=diag.log=<path_from_script> \
  -n azure-iot-operations --dry-run=client -o yaml | kubectl apply -f -
```

From Windows:
```powershell
kubectl get configmap onvif-diag-log -n azure-iot-operations -o jsonpath='{.data.diag\.log}'
```

**What to look for in the output:**
- Section 1: camera vs NUC clock diff (should be < 300s)
- Section 4a (strings): find `wsse:Username`, `wsse:Password`, `wsse:Nonce`, `wsu:Created` in the POST body
- Section 4b: full tcpdump decode showing the authenticated SOAP request to the camera

### 2. If capture shows wrong username/password in WS-Security

Check if the connector is applying any transformation. Look for the `Username` field in the SOAP body — it should be exactly `homecamnet` with no padding, prefix, or suffix.

### 3. Alternative: Python MITM proxy

If tcpdump still doesn't capture the full authenticated body, run a simple Python proxy on the NUC:

```bash
# Run on NUC - listens on 18080, logs requests, forwards to camera
python3 - <<'EOF'
from http.server import HTTPServer, BaseHTTPRequestHandler
import urllib.request, sys

class LoggingProxy(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        print("\n=== CONNECTOR REQUEST ===")
        print(body.decode('utf-8', errors='replace'))
        req = urllib.request.Request("http://10.0.0.48:2020" + self.path, body, dict(self.headers))
        try:
            resp = urllib.request.urlopen(req, timeout=10)
            rb = resp.read()
            self.send_response(resp.status)
            for h, v in resp.getheaders():
                if h.lower() not in ('transfer-encoding', 'connection'):
                    self.send_header(h, v)
            self.end_headers()
            self.wfile.write(rb)
            print("=== CAMERA RESPONSE ===")
            print(rb.decode('utf-8', errors='replace'))
        except Exception as e:
            print("PROXY ERROR:", e)
            self.send_error(502, str(e))
    def log_message(self, *args): pass

HTTPServer(("0.0.0.0", 18080), LoggingProxy).serve_forever()
EOF
```

Then update the device endpoint address in the AIO portal from `http://10.0.0.48:2020/onvif/device_service` to `http://<NUC_LAN_IP>:18080/onvif/device_service`, watch the proxy output, then restore.

---

## Notes

- Port `2020` is the ONVIF port for Tapo cameras — confirmed correct.
- Camera IP `10.0.0.48` is on home LAN. NUC cluster pods (`10.42.0.x`) can reach it fine.
- `additionalConfiguration: "{}"` — no auth method override. Connector uses PasswordDigest (default).
- Connector pod: `azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0` in `azure-iot-operations` (StatefulSet — restarts automatically if deleted, keeping pod name but getting new IP).
- **IP pool concern**: Every pod restart gets a new IP. If connector continuously retries with wrong auth, the new IP will get banned within minutes. After several restarts for diagnostics, most of the `.10.42.0.x` pool may be banned.
- The connector secret (`azureiotoperationsconnectorforonvif-8404-612d9fbf`) is a DIFFERENT secret from the SecretSync secret (`tapo-desk-secretsync-72f20aa8`). Both have been verified to contain the correct values.
- PowerShell `$` expansion bug: always use single quotes when setting KV secrets with `az keyvault secret set --value '...'`.
