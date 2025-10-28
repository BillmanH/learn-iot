# Certificate Management for IoT Operations

This guide explains how to manage certificates for applications connecting to Azure IoT Operations MQTT broker.

## Quick Reference: Understanding the Certificates

Azure IoT Operations MQTT broker uses **two separate certificate authorities (CAs)**:

1. **Broker Server CA** (`aio-broker-internal-ca`):
   - Used to sign the broker's server certificate
   - Clients need this CA to verify the broker's identity during TLS handshake
   - File: `broker-ca.crt`

2. **Client CA** (you create this):
   - Used to sign client certificates
   - Broker needs this CA to verify client identities during authentication
   - Must be added to the broker's authentication configuration
   - File: `client-ca.crt` (stored in ConfigMap `client-ca`)

**Important**: Your client certificate must be signed by the **Client CA**, not the Broker CA!

## Prerequisites

Before managing certificates, verify your Azure IoT Operations security settings:

1. In the Azure Portal:
   - Navigate to your IoT Operations instance
   - Select "MQTT broker" under "Settings"
   - Check the broker configuration:
     * Under "Advanced", verify "Encrypt internal traffic" is "Enabled"
     * This indicates you're running in secure mode

2. Using Azure CLI:
   ```bash
   # Get your MQTT broker settings
   az iot ops mqtt broker show \
     --resource-group <your-resource-group> \
     --instance-name <your-instance-name> \
     --name default
   
   # Look for "encryptInternalTraffic": "Enabled" in the output
   ```

If encryption is enabled, your deployment is in secure mode and ready for certificate management.

## Certificate Requirements

Applications need the following certificates to connect securely to the Azure IoT Operations MQTT broker:

1. **Client Certificate** (`client.crt`): Identifies and authenticates your application
2. **Client Private Key** (`client.key`): The private key for your client certificate
3. **CA Certificate** (`ca.crt`): The root or intermediate CA certificate that signed the broker's certificate

## Getting Certificates

### Use Azure IoT Operations Built-in Certificates

1. Access your Azure IoT Operations cluster:
   - Sign in to the [Azure Portal](https://portal.azure.com)
   - Navigate to your Azure Arc-enabled Kubernetes cluster where IoT Operations is installed
   - Select "Extensions" in the left navigation pane
   - Look for two IoT Operations extensions:
     * `azure-iot-operations-xxxxx` (your instance, with a unique suffix)
     * `azure-iot-operations-platform` (platform components)
   - The main extension should be `azure-iot-operations-xxxxx` (in your case, `azure-iot-operations-q4csz`)
   - After verifying your extension is installed and running:
     * Note the namespace used by the extension (typically `azure-iot-operations`)
     * Connect to your cluster using `kubectl`
     * Note, in my instance the cert names had changed and I was able to find them via `kubectl get secrets -n azure-iot-operations`
     
2. **Get the CA certificate** (needed to verify the broker's certificate):
   ```bash
   # Get the CA certificate from the broker's internal CA
   kubectl get secret aio-broker-internal-ca -n azure-iot-operations -o jsonpath='{.data.tls\.crt}' | base64 -d > ca.crt
   
   # Also get the CA key (needed to sign client certificates)
   kubectl get secret aio-broker-internal-ca -n azure-iot-operations -o jsonpath='{.data.tls\.key}' | base64 -d > ca.key
   ```

3. **Create a client CA certificate** (separate from the broker's internal CA):
   
   For security, create a separate CA for client authentication:
   ```bash
   # Generate a client CA certificate
   openssl genrsa -out client-ca.key 4096
   openssl req -new -x509 -days 3650 -key client-ca.key -out client-ca.crt \
     -subj "/CN=Client Root CA/O=IoT-Operations"
   ```

4. **Create a ConfigMap with the client CA** in the Azure IoT Operations namespace:
   ```bash
   kubectl create configmap client-ca \
     --from-file=ca.pem=client-ca.crt \
     -n azure-iot-operations
   
   # Verify the ConfigMap was created
   kubectl describe configmap client-ca -n azure-iot-operations
   ```

5. **Enable X.509 authentication using Azure CLI**:
   
   Since BrokerAuthentication is Azure-managed, use Azure CLI to add X.509 authentication:
   
   ```bash
   # Create a configuration file for X.509 authentication
   cat > x509-authn.json << 'EOF'
   {
     "authenticationMethods": [
       {
         "method": "ServiceAccountToken",
         "serviceAccountTokenSettings": {
           "audiences": ["aio-internal"]
         }
       },
       {
         "method": "X509",
         "x509Settings": {
           "trustedClientCaCert": "client-ca"
         }
       }
     ]
   }
   EOF
   
   # Apply the authentication configuration
   az iot ops broker authn apply \
     --resource-group IoT-Operations-Work-Edge-bel-aio \
     --instance bel-aio-work-cluster-aio \
     --broker default \
     --name default \
     --config-file x509-authn.json
   ```
   
   Alternatively, use the Azure Portal:
   - Navigate to your IoT Operations instance
   - Under **Components**, select **MQTT Broker**
   - Select the **Authentication** tab
   - Select the **default** authentication policy
   - Select **Add method** → **X.509**
   - In **X.509 authentication details**, enter:
     * **Trusted client CA ConfigMap**: `client-ca`
   - Select **Apply** and **Save**

6. **Create a client certificate** signed by your client CA:
   ```bash
   # Generate a private key for your client
   openssl genrsa -out client.key 2048
   
   # Create a certificate signing request (CSR)
   openssl req -new -key client.key -out client.csr \
     -subj "/CN=sputnik-client/O=IoT-Operations"
   
   # Sign the client certificate with the CLIENT CA (not the broker CA)
   openssl x509 -req -in client.csr \
     -CA client-ca.crt -CAkey client-ca.key \
     -CAcreateserial -out client.crt \
     -days 365 -sha256
   
   # Verify the certificate was signed correctly
   openssl verify -CAfile client-ca.crt client.crt
   ```
   
   You should see: `client.crt: OK`

7. **Get the broker's server CA certificate** (for server verification):
   ```bash
   # Get the broker's server CA certificate for TLS verification
   kubectl get secret aio-broker-internal-ca -n azure-iot-operations \
     -o jsonpath='{.data.tls\.crt}' | base64 -d > broker-ca.crt
   ```
   
8. **Clean up** (optional - remove sensitive keys):
   ```bash
   # Remove the CA key - you don't need it anymore and it's sensitive
   rm client-ca.key client-ca.crt.srl client.csr
   ```

Now you have four files ready for use:
- `broker-ca.crt` - The broker's CA certificate (to verify the broker's server certificate)
- `client.crt` - Your client certificate (to authenticate to the broker)
- `client.key` - Your client private key (to authenticate to the broker)
- `client-ca.crt` - Your client CA certificate (for reference, already in ConfigMap)



3. Get Broker Certificate Information:
   ```bash
   # View details of the MQTT broker's certificate configuration
   kubectl get MqttBrokerCertificates -n azure-iot-operations -o yaml
   
   # Get the auto-generated CA certificate
   kubectl get secret mqtt-broker-ca -n azure-iot-operations -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
   ```

4. Create Client Certificate:
   There are two approaches to create client certificates:

   A. Using the Broker's CA (Recommended):
   ```bash
   # Create a private key for your client
   openssl genrsa -out client.key 2048

   # Create a Certificate Signing Request (CSR)
   openssl req -new -key client.key -out client.csr \
     -subj "/CN=sputnik-client/O=your-organization"

   # Create a Kubernetes CSR resource
   cat <<EOF | kubectl apply -f -
   apiVersion: certificates.k8s.io/v1
   kind: CertificateSigningRequest
   metadata:
     name: sputnik-client
   spec:
     request: $(cat client.csr | base64 | tr -d '\n')
     signerName: azure-iot-operations.microsoft.com/mqtt-broker
     usages:
     - client auth
   EOF

   # Approve the certificate
   kubectl certificate approve sputnik-client

   # Get the signed certificate
   kubectl get csr sputnik-client -o jsonpath='{.status.certificate}' | base64 -d > client.crt
   ```

   B. Using Kubernetes Secret (Alternative):
   ```bash
   # Create a secret for client authentication
   kubectl create secret tls mqtt-client-cert \
     --namespace azure-iot-operations \
     --cert=client.crt \
     --key=client.key
   ```



## Using Certificates in Kubernetes

### 1. Store Certificates in GitHub Secrets

**IMPORTANT**: Certificate files (`.crt` and `.key`) are already in PEM format (base64-encoded). Do NOT base64 encode them again - just copy the raw content.

1. Read the certificate file contents:
   ```bash
   # On Linux/Mac - just display the content
   cat broker-ca.crt
   cat client.crt
   cat client.key
   
   # On Windows PowerShell - display the content
   Get-Content -Raw -Path .\broker-ca.crt
   Get-Content -Raw -Path .\client.crt
   Get-Content -Raw -Path .\client.key
   ```

2. Copy and paste the **entire output** (including `-----BEGIN CERTIFICATE-----` and `-----END CERTIFICATE-----` lines) into GitHub Secrets:
   - Go to your GitHub repository
   - Navigate to Settings > Secrets and variables > Actions
   - Add new repository secrets:
     * `MQTT_BROKER_CA_CERT`: Paste the entire content of `broker-ca.crt` (broker's server CA for TLS verification)
     * `MQTT_CLIENT_CERT`: Paste the entire content of `client.crt`
     * `MQTT_CLIENT_KEY`: Paste the entire content of `client.key`

### 2. Create Kubernetes Secret in GitHub Actions

Add this step to your GitHub Actions workflow:

```yaml
# In your .github/workflows/deploy.yml
steps:
  - name: Create MQTT Certificates Secret
    run: |
      # Write secrets to temporary files
      echo "${{ secrets.MQTT_BROKER_CA_CERT }}" > broker-ca.crt
      echo "${{ secrets.MQTT_CLIENT_CERT }}" > client.crt
      echo "${{ secrets.MQTT_CLIENT_KEY }}" > client.key
      
      # Create the secret from files (not literals, to preserve formatting)
      kubectl create secret generic aio-mqtt-certs \
        --namespace default \
        --from-file=broker-ca.crt=broker-ca.crt \
        --from-file=client.crt=client.crt \
        --from-file=client.key=client.key \
        --dry-run=client -o yaml | kubectl apply -f -
      
      # Clean up temporary files
      rm broker-ca.crt client.crt client.key
    env:
      KUBECONFIG: ${{ secrets.KUBECONFIG }}
```

**Note**: Update your GitHub Secrets to use `MQTT_BROKER_CA_CERT` (for the broker's server CA) instead of `MQTT_CA_CERT`.

### 3. Mount Certificates in Deployment

Update your deployment YAML to use the secret:

```yaml
spec:
  template:
    spec:
      containers:
      - name: your-container
        volumeMounts:
        - name: mqtt-certs
          mountPath: "/certs"
          readOnly: true
        env:
        - name: MQTT_CLIENT_CERT
          value: "/certs/client.crt"
        - name: MQTT_CLIENT_KEY
          value: "/certs/client.key"
        - name: MQTT_BROKER_CA_CERT
          value: "/certs/broker-ca.crt"
      volumes:
      - name: mqtt-certs
        secret:
          secretName: aio-mqtt-certs
```

## Certificate Rotation

1. Generate new certificates following one of the methods above
2. Create a new Kubernetes secret with a different name:
   ```bash
   kubectl create secret generic aio-mqtt-certs-new \
       --from-file=client.crt=/path/to/new-client.crt \
       --from-file=client.key=/path/to/new-client.key \
       --from-file=ca.crt=/path/to/new-ca.crt
   ```

3. Update your deployment to use the new secret:
   ```bash
   kubectl patch deployment your-deployment -p '{"spec":{"template":{"spec":{"volumes":[{"name":"mqtt-certs","secret":{"secretName":"aio-mqtt-certs-new"}}]}}}}'
   ```

4. Delete the old secret once all pods are updated:
   ```bash
   kubectl delete secret aio-mqtt-certs
   ```

## Troubleshooting

### Certificate Issues

1. Verify certificate files:
   ```bash
   # Check client certificate
   openssl x509 -in client.crt -text -noout
   
   # Verify client key matches certificate
   openssl x509 -noout -modulus -in client.crt | openssl md5
   openssl rsa -noout -modulus -in client.key | openssl md5
   
   # Check CA certificate
   openssl x509 -in ca.crt -text -noout
   ```

2. Test MQTT Connection:
   ```bash
   # Test using mosquitto client
   mosquitto_pub --cafile ca.crt \
                 --cert client.crt \
                 --key client.key \
                 -h your-broker-host \
                 -p 8883 \
                 -t "test/topic" \
                 -m "test message" \
                 -d
   ```

### Common Issues

1. **Certificate Not Found**: Check the secret was created and mounted correctly:
   ```bash
   kubectl describe secret aio-mqtt-certs
   kubectl describe pod your-pod-name
   ```

2. **Permission Denied**: Check file permissions in the container:
   ```bash
   kubectl exec your-pod-name -- ls -l /certs
   ```

3. **Certificate Expired**: Check certificate validity:
   ```bash
   openssl x509 -in client.crt -noout -dates
   ```

## Security Best Practices

1. Never commit certificates to source control
2. Use separate certificates for development and production
3. Implement proper certificate rotation procedures
4. Monitor certificate expiration dates
5. Use appropriate file permissions for certificate files
6. Consider using Azure Key Vault for certificate storage in production

## References

- [Azure IoT Operations Documentation](https://learn.microsoft.com/azure/iot-operations)
- [MQTT TLS Documentation](https://mosquitto.org/man/mosquitto-tls-7.html)
- [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- [OpenSSL Certificate Commands](https://www.openssl.org/docs/man1.1.1/man1/)