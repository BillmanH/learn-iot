# AIO ONVIF Connector Bug: Unauthenticated Probe Incompatibility

## Summary

The AIO ONVIF connector (`mcr.microsoft.com/azureiotoperations/akri-connectors/onvif:1.3.4`) unconditionally sends an **unauthenticated** `GetDeviceInformation` SOAP request as a probe before attempting any authenticated calls. Some cameras — including Tapo cameras on default post-factory-reset security settings — require authentication for **all** ONVIF requests, including `GetDeviceInformation`. This makes the connector permanently unable to connect to these cameras.

---

## Observed Behaviour

### Connector startup sequence (logged within 100ms)

```
22:06:55.560Z - Device endpoint created: tapo-desk/tapo-onvif-desk
22:06:55.648Z - Failed to connect to endpoint 'tapo-onvif-desk':
                Fault { code: SOAP-ENV:Sender, subcode: ter:NotAuthorized,
                reason: "Authority failure" }
22:06:55.648Z - Stored unhealthy endpoint in state (will retry periodically)
```

The error occurs 88ms after endpoint creation — far too fast for a credential exchange. This is the unauthenticated probe failing.

### What the connector sends (from tcpdump)

**Request (unauthenticated probe):**
```xml
POST /onvif/device_service HTTP/1.1
Content-Type: application/soap+xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Body>
    <GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/>
  </s:Body>
</s:Envelope>
```

No `<s:Header>` / `<wsse:Security>` block — no credentials at all.

**Camera response:**
```
HTTP/1.1 200 OK   ← (or 400 if IP is banned)
...
ter:NotAuthorized / Authority failure
```

The connector receives the `NotAuthorized` fault, logs it as a connection failure, marks the endpoint unhealthy, and enters a retry backoff. It **never** attempts a follow-up request with credentials.

### What a working authenticated request looks like

A successful authenticated `GetDeviceInformation` from the same endpoint (confirmed via `onvif_auth_test.py` from pod IP `10.42.0.126`):

```xml
POST /onvif/device_service HTTP/1.1
Content-Type: application/soap+xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
            xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
  <s:Header>
    <wsse:Security>
      <wsse:UsernameToken>
        <wsse:Username>homecamnet</wsse:Username>
        <wsse:Password Type="...#PasswordDigest">{sha1_digest}</wsse:Password>
        <wsse:Nonce EncodingType="...#Base64Binary">{nonce_b64}</wsse:Nonce>
        <wsu:Created>{timestamp}</wsu:Created>
      </wsse:UsernameToken>
    </wsse:Security>
  </s:Header>
  <s:Body>
    <GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/>
  </s:Body>
</s:Envelope>
```

This returns `HTTP 200` with full device info. The camera accepts the credentials — there is no issue with the credentials themselves.

---

## Environment

| Item | Value |
|---|---|
| Camera | Tapo C520WS (or similar) at `10.0.0.48:2020` |
| ONVIF endpoint | `http://10.0.0.48:2020/onvif/device_service` |
| Connector image | `mcr.microsoft.com/azureiotoperations/akri-connectors/onvif:1.3.4` |
| Connector StatefulSet | `azureiotoperationsconnectorforonvif-8404-612d9fbf-ss` in `azure-iot-operations` |
| Credentials | username `homecamnet`, password `40z$jiOdg6`, PasswordDigest only |
| Auth method | `UsernamePassword` via K8s SecretSync from Key Vault |
| K8s secret | `azureiotoperationsconnectorforonvif-8404-612d9fbf` |

---

## Root Cause

The connector's connection logic is:

1. Send unauthenticated `GetDeviceInformation` → if success, proceed to authenticated calls
2. If probe fails with `ter:NotAuthorized` → mark endpoint unhealthy, schedule retry, **stop**

The connector treats `ter:NotAuthorized` on the probe as a fatal connectivity failure rather than a signal to retry with credentials. This is incorrect behaviour for cameras that require auth on all requests.

The ONVIF spec does not require `GetDeviceInformation` to be accessible without credentials — it is a capability of permissive cameras, not a requirement. The connector assumes all cameras behave permissively.

---

## Side Effects Discovered During Investigation

### Tapo brute-force IP banning

Because the connector retries every ~5 minutes with a bad credential setup (the original issue was a wrong username casing + truncated password), it accumulated hundreds of failed auth attempts. Tapo firmware responded by banning source IPs at the HTTP level:

- Banned IPs receive `HTTP 400 Bad Request` on **all** requests — even the unauthenticated probe
- The ban list is stored in NVRAM and **survives power cycles**
- Only a factory reset clears it
- The entire `10.42.0.0/24` pod CIDR was eventually exhausted

This is a secondary problem caused by the primary credential misconfiguration, but it is worth noting that the connector's retry behaviour (indefinite retries every 5 min) can trigger camera-level IP bans with no indication in the connector logs beyond the ongoing `ter:NotAuthorized`.

---

## Requirements for a Custom AKRI Connector

A replacement connector for this camera must:

### 1. Always authenticate from the first request

Send `wsse:UsernameToken` with **PasswordDigest** on every request, including the initial probe.

PasswordDigest formula:
```
digest = base64( SHA1( nonce_bytes + created_utf8 + password_utf8 ) )
```

Where:
- `nonce_bytes` = 20 random bytes (new per request)
- `created` = UTC timestamp in ISO 8601 format (`%Y-%m-%dT%H:%M:%SZ`)
- `nonce` in SOAP = base64(nonce_bytes)

**PasswordText is rejected by this camera.** Only PasswordDigest works.

### 2. Username is case-sensitive

The camera stores ONVIF usernames case-sensitively. `homecamnet` ≠ `Homecamnet`. The connector must use the exact string from the secret without any normalisation.

### 3. Clock tolerance

Camera clock skew at time of testing: **+0.7s** (camera ahead of NUC). Well within ONVIF's 300s window. The connector should tolerate skew up to ~60s.

### 4. Target the correct endpoint

ONVIF device service: `http://10.0.0.48:2020/onvif/device_service`

This camera uses port 2020 (not the standard 80 or 8080). The port is set in the AIO device endpoint ARM resource.

### 5. Events of interest

The asset (`tapo-desk-onvif`) is configured with these ONVIF event topics:

- `RuleEngine/CellMotionDetector/Motion`
- `RuleEngine/TamperDetector/Tamper`
- `RuleEngine/PeopleDetector/People`
- `RuleEngine/TPSmartEventDetector/TPSmartEvent`
- `RuleEngine/LineCrossDetector/LineCross`
- `RuleEngine/IntrusionDetector/Intrusion`

The connector should subscribe to these via ONVIF `CreatePullPointSubscription` / `PullMessages` or WS-BaseNotification.

### 6. Credentials from K8s secret

Read from mounted secret or environment variable — do not hardcode. The AIO ONVIF connector reads from:

```
/etc/akri/secrets/device_endpoint_auth/{secret-name}/{username-key}
/etc/akri/secrets/device_endpoint_auth/{secret-name}/{password-key}
```

Or via the standard K8s secret mount pattern.

### 7. Do not re-ban the camera

Rate-limit retries on `ter:NotAuthorized` responses. If the camera returns repeated auth failures, back off exponentially and alert — do not hammer indefinitely. Suggested maximum: 3 retries, then 10-minute backoff.

---

## Testing

Use `issues/onvif_auth_test.py` to validate against the camera before deploying a connector:

```bash
# From NUC or a cluster pod
python3 ~/learn-iothub/issues/onvif_auth_test.py
```

Expected output:
```
=== Clock skew check ===
  Camera=...  NUC=...  skew=+0.7s  [OK]

=== PasswordDigest tests ===
  Digest user='homecamnet': SUCCESS: ...
  Digest user='Homecamnet': FAIL HTTP 400: subcode=ter:NotAuthorized ...

=== PasswordText tests ===
  Text   user='homecamnet': FAIL HTTP 400: ter:NotAuthorized
```

The custom connector should produce equivalent authenticated requests to the ones that return `SUCCESS` here.

---

## Resolution (2026-05-11)

The `additionalConfiguration` field on the AIO device endpoint supports a `fallbackToUsernameTokenAuth` flag. Setting it to `true` causes the connector to send credentials even when the unauthenticated probe fails:

```json
{"acceptInvalidHostnames":true,"acceptInvalidCertificates":true,"fallbackToUsernameTokenAuth":true}
```

Set via the AIO portal: **IoT Operations instance → Devices → tapo-desk → tapo-onvif-desk → Additional configuration**.

After the update the connector immediately retried, sent authenticated credentials, and the endpoint became `Available`:

```
22:34:20.287Z - Successfully connected to endpoint: tapo-onvif-desk
22:34:20.320Z - Discovered 7 ONVIF services
22:34:20.361Z - Discovered device: tp-link Tapo C210 (746157d0)
```

**The bug is a documentation/default issue** — `fallbackToUsernameTokenAuth` is not the default, and the connector gives no indication that this flag exists when it logs `ter:NotAuthorized`. A custom connector should either always authenticate or expose this behaviour clearly.

---

## References

- [ONVIF Core Specification](https://www.onvif.org/specs/core/ONVIF-Core-Specification.pdf) — WS-Security / UsernameToken section
- [WS-Security UsernameToken Profile](https://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0.pdf) — PasswordDigest definition
- `issues/home1-desk-tapo.md` — Full troubleshooting log for this camera
- `issues/onvif_auth_test.py` — Working Python reference implementation of PasswordDigest auth
