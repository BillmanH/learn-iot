# Manual Commands for Systems Without netstat

Since `netstat` is not available on your system, here are alternative commands you can use:

## CHECK WHAT'S USING PORT 6443

### Option 1: Using `ss` (modern netstat replacement)
```bash
# Check if port 6443 is in use
ss -tlnp | grep :6443

# More detailed output
ss -tulpn | grep :6443
```

### Option 2: Using `lsof` (if available)
```bash
# Check what's using port 6443
sudo lsof -i :6443

# More detailed
sudo lsof -i TCP:6443
```

### Option 3: Using basic connectivity test
```bash
# Test if something is listening on port 6443
timeout 2 bash -c "</dev/tcp/127.0.0.1/6443" && echo "Port 6443 is in use" || echo "Port 6443 is free"
```

### Option 4: Using `nmap` (if available)
```bash
# Scan port 6443
nmap -p 6443 localhost
```

## FIND AND KILL PROCESSES

### Find K3s processes
```bash
# Find K3s processes
ps aux | grep k3s | grep -v grep

# Get K3s process IDs
pgrep -f k3s

# Kill K3s processes
sudo pkill -f k3s
```

### Find other Kubernetes processes
```bash
# Find any Kubernetes-related processes
ps aux | grep -E "kube|minikube|kind" | grep -v grep

# Kill specific processes
sudo pkill -f kube-apiserver
sudo pkill -f minikube
sudo pkill -f kind
```

### Find Docker containers using port 6443
```bash
# List all containers with port mappings
docker ps --format "table {{.Names}}\t{{.Ports}}"

# Find containers using port 6443
docker ps --filter "publish=6443"

# Stop containers using port 6443
docker stop $(docker ps -q --filter "publish=6443")
```

## INSTALL MISSING TOOLS (if needed)

### Install `ss` (usually part of iproute2)
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install iproute2

# CentOS/RHEL/Fedora
sudo yum install iproute2
# or
sudo dnf install iproute2
```

### Install `lsof`
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install lsof

# CentOS/RHEL/Fedora
sudo yum install lsof
# or
sudo dnf install lsof
```

### Install `netstat` (part of net-tools)
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install net-tools

# CentOS/RHEL/Fedora
sudo yum install net-tools
# or
sudo dnf install net-tools
```

## COMPLETE MANUAL FIX FOR PORT 6443 CONFLICT

```bash
# Step 1: Check if port 6443 is in use
ss -tlnp | grep :6443

# Step 2: If you see output, identify the process
# Look for the process name in the output

# Step 3: Stop the conflicting process
# If it's K3s:
sudo systemctl stop k3s
sudo pkill -f k3s

# If it's minikube:
minikube stop
minikube delete

# If it's Docker:
docker ps --filter "publish=6443"
docker stop <CONTAINER_ID>

# If it's something else, get the PID from step 1 and:
sudo kill -9 <PID>

# Step 4: Verify port is free
ss -tlnp | grep :6443
# Should return nothing

# Step 5: Start K3s
sudo systemctl start k3s

# Step 6: Monitor startup
sudo journalctl -u k3s -f
```

## QUICK TEST COMMANDS

```bash
# Test if K3s is working
sudo k3s kubectl get nodes

# Test if API server is responding
curl -k https://127.0.0.1:6443/version

# Check K3s service status
sudo systemctl status k3s
```