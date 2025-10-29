# Authentication Method Comparison

## Overview

This document compares the two authentication methods available for connecting to Azure IoT Operations MQTT broker from in-cluster applications.

## Quick Decision

**Use ServiceAccountToken if:**
- ✅ Your application runs **inside** the Kubernetes cluster
- ✅ You want **simpler setup** with no certificate management
- ✅ You want **automatic token renewal**
- ✅ You're following **Microsoft's recommendations** for production

**Use X.509 Certificates if:**
- ⚠️ Your application runs **outside** the Kubernetes cluster
- ⚠️ You need **long-lived credentials** (years vs hours)
- ⚠️ You have **external devices** connecting to the broker
- ⚠️ You need **mutual TLS authentication** for regulatory compliance

## Detailed Comparison

| Feature | ServiceAccountToken | X.509 Certificates |
|---------|--------------------|--------------------|
| **Setup Complexity** | ⭐⭐⭐⭐⭐ Simple | ⭐⭐ Complex |
| **Certificate Management** | Not needed | Manual creation, renewal, storage |
| **Secret Management** | Automatic | GitHub Secrets + K8s Secret |
| **Credential Rotation** | Automatic (24h default) | Manual process |
| **Best for** | In-cluster apps | External clients |
| **Production Ready** | ✅ Recommended | ✅ Supported |
| **Microsoft Recommendation** | **Primary choice** | Secondary option |
| **Token/Cert Lifetime** | 24 hours (auto-renewed) | 365 days (manual renewal) |
| **Authentication Protocol** | MQTT v5 Enhanced Auth | TLS Client Certificates |
| **Broker Config Required** | Already configured | Requires X.509 method + ConfigMap |
| **Initial Setup Time** | ~5 minutes | ~30 minutes |
| **Ongoing Maintenance** | Zero | Certificate rotation needed |

## Implementation Comparison

### ServiceAccountToken Setup

**Prerequisites:**
- None (broker already configured)

**Steps:**
1. Create service account: `kubectl create serviceaccount mqtt-client`
2. Update deployment with `serviceAccountName: mqtt-client`
3. Mount token volume (Kubernetes does this automatically)
4. Update app to read token and use MQTT v5 enhanced auth

**Files to modify:**
- `deployment.yaml` (add serviceAccountName, volume mount)
- `app.py` (read token, configure MQTT v5 auth)

**Secrets needed:**
- None (token is auto-generated and mounted)

**Maintenance:**
- None (Kubernetes handles everything)

---

### X.509 Certificate Setup

**Prerequisites:**
- OpenSSL or similar tool
- Access to Azure CLI or Portal
- Understanding of PKI concepts

**Steps:**
1. Create client CA certificate
2. Create ConfigMap with CA cert
3. Enable X.509 auth on broker (via Azure CLI/Portal)
4. Generate client certificate signed by CA
5. Store certificates in GitHub Secrets
6. Update GitHub Actions workflow
7. Create Kubernetes secret
8. Mount certificates in deployment
9. Update app to use TLS with client certs

**Files to modify:**
- `deployment.yaml` (add secret volume mount)
- `app.py` (configure TLS with client certs)
- `.github/workflows/deploy-iot-edge.yaml` (create secret from GitHub Secrets)

**Secrets needed:**
- GitHub Secrets: `MQTT_BROKER_CA_CERT`, `MQTT_CLIENT_CERT`, `MQTT_CLIENT_KEY`
- Kubernetes Secret: `aio-mqtt-certs`

**Maintenance:**
- Renew certificates before expiration (annually)
- Update secrets when certificates rotate
- Monitor certificate expiration dates

## Code Comparison

### ServiceAccountToken - Connection Setup

```python
# Read token from mounted volume
token = Path('/var/run/secrets/tokens/broker-sat').read_text().strip()

# Configure MQTT v5 enhanced authentication
auth_properties = mqtt.Properties(packetType=1)
auth_properties.AuthenticationMethod = 'K8S-SAT'
auth_properties.AuthenticationData = token.encode('utf-8')

# Connect with TLS + SAT
client.tls_set(cert_reqs=ssl.CERT_NONE)
client.connect(broker, port, properties=auth_properties)
```

### X.509 - Connection Setup

```python
# Configure TLS with client certificates
client.tls_set(
    ca_certs="/certs/broker-ca.crt",
    certfile="/certs/client.crt",
    keyfile="/certs/client.key",
    cert_reqs=ssl.CERT_REQUIRED
)

# Connect with mutual TLS
client.connect(broker, port)
```

## Deployment Comparison

### ServiceAccountToken - deployment.yaml

```yaml
spec:
  serviceAccountName: mqtt-client  # ← Only addition needed
  containers:
  - name: sputnik
    env:
    - name: MQTT_AUTH_METHOD
      value: "K8S-SAT"
    volumeMounts:
    - name: broker-sat
      mountPath: /var/run/secrets/tokens
  volumes:
  - name: broker-sat
    projected:
      sources:
      - serviceAccountToken:
          path: broker-sat
          expirationSeconds: 86400
          audience: aio-internal
```

### X.509 - deployment.yaml

```yaml
spec:
  containers:
  - name: sputnik
    env:
    - name: MQTT_BROKER_CA_CERT
      value: "/certs/broker-ca.crt"
    - name: MQTT_CLIENT_CERT
      value: "/certs/client.crt"
    - name: MQTT_CLIENT_KEY
      value: "/certs/client.key"
    volumeMounts:
    - name: mqtt-certs
      mountPath: "/certs"
  volumes:
  - name: mqtt-certs
    secret:
      secretName: aio-mqtt-certs  # Must be created separately
```

## Security Comparison

| Security Aspect | ServiceAccountToken | X.509 Certificates |
|----------------|--------------------|--------------------|
| **Encryption** | TLS (same as X.509) | TLS |
| **Authentication** | Token-based | Certificate-based |
| **Credential Theft Risk** | Low (short-lived, auto-renewed) | Medium (long-lived) |
| **Credential Storage** | Automatic by K8s | Manual (secrets/files) |
| **Revocation** | Delete service account | Certificate revocation list |
| **Audit Trail** | K8s service account | Certificate serial numbers |
| **Compromise Recovery** | Delete SA, redeploy | Revoke cert, issue new |

## Migration Path

### From X.509 to ServiceAccountToken

1. Run setup script: `./setup-sat-auth.ps1`
2. Update `deployment.yaml` (remove cert volumes, add serviceAccountName)
3. Update `app.py` (remove TLS cert config, add SAT token reading)
4. Deploy: `kubectl apply -f deployment.yaml`
5. Verify connection in logs
6. (Optional) Delete certificate secrets: `kubectl delete secret aio-mqtt-certs`

### From ServiceAccountToken to X.509

1. Follow steps in `X509_AUTH_SETUP.md`
2. Create client CA and certificates
3. Enable X.509 on broker
4. Update deployment and app code
5. Deploy updated application
6. (Optional) Remove service account

## Performance Comparison

| Metric | ServiceAccountToken | X.509 Certificates |
|--------|--------------------|--------------------|
| Connection Time | ~50ms | ~100ms (TLS handshake) |
| Token/Cert Size | ~1KB | ~2-4KB (cert chain) |
| Validation Overhead | Token Review API call | Certificate chain validation |
| Memory Usage | Minimal | Minimal |
| Network Overhead | Same | Same |

**Note:** Performance differences are negligible for typical IoT workloads.

## Troubleshooting Comparison

### Common Issues

**ServiceAccountToken:**
- ❌ Token not found → Check volume mount
- ❌ Authentication failed → Verify audience matches broker config
- ❌ Connection refused → Check broker is running

**X.509:**
- ❌ CERTIFICATE_VERIFY_FAILED → Wrong CA certificate
- ❌ TLSV1_ALERT_UNKNOWN_CA → Broker doesn't trust client CA
- ❌ Bad username/password → Wrong auth method or broker config
- ❌ Certificate expired → Renew certificates

## Recommendation for Sputnik

**Use ServiceAccountToken** because:

1. ✅ Sputnik runs **inside the cluster** (same namespace as broker)
2. ✅ **Simpler setup** - no certificate management needed
3. ✅ **Zero maintenance** - automatic token renewal
4. ✅ **Microsoft recommended** for in-cluster apps
5. ✅ **Production ready** - widely used pattern
6. ✅ **Already configured** - broker accepts SAT out of the box

The X.509 setup you attempted was adding unnecessary complexity for an in-cluster application. ServiceAccountToken is the right choice here!

## Files Provided

**For ServiceAccountToken (Recommended):**
- `SAT_AUTH_SETUP.md` - Complete setup guide
- `setup-sat-auth.ps1` - Windows setup script
- `setup-sat-auth.sh` - Linux/Mac setup script
- Updated `app.py` - With SAT authentication
- Updated `deployment.yaml` - With service account config

**For X.509 (Alternative):**
- `X509_AUTH_SETUP.md` - Complete setup guide
- `CERT_MANAGEMENT.md` - Certificate procedures

## References

- [Microsoft: Configure SAT Authentication](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication#kubernetes-service-account-tokens)
- [Microsoft: Production Guidelines](https://learn.microsoft.com/azure/iot-operations/deploy-iot-ops/concept-production-guidelines#mqtt-broker)
- [Kubernetes: Service Account Tokens](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/)
