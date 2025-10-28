# Mosquitto Subscriber Troubleshooting Guide

## Common Issues and Solutions

### Issue 1: Pod Not Starting

**Symptom:**
```bash
kubectl get pods -n default -l app=mosquitto-sub
# Shows: CrashLoopBackOff or Error
```

**Diagnosis:**
```bash
kubectl describe pod -n default -l app=mosquitto-sub
kubectl logs -n default -l app=mosquitto-sub
```

**Common Causes:**

1. **Service account doesn't exist**
   ```bash
   # Check if service account exists
   kubectl get serviceaccount mqtt-client -n default
   
   # Create if missing
   kubectl create serviceaccount mqtt-client -n default
   kubectl annotate serviceaccount mqtt-client aio-broker-auth/group=telemetry-publishers -n default
   ```

2. **ConfigMap missing**
   ```bash
   # Check if CA certificate ConfigMap exists
   kubectl get configmap azure-iot-operations-aio-ca-trust-bundle -n azure-iot-operations
   
   # If missing, Azure IoT Operations may not be installed correctly
   ```

### Issue 2: Connection Refused

**Symptom in logs:**
```
Error: Connection refused
```

**Solutions:**

1. **Check broker is running**
   ```bash
   kubectl get pods -n azure-iot-operations -l app.kubernetes.io/name=aio-broker
   kubectl get service -n azure-iot-operations aio-broker
   ```

2. **Verify broker address**
   The correct address is:
   - ✅ `aio-broker.azure-iot-operations.svc.cluster.local`
   - ❌ NOT `aio-broker-frontend`
   
   Check `deployment.yaml`:
   ```yaml
   - name: MQTT_BROKER
     value: "aio-broker.azure-iot-operations.svc.cluster.local"
   ```

3. **Check port number**
   Default TLS port is `18883`:
   ```yaml
   - name: MQTT_PORT
     value: "18883"
   ```

### Issue 3: Authentication Failed

**Symptom in logs:**
```
Connection error: Bad username or password
```

**Solutions:**

1. **Verify ServiceAccountToken is mounted**
   ```bash
   kubectl exec -n default -l app=mosquitto-sub -- ls -la /var/run/secrets/tokens/
   kubectl exec -n default -l app=mosquitto-sub -- cat /var/run/secrets/tokens/broker-sat
   ```

2. **Check token audience matches broker config**
   ```bash
   # Check broker authentication config
   kubectl get brokerauthentication default -n azure-iot-operations -o yaml
   
   # Should show:
   # audiences:
   # - aio-internal
   ```
   
   Ensure `deployment.yaml` matches:
   ```yaml
   audience: aio-internal
   ```

3. **Verify service account has correct annotations**
   ```bash
   kubectl get serviceaccount mqtt-client -n default -o yaml
   
   # Should have:
   # annotations:
   #   aio-broker-auth/group: telemetry-publishers
   ```

### Issue 4: No Messages Received

**Symptom:**
Pod is running and connected, but no messages appear in logs.

**Diagnosis:**

1. **Verify topic name is correct**
   ```bash
   # Check what topic Sputnik is publishing to
   kubectl logs -n default -l app=sputnik | grep "Topic:"
   
   # Should match mosquitto-sub's MQTT_TOPIC
   kubectl get deployment mosquitto-sub -n default -o yaml | grep MQTT_TOPIC
   ```

2. **Check if Sputnik is running**
   ```bash
   kubectl get pods -n default -l app=sputnik
   kubectl logs -n default -l app=sputnik --tail=20
   ```

3. **Verify authorization allows subscription**
   ```bash
   # Check broker authorization
   kubectl get brokerauthorization -n azure-iot-operations -o yaml
   ```

4. **Test with wildcard subscription**
   Temporarily change to subscribe to all topics:
   ```yaml
   - name: MQTT_TOPIC
     value: "#"
   ```
   
   If you see messages now, it's a topic name mismatch.

### Issue 5: TLS Certificate Errors

**Symptom in logs:**
```
Error: certificate verify failed
Error: A TLS error occurred
```

**Solutions:**

1. **Check CA certificate ConfigMap exists**
   ```bash
   kubectl get configmap azure-iot-operations-aio-ca-trust-bundle -n azure-iot-operations
   ```

2. **Verify ConfigMap is mounted correctly**
   ```bash
   kubectl exec -n default -l app=mosquitto-sub -- ls -la /var/run/certs/
   kubectl exec -n default -l app=mosquitto-sub -- cat /var/run/certs/ca.crt
   ```

3. **Check volume mount in deployment.yaml**
   ```yaml
   volumeMounts:
   - name: ca-cert
     mountPath: /var/run/certs
   
   volumes:
   - name: ca-cert
     configMap:
       name: azure-iot-operations-aio-ca-trust-bundle
   ```

### Issue 6: Permission Denied

**Symptom:**
```
Error: Not authorized
```

**Solutions:**

1. **Check BrokerAuthorization policy**
   ```bash
   kubectl get brokerauthorization -n azure-iot-operations -o yaml
   ```

2. **Verify service account is in allowed group**
   ```bash
   kubectl get serviceaccount mqtt-client -n default -o yaml | grep aio-broker-auth
   
   # Should show:
   # aio-broker-auth/group: telemetry-publishers
   ```

3. **Check if topic is allowed by authorization rules**
   The authorization policy must allow the group to subscribe to your topic.

### Issue 7: Pod Exits Immediately

**Symptom:**
Pod status shows `Completed` instead of `Running`.

**Cause:**
The container command finished instead of running continuously.

**Solution:**
This shouldn't happen with the current deployment. Verify the command in `deployment.yaml` is:
```yaml
command:
  - sh
  - -c
  - |
    mosquitto_sub ...  # Should run indefinitely
```

### Issue 8: Out of Memory

**Symptom:**
```
OOMKilled
```

**Solution:**
Increase memory limits in `deployment.yaml`:
```yaml
resources:
  limits:
    memory: "256Mi"  # Increase from 128Mi
```

## Diagnostic Commands

### Check Pod Status
```bash
kubectl get pods -n default -l app=mosquitto-sub
kubectl describe pod -n default -l app=mosquitto-sub
```

### View Logs
```bash
# Current logs
kubectl logs -n default -l app=mosquitto-sub

# Follow logs
kubectl logs -n default -l app=mosquitto-sub -f

# Previous pod logs (if crashed)
kubectl logs -n default -l app=mosquitto-sub --previous
```

### Interactive Shell
```bash
# Get a shell in the pod
kubectl exec -it -n default -l app=mosquitto-sub -- sh

# Inside the pod, test connection manually
mosquitto_sub \
  --host aio-broker.azure-iot-operations.svc.cluster.local \
  --port 18883 \
  --topic "sputnik/beep" \
  --verbose \
  --cafile /var/run/certs/ca.crt \
  -D CONNECT authentication-method 'K8S-SAT' \
  -D CONNECT authentication-data "$(cat /var/run/secrets/tokens/broker-sat)"
```

### Check Network Connectivity
```bash
# Test DNS resolution
kubectl exec -n default -l app=mosquitto-sub -- nslookup aio-broker.azure-iot-operations.svc.cluster.local

# Test broker port
kubectl exec -n default -l app=mosquitto-sub -- nc -zv aio-broker.azure-iot-operations.svc.cluster.local 18883
```

### Verify ServiceAccountToken
```bash
# Check token exists and has content
kubectl exec -n default -l app=mosquitto-sub -- cat /var/run/secrets/tokens/broker-sat

# Decode token to see contents (for debugging)
kubectl exec -n default -l app=mosquitto-sub -- cat /var/run/secrets/tokens/broker-sat | base64 -d
```

## Debug Mode

To get more verbose output, you can modify the mosquitto_sub command to include debug flags:

```yaml
# In deployment.yaml, change the mosquitto_sub command:
mosquitto_sub \
  --host ${MQTT_BROKER} \
  --port ${MQTT_PORT} \
  --topic "${MQTT_TOPIC}" \
  --debug \              # Add this
  --verbose \
  ...
```

## Compare with Working Sputnik

If Sputnik works but mosquitto-sub doesn't:

1. **Both use the same service account**: `mqtt-client`
2. **Both use the same broker**: `aio-broker.azure-iot-operations.svc.cluster.local`
3. **Both use the same authentication**: K8S-SAT with audience `aio-internal`
4. **Both use TLS on port 18883**

Check differences:
```bash
# Compare deployments
kubectl get deployment sputnik -n default -o yaml > sputnik.yaml
kubectl get deployment mosquitto-sub -n default -o yaml > mosquitto-sub.yaml
diff sputnik.yaml mosquitto-sub.yaml
```

## Still Having Issues?

1. Check the broker logs:
   ```bash
   kubectl logs -n azure-iot-operations -l app.kubernetes.io/name=aio-broker --tail=100
   ```

2. Verify Azure IoT Operations is healthy:
   ```bash
   kubectl get pods -n azure-iot-operations
   ```

3. Check if Sputnik can publish:
   ```bash
   kubectl logs -n default -l app=sputnik --tail=20
   ```

4. Review the setup guide: See [README.md](README.md)

## Contact

If you continue to experience issues, gather the following information:
- Pod describe output: `kubectl describe pod -n default -l app=mosquitto-sub`
- Pod logs: `kubectl logs -n default -l app=mosquitto-sub`
- Service account: `kubectl get serviceaccount mqtt-client -n default -o yaml`
- Broker authentication: `kubectl get brokerauthentication default -n azure-iot-operations -o yaml`
