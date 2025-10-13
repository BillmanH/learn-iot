# K3s Troubleshooting Quick Reference
# When stuck at "Still waiting for k3s to be ready..."

## IMMEDIATE ACTIONS (run these in order)

### 1. Check what's happening right now
```bash
# Check if K3s service is actually running
sudo systemctl status k3s

# Check recent logs (run this in a separate terminal)
sudo journalctl -u k3s -f

# Check if the API server is responding
sudo k3s kubectl get nodes

# Check system resources
df -h
free -h
```

### 2. Look for specific error patterns
```bash
# Check for errors in logs
sudo journalctl -u k3s --no-pager | grep -i error | tail -10

# Check for port conflicts
sudo netstat -tlnp | grep :6443

# Check for disk space issues
sudo journalctl -u k3s --no-pager | grep -i "no space\|disk full"

# Check for memory issues
sudo journalctl -u k3s --no-pager | grep -i "memory\|oom"

# Check for permission issues
sudo journalctl -u k3s --no-pager | grep -i "permission\|denied"
```

### 3. Try a gentle restart
```bash
# Stop your installation script first (Ctrl+C)
# Then restart K3s
sudo systemctl restart k3s

# Wait 30 seconds and check
sleep 30
sudo k3s kubectl get nodes
```

### 4. If gentle restart doesn't work
```bash
# Stop K3s completely
sudo systemctl stop k3s

# Kill any stuck processes
sudo pkill -f k3s

# Clean up log files that might be corrupted
sudo rm -rf /var/lib/rancher/k3s/server/logs/*

# Start fresh
sudo systemctl start k3s

# Monitor the startup
sudo journalctl -u k3s -f
```

### 5. Check for common issues

#### A. Port conflicts
```bash
# Check what's using port 6443
sudo netstat -tlnp | grep :6443

# If it's not K3s, kill the conflicting process
sudo pkill -f "kube-apiserver"
sudo pkill -f "minikube"
sudo pkill -f "kind"

# Stop Docker containers using the port
docker stop $(docker ps -q --filter "publish=6443") 2>/dev/null || true
```

#### B. Disk space
```bash
# Check disk space (need at least 1GB free)
df -h

# Clean up if needed
sudo apt clean
sudo docker system prune -f  # If Docker is installed
sudo rm -rf /tmp/* /var/tmp/*
```

#### C. Memory issues
```bash
# Check memory (need at least 1GB available)
free -h

# Check for memory pressure
dmesg | grep -i "killed process"

# If low on memory, try increasing swap or freeing memory
sudo swapoff -a && sudo swapon -a  # Reset swap
```

#### D. Network issues
```bash
# Check network connectivity
ping -c 3 8.8.8.8

# Check DNS
nslookup google.com

# Reset network if needed
sudo systemctl restart networking
```

### 6. Nuclear option - Complete reinstall
```bash
# Only if nothing else works
sudo /usr/local/bin/k3s-uninstall.sh

# Clean up completely
sudo rm -rf /etc/rancher/k3s/
sudo rm -rf /var/lib/rancher/k3s/

# Reinstall
curl -sfL https://get.k3s.io | sh -s - --disable=traefik --write-kubeconfig-mode 644

# Monitor the installation
sudo journalctl -u k3s -f
```

## COMMON ERROR PATTERNS AND SOLUTIONS

### "failed to create listener: address already in use"
- **Cause**: Port 6443 is occupied
- **Solution**: Find and kill the process using the port
```bash
sudo netstat -tlnp | grep :6443
sudo kill -9 <PID>
```

### "no space left on device"
- **Cause**: Disk full
- **Solution**: Free up disk space
```bash
df -h
sudo apt clean
sudo rm -rf /var/lib/rancher/k3s/server/logs/*
```

### "failed to get CA bundle: context deadline exceeded"
- **Cause**: Network connectivity issues
- **Solution**: Check network and DNS
```bash
ping -c 3 8.8.8.8
sudo systemctl restart networking
```

### "permission denied"
- **Cause**: File permission issues
- **Solution**: Fix permissions
```bash
sudo chown -R root:root /etc/rancher/k3s/
sudo chmod 755 /usr/local/bin/k3s
```

### Nodes stuck in "NotReady" state
- **Cause**: Container runtime issues
- **Solution**: Restart the container runtime
```bash
sudo systemctl restart k3s
sudo k3s kubectl get nodes -o wide
```

## TIMING EXPECTATIONS

- **Initial startup**: 30-60 seconds
- **Node ready**: 1-2 minutes
- **System pods ready**: 2-3 minutes
- **Total installation**: 3-5 minutes

If it's taking longer than 5 minutes, there's definitely an issue.

## SYSTEM REQUIREMENTS CHECK

Verify your system meets the requirements:
```bash
# Check OS version (Ubuntu 16.04+ required, 20.04+ recommended)
lsb_release -a

# Check memory (1GB+ required, 2GB+ recommended)
free -h

# Check disk space (1GB+ required, 10GB+ recommended)
df -h

# Check CPU (1+ cores required, 2+ recommended)
nproc
```

## GETTING HELP

If none of these steps work:

1. Run the advanced diagnostics script:
   ```bash
   chmod +x k3s_advanced_diagnostics.sh
   ./k3s_advanced_diagnostics.sh > diagnostics.log 2>&1
   ```

2. Check the full logs:
   ```bash
   sudo journalctl -u k3s --no-pager > k3s_full.log
   ```

3. Get system information:
   ```bash
   uname -a > system_info.txt
   lsb_release -a >> system_info.txt
   free -h >> system_info.txt
   df -h >> system_info.txt
   ```

4. Share the diagnostic files for further help.