# IoT Operations MQTT Troubleshooting Guide

## Overview
This guide provides step-by-step troubleshooting for Azure IoT Operations MQTT connectivity issues, specifically for the SpaceShip Factory Simulator application.

## Current Issue Analysis

### Observed Symptoms
- **CONNACK reason code: 134** - "Bad username or password"
- **Disconnect code: 2** - Protocol error or authentication failure
- App repeatedly waiting for connection
- Queue depth increasing while connection fails

### Root Cause Analysis
The error indicates **ServiceAccountToken (K8S-SAT) authentication failure**. This can happen due to:

1. **Token Issues**
   - Token file not mounted correctly
   - Token expired or invalid
   - Wrong token audience

2. **Broker Configuration**
   - MQTT broker not accepting K8S-SAT authentication
   - Audience mismatch between token and broker
   - Broker service account permissions

3. **Network Issues**
   - DNS resolution failures
   - Port accessibility
   - Service mesh/proxy interference

## Troubleshooting Steps

### 1. Verify Pod Status and Logs

```bash
# Check if the pod is running
kubectl get pods -n default | grep spaceshipfactorysim

# Get detailed pod information
kubectl describe pod -l app=spaceshipfactorysim -n default

# Check application logs
kubectl logs -l app=spaceshipfactorysim -n default --tail=50

# Follow logs in real-time
kubectl logs -l app=spaceshipfactorysim -n default -f
```

### 2. Verify ServiceAccountToken Mount

```bash
# Check if token is mounted correctly
kubectl exec -it deployment/spaceshipfactorysim -n default -- ls -la /var/run/secrets/tokens/

# Verify token content (check length and format)
kubectl exec -it deployment/spaceshipfactorysim -n default -- cat /var/run/secrets/tokens/broker-sat | wc -c

# Check token audience and other claims (decode JWT - first part is header, second is payload)
kubectl exec -it deployment/spaceshipfactorysim -n default -- cat /var/run/secrets/tokens/broker-sat | cut -d. -f2 | base64 -d 2>/dev/null || echo "Unable to decode token payload"
```

### 3. Verify Service Account Configuration

```bash
# Check if service account exists
kubectl get serviceaccount mqtt-client -n default

# Verify service account is referenced in deployment
kubectl get deployment spaceshipfactorysim -n default -o yaml | grep serviceAccountName

# Check service account token projection
kubectl get deployment spaceshipfactorysim -n default -o yaml | grep -A 10 "serviceAccountToken:"
```

### 4. Test MQTT Broker Connectivity

```bash
# Test DNS resolution of MQTT broker
kubectl exec -it deployment/spaceshipfactorysim -n default -- nslookup aio-broker.azure-iot-operations.svc.cluster.local

# Test network connectivity to MQTT broker
kubectl exec -it deployment/spaceshipfactorysim -n default -- nc -zv aio-broker.azure-iot-operations.svc.cluster.local 18883

# Alternative connectivity test
kubectl exec -it deployment/spaceshipfactorysim -n default -- telnet aio-broker.azure-iot-operations.svc.cluster.local 18883
```

### 5. Verify Azure IoT Operations Broker Status

```bash
# Check if Azure IoT Operations is installed and running
kubectl get pods -n azure-iot-operations

# Check broker service
kubectl get service aio-broker -n azure-iot-operations

# Check broker configuration
kubectl get broker -n azure-iot-operations -o yaml

# Check broker authentication configuration
kubectl get brokerauthentication -n azure-iot-operations -o yaml
```

### 6. Debug Token Authentication

```bash
# Check projected service account token details
kubectl exec -it deployment/spaceshipfactorysim -n default -- sh -c '
  TOKEN=$(cat /var/run/secrets/tokens/broker-sat)
  echo "Token length: $(echo $TOKEN | wc -c)"
  echo "Token preview: $(echo $TOKEN | cut -c1-50)..."
  echo "Token format check: $(echo $TOKEN | cut -d. -f1,2,3 | wc -w)"
'

# Verify token expiration
kubectl exec -it deployment/spaceshipfactorysim -n default -- sh -c '
  TOKEN=$(cat /var/run/secrets/tokens/broker-sat)
  # Extract payload (second part of JWT)
  PAYLOAD=$(echo $TOKEN | cut -d. -f2)
  # Decode base64 and check expiration
  echo $PAYLOAD | base64 -d 2>/dev/null | grep -o "\"exp\":[0-9]*" || echo "Cannot decode token expiration"
'
```

### 7. Application-Level Debugging

```bash
# Enable debug mode in Python MQTT client
kubectl exec -it deployment/spaceshipfactorysim -n default -- python3 -c "
import paho.mqtt.client as mqtt
import ssl
print('MQTT Client version:', mqtt.__version__)
print('SSL version:', ssl.OPENSSL_VERSION)
"

# Test with minimal MQTT client
kubectl exec -it deployment/spaceshipfactorysim -n default -- python3 -c "
import os
token_path = '/var/run/secrets/tokens/broker-sat'
if os.path.exists(token_path):
    with open(token_path, 'r') as f:
        token = f.read().strip()
    print(f'Token found: {len(token)} characters')
    print(f'Token starts with: {token[:20]}...')
else:
    print('ERROR: Token file not found')
"
```

## Common Solutions

### Solution 1: Fix DNS Resolution Issues

**Scenario**: DNS resolution fails for FQDN but short names work, port connectivity is fine.

**Symptoms**:
- `❌ DNS resolution failed` for `aio-broker.azure-iot-operations.svc.cluster.local`
- `✅ Port 18883 is accessible (via Python)`
- `✅ Short service name resolution works`
- Messages being generated but connection issues

**Root Cause**: DNS caching issues or stale DNS records in the pod.

**Fix**:
```bash
# Restart deployment to refresh DNS cache and network connections
kubectl rollout restart deployment/spaceshipfactorysim -n default

# Wait for rollout to complete
kubectl rollout status deployment/spaceshipfactorysim -n default

# Verify fix
kubectl logs -l app=spaceshipfactorysim -n default --tail=20 | grep -E "(Connected|Messages|Rate)"
```

**Validation**: Look for:
- Messages being sent with positive rate (e.g., "Message Rate: 2.70 msg/sec")
- Queue depth at or near 0
- Batch message generation without connection errors

### Solution 2: Fix Service Account Token Configuration

If the token is not mounted or has wrong audience:

```bash
# Delete and recreate service account
kubectl delete serviceaccount mqtt-client -n default --ignore-not-found
kubectl create serviceaccount mqtt-client -n default

# Restart deployment to get fresh token
kubectl rollout restart deployment/spaceshipfactorysim -n default
```

### Solution 3: Fix Network Connectivity Issues (Alternative Approach)

**Scenario**: When FQDN resolution completely fails but service exists.

**Alternative DNS Names to Try**: Update your deployment to use different service names:

```yaml
# In deployment.yaml, try these alternatives:
env:
- name: MQTT_BROKER
  value: "aio-broker.azure-iot-operations"  # Short name (often works)
# OR
- name: MQTT_BROKER  
  value: "10.43.131.208"  # Direct cluster IP (from service details)
```

**Apply the change**:
```bash
kubectl apply -f deployment.yaml
kubectl rollout status deployment/spaceshipfactorysim -n default
```

### Solution 4: Verify Broker Authentication Configuration

Check if the broker accepts K8S-SAT authentication:

```bash
# Check broker authentication methods
kubectl get brokerauthentication -n azure-iot-operations -o yaml | grep -A 5 -B 5 "kubernetes"

# If K8S-SAT is not configured, you may need to reconfigure the broker
# This typically requires Azure IoT Operations management tools
```

### Solution 3: Update Token Audience

If audience mismatch is detected:

```yaml
# Update deployment.yaml volume configuration
volumes:
- name: broker-sat
  projected:
    sources:
    - serviceAccountToken:
        path: broker-sat
        expirationSeconds: 86400
        audience: aio-internal  # Ensure this matches broker configuration
```

### Solution 5: Switch to X.509 Authentication (Fallback)

If ServiceAccountToken continues to fail:

1. Follow the X.509 setup guide in `AUTH_COMPARISON.md`
2. Update environment variables in deployment:
   ```yaml
   env:
   - name: MQTT_AUTH_METHOD
     value: "X509"  # Switch from K8S-SAT to X509
   ```

### Solution 6: Network Connectivity Issues

If network connectivity is the problem:

```bash
# Check for network policies blocking traffic
kubectl get networkpolicy -n default
kubectl get networkpolicy -n azure-iot-operations

# Check service mesh/proxy configuration
kubectl get pods -n default -o wide
kubectl describe pod -l app=spaceshipfactorysim -n default | grep -A 10 -B 10 "proxy\|mesh\|sidecar"
```

## Validation Steps

After applying fixes, validate the connection:

```bash
# Check if connection is successful
kubectl logs -l app=spaceshipfactorysim -n default --tail=20 | grep -E "(Connected|✓|Failed|✗)"

# Monitor message flow
kubectl logs -l app=spaceshipfactorysim -n default -f | grep -E "(Batch|messages|sent|failed)"

# Check application statistics
kubectl logs -l app=spaceshipfactorysim -n default --tail=50 | grep -E "(Messages|Rate|Queue)"
```

## Prevention Measures

### 1. Health Checks
Add comprehensive health checks to the deployment:

```yaml
readinessProbe:
  exec:
    command:
    - python3
    - -c
    - |
      import os
      import sys
      # Check if token exists and is readable
      token_path = '/var/run/secrets/tokens/broker-sat'
      if not os.path.exists(token_path):
          sys.exit(1)
      try:
          with open(token_path, 'r') as f:
              token = f.read().strip()
          if len(token) < 100:  # JWT tokens are typically much longer
              sys.exit(1)
      except Exception:
          sys.exit(1)
  initialDelaySeconds: 5
  periodSeconds: 10
```

### 2. Monitoring and Alerting
Set up monitoring for:
- Connection failures
- Token expiration warnings
- Message queue depth
- Network connectivity

### 3. Automated Recovery
Implement circuit breaker patterns and automatic reconnection with exponential backoff (already implemented in the application).

## Advanced Debugging

### Enable MQTT Client Debug Logging

Add to `app.py` for detailed MQTT debugging:

```python
import logging
logging.basicConfig(level=logging.DEBUG)

# Enable MQTT client logging
mqtt_logger = logging.getLogger("paho")
mqtt_logger.setLevel(logging.DEBUG)
mqtt_logger.addHandler(logging.StreamHandler())
```

### Capture Network Traffic

```bash
# Install tcpdump in the pod (if needed for deep debugging)
kubectl exec -it deployment/spaceshipfactorysim -n default -- sh -c "
  # Note: This requires privilege escalation and may not work in restricted environments
  apt-get update && apt-get install -y tcpdump
  tcpdump -i eth0 -n port 18883
"
```

## Related Documentation

- [Azure IoT Operations Authentication Guide](https://docs.microsoft.com/azure/iot-operations/)
- [AUTH_COMPARISON.md](./AUTH_COMPARISON.md) - Detailed auth method comparison
- [Kubernetes ServiceAccount Tokens](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- [MQTT v5 Authentication](https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html)

## Contact and Support

For additional support:
- Check Azure IoT Operations documentation
- Review Kubernetes cluster logs
- Consult with platform team for broker configuration issues