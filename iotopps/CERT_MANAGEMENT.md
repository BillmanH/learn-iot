# Certificate Management for IoT Operations

This guide explains how to manage certificates for applications connecting to Azure IoT Operations MQTT broker.

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

3. **Create a client certificate** signed by the broker's CA:
   ```bash
   # Generate a private key for your client
   openssl genrsa -out client.key 2048
   
   # Create a certificate signing request (CSR)
   openssl req -new -key client.key -out client.csr \
     -subj "/CN=sputnik-client/O=IoT-Operations"
   
   # Sign the client certificate with the broker's CA
   openssl x509 -req -in client.csr \
     -CA ca.crt -CAkey ca.key \
     -CAcreateserial -out client.crt \
     -days 365 -sha256
   
   # Verify the certificate was signed correctly
   openssl verify -CAfile ca.crt client.crt
   ```
   
   You should see: `client.crt: OK`
   
4. **Clean up** (optional - remove CA key for security):
   ```bash
   # Remove the CA key - you don't need it anymore and it's sensitive
   rm ca.key ca.crt.srl client.csr
   ```

Now you have three files ready for use:
- `ca.crt` - The CA certificate (to verify the broker)
- `client.crt` - Your client certificate (to authenticate to the broker)
- `client.key` - Your client private key (to authenticate to the broker)



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

1. Base64 encode your certificates:
   ```bash
   # On Linux/Mac
   base64 -w 0 ca.crt > ca.crt.b64
   base64 -w 0 client.crt > client.crt.b64
   base64 -w 0 client.key > client.key.b64
   
   # On Windows PowerShell (run these commands in the folder containing your certificates)
   $content = Get-Content -Raw -Path .\ca.crt; [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content)) > ca.crt.b64
   $content = Get-Content -Raw -Path .\client.crt; [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content)) > client.crt.b64
   $content = Get-Content -Raw -Path .\client.key; [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content)) > client.key.b64
   ```

2. Add the base64-encoded certificates as GitHub Secrets:
   - Go to your GitHub repository
   - Navigate to Settings > Secrets and variables > Actions
   - Add new repository secrets:
     * `MQTT_CA_CERT`: Content of ca.crt.b64
     * `MQTT_CLIENT_CERT`: Content of client.crt.b64
     * `MQTT_CLIENT_KEY`: Content of client.key.b64

### 2. Create Kubernetes Secret in GitHub Actions

Add this step to your GitHub Actions workflow:

```yaml
# In your .github/workflows/deploy.yml
steps:
  - name: Create MQTT Certificates Secret
    run: |
      # Create the secret with the certificates
      kubectl create secret generic aio-mqtt-certs \
        --namespace azure-iot-operations \
        --from-literal=ca.crt="${{ secrets.MQTT_CA_CERT }}" \
        --from-literal=client.crt="${{ secrets.MQTT_CLIENT_CERT }}" \
        --from-literal=client.key="${{ secrets.MQTT_CLIENT_KEY }}" \
        --dry-run=client -o yaml | kubectl apply -f -
    env:
      KUBECONFIG: ${{ secrets.KUBECONFIG }}

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
        - name: MQTT_CA_CERT
          value: "/certs/ca.crt"
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