#!/bin/bash

# Quick Fix Script for MQTT Connection Issues
# This script attempts to resolve common authentication and connectivity problems

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    case $status in
        "success") echo -e "${GREEN}✅ $message${NC}" ;;
        "error") echo -e "${RED}❌ $message${NC}" ;;
        "warning") echo -e "${YELLOW}⚠️  $message${NC}" ;;
        "info") echo -e "${CYAN}ℹ️  $message${NC}" ;;
        "header") echo -e "${CYAN}$message${NC}" ;;
        "subheader") echo -e "${YELLOW}$message${NC}" ;;
        "gray") echo -e "${GRAY}$message${NC}" ;;
    esac
}

# Function to run kubectl and check results
run_kubectl() {
    local command=$1
    local success_msg=$2
    local error_msg=$3
    
    print_status "gray" "Running: kubectl $command"
    
    if output=$(kubectl $command 2>&1); then
        print_status "success" "$success_msg"
        return 0
    else
        print_status "error" "$error_msg"
        print_status "gray" "   Details: $output"
        return 1
    fi
}

# Function to check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        print_status "error" "kubectl is not installed or not in PATH"
        exit 1
    fi
}

print_status "header" "============================================"
print_status "header" "IoT Operations MQTT Quick Fix Script"
print_status "header" "============================================"
echo ""

# Check prerequisites
check_kubectl

print_status "subheader" "Step 1: Checking and creating service account..."
print_status "subheader" "------------------------------------------------"

# Check if service account exists
if kubectl get serviceaccount mqtt-client -n default &>/dev/null; then
    print_status "success" "Service account 'mqtt-client' already exists"
else
    print_status "warning" "Service account 'mqtt-client' not found. Creating..."
    if run_kubectl "create serviceaccount mqtt-client -n default" \
        "Service account created successfully" \
        "Failed to create service account"; then
        :
    else
        print_status "error" "Cannot proceed without service account"
        exit 1
    fi
fi
echo ""

print_status "subheader" "Step 2: Verifying deployment configuration..."
print_status "subheader" "----------------------------------------------"

# Check if deployment exists and uses correct service account
if deployment_sa=$(kubectl get deployment edgemqttsim -n default -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null); then
    if [ "$deployment_sa" = "mqtt-client" ]; then
        print_status "success" "Deployment is correctly configured with service account 'mqtt-client'"
    else
        print_status "warning" "Deployment is using service account: '$deployment_sa'"
        print_status "warning" "   Expected: 'mqtt-client'"
        print_status "warning" "   Please update deployment.yaml to use serviceAccountName: mqtt-client"
    fi
else
    print_status "error" "Deployment 'edgemqttsim' not found"
    print_status "error" "   Please deploy the application first"
fi
echo ""

print_status "subheader" "Step 3: Restarting deployment to refresh token..."
print_status "subheader" "--------------------------------------------------"

if run_kubectl "rollout restart deployment/edgemqttsim -n default" \
    "Deployment restart initiated" \
    "Failed to restart deployment"; then
    
    print_status "gray" "Waiting for rollout to complete..."
    sleep 5
    
    if run_kubectl "rollout status deployment/edgemqttsim -n default --timeout=60s" \
        "Rollout completed successfully" \
        "Rollout did not complete in time"; then
        :
    fi
fi
echo ""

print_status "subheader" "Step 4: Verifying Azure IoT Operations..."
print_status "subheader" "-----------------------------------------"

# Check if Azure IoT Operations is running
if kubectl get namespace azure-iot-operations &>/dev/null; then
    print_status "success" "Azure IoT Operations namespace exists"
    
    # Check if broker service exists
    if kubectl get service aio-broker -n azure-iot-operations &>/dev/null; then
        print_status "success" "MQTT broker service 'aio-broker' is available"
    else
        print_status "error" "MQTT broker service 'aio-broker' not found"
        print_status "error" "   Azure IoT Operations may not be properly installed"
    fi
else
    print_status "error" "Azure IoT Operations namespace not found"
    print_status "error" "   Please install Azure IoT Operations first"
fi
echo ""

print_status "subheader" "Step 5: Testing connectivity..."
print_status "subheader" "--------------------------------"

# Wait a moment for pod to be ready
sleep 10

# Get the new pod name
if pod_name=$(kubectl get pods -n default -l app=edgemqttsim -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [ -n "$pod_name" ]; then
    print_status "gray" "Testing from pod: $pod_name"
    
    # Test DNS resolution
    print_status "gray" "Testing DNS resolution..."
    if kubectl exec "$pod_name" -n default -- nslookup aio-broker.azure-iot-operations.svc.cluster.local &>/dev/null; then
        print_status "success" "DNS resolution successful"
    else
        print_status "error" "DNS resolution failed"
        print_status "gray" "Trying alternative DNS test..."
        # Try with Python socket as fallback
        if kubectl exec "$pod_name" -n default -- python3 -c "
import socket
try:
    socket.gethostbyname('aio-broker.azure-iot-operations.svc.cluster.local')
    print('DNS resolution successful via Python')
    exit(0)
except:
    print('DNS resolution failed via Python')
    exit(1)
        " &>/dev/null; then
            print_status "success" "DNS resolution successful (via Python)"
        else
            print_status "error" "DNS resolution failed completely"
        fi
    fi
    
    # Test port connectivity
    print_status "gray" "Testing port connectivity..."
    # First try nc if available, then fallback to Python
    if kubectl exec "$pod_name" -n default -- which nc &>/dev/null; then
        if port_test=$(kubectl exec "$pod_name" -n default -- nc -zv aio-broker.azure-iot-operations.svc.cluster.local 18883 2>&1); then
            if echo "$port_test" | grep -q -E "(succeeded|Connected|open)"; then
                print_status "success" "Port 18883 is accessible"
            else
                print_status "error" "Port 18883 is not accessible"
                print_status "gray" "   Details: $port_test"
            fi
        else
            print_status "error" "Port 18883 is not accessible"
            print_status "gray" "   Details: $port_test"
        fi
    else
        print_status "gray" "netcat not available, trying Python socket test..."
        if kubectl exec "$pod_name" -n default -- python3 -c "
import socket
import sys
try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(5)
    result = sock.connect_ex(('aio-broker.azure-iot-operations.svc.cluster.local', 18883))
    sock.close()
    if result == 0:
        print('Port 18883 is accessible')
        sys.exit(0)
    else:
        print(f'Port 18883 not accessible (error code: {result})')
        sys.exit(1)
except Exception as e:
    print(f'Connection test failed: {e}')
    sys.exit(1)
        " 2>/dev/null; then
            print_status "success" "Port 18883 is accessible (via Python)"
        else
            print_status "error" "Port 18883 is not accessible (via Python)"
        fi
    fi
    
    # Check token
    print_status "gray" "Checking ServiceAccountToken..."
    if kubectl exec "$pod_name" -n default -- ls -la /var/run/secrets/tokens/broker-sat &>/dev/null; then
        print_status "success" "ServiceAccountToken file exists"
        
        if token_size=$(kubectl exec "$pod_name" -n default -- wc -c /var/run/secrets/tokens/broker-sat 2>/dev/null); then
            size=$(echo "$token_size" | awk '{print $1}')
            if [ "$size" -gt 100 ]; then
                print_status "success" "Token size looks good: $size characters"
            else
                print_status "warning" "Token size seems small: $size characters"
            fi
        fi
    else
        print_status "error" "ServiceAccountToken file not found"
    fi
    
    # Additional network diagnostics
    print_status "gray" "Additional network diagnostics..."
    
    # Check if broker service exists and get details
    print_status "gray" "Checking broker service details..."
    if service_info=$(kubectl get service aio-broker -n azure-iot-operations -o wide 2>/dev/null); then
        echo "$service_info"
    else
        print_status "error" "Cannot get broker service details"
    fi
    
    # Check endpoints
    print_status "gray" "Checking service endpoints..."
    if endpoints=$(kubectl get endpoints aio-broker -n azure-iot-operations 2>/dev/null); then
        echo "$endpoints"
    else
        print_status "error" "Cannot get broker endpoints"
    fi
    
    # Test internal service name resolution
    print_status "gray" "Testing short service name resolution..."
    if kubectl exec "$pod_name" -n default -- python3 -c "
import socket
try:
    ip = socket.gethostbyname('aio-broker.azure-iot-operations')
    print(f'Short name resolves to: {ip}')
    exit(0)
except Exception as e:
    print(f'Short name resolution failed: {e}')
    exit(1)
    " 2>/dev/null; then
        print_status "success" "Short service name resolution works"
    else
        print_status "warning" "Short service name resolution failed"
    fi
else
    print_status "error" "No running pod found for connectivity tests"
fi
echo ""

print_status "subheader" "Step 5.5: Network Policy and DNS Debug..."
print_status "subheader" "-------------------------------------------"

# Check for network policies that might block traffic
print_status "gray" "Checking for network policies..."
if network_policies=$(kubectl get networkpolicy -n default 2>/dev/null); then
    if [ -n "$network_policies" ]; then
        print_status "warning" "Network policies found in default namespace:"
        echo "$network_policies"
    else
        print_status "success" "No network policies blocking traffic in default namespace"
    fi
else
    print_status "success" "No network policies found"
fi

# Check DNS configuration
print_status "gray" "Checking cluster DNS configuration..."
if dns_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-dns 2>/dev/null); then
    print_status "success" "DNS pods found in kube-system:"
    echo "$dns_pods"
elif dns_pods=$(kubectl get pods -n kube-system -l app=coredns 2>/dev/null); then
    print_status "success" "CoreDNS pods found in kube-system:"
    echo "$dns_pods"
else
    print_status "error" "No DNS pods found - this may explain connectivity issues"
fi
echo ""

print_status "subheader" "Step 6: Checking application logs..."
print_status "subheader" "------------------------------------"

# Get recent logs
print_status "gray" "Recent application logs:"
if logs=$(kubectl logs -l app=edgemqttsim -n default --tail=5 2>/dev/null); then
    echo "$logs"
    
    # Check for successful connection
    if echo "$logs" | grep -q "Connected successfully"; then
        print_status "success" "🎉 SUCCESS: Application is now connected!"
    elif echo "$logs" | grep -q -E "(Failed to connect|Bad username or password)"; then
        print_status "warning" "Still experiencing connection issues"
    fi
else
    print_status "error" "Cannot retrieve application logs"
fi
echo ""

print_status "header" "============================================"
print_status "header" "Quick Fix Summary"
print_status "header" "============================================"
echo ""

print_status "info" "Actions Taken:"
print_status "gray" "✓ Verified/created service account 'mqtt-client'"
print_status "gray" "✓ Restarted deployment to refresh ServiceAccountToken"
print_status "gray" "✓ Verified Azure IoT Operations components"
print_status "gray" "✓ Tested network connectivity"
echo ""

print_status "info" "Next Steps:"
echo -e "${CYAN}1. Monitor logs: kubectl logs -l app=edgemqttsim -n default -f${NC}"
echo -e "${CYAN}2. If issues persist, run: ./diagnose-mqtt.sh${NC}"
echo -e "${CYAN}3. For detailed troubleshooting: See IOT_TROUBLESHOOTING.md${NC}"
echo ""

print_status "success" "🔍 To continue monitoring connection status:"
echo -e "${CYAN}kubectl logs -l app=edgemqttsim -n default -f | grep -E '(Connected|Failed|✓|✗)'${NC}"