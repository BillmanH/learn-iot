#!/bin/bash

# Advanced K3s Diagnostic Script
# This script provides detailed diagnostics when K3s fails to start or become ready
# Run this when your installation is stuck at "Still waiting for k3s to be ready..."

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING: $1${NC}"; }
error() { echo -e "${RED}[$(date +'%H:%M:%S')] ERROR: $1${NC}"; }
info() { echo -e "${BLUE}[$(date +'%H:%M:%S')] INFO: $1${NC}"; }
debug() { echo -e "${CYAN}[$(date +'%H:%M:%S')] DEBUG: $1${NC}"; }

# Check system resources in detail
check_system_resources() {
    echo -e "\n${YELLOW}=== SYSTEM RESOURCES ===${NC}"
    
    # Disk space
    log "Checking disk space..."
    df -h
    
    # Check specifically for /var/lib/rancher/k3s (K3s data directory)
    if [ -d "/var/lib/rancher/k3s" ]; then
        debug "K3s data directory size:"
        sudo du -sh /var/lib/rancher/k3s/* 2>/dev/null || true
    fi
    
    # Memory
    log "Checking memory..."
    free -h
    echo "Memory details:"
    cat /proc/meminfo | grep -E "MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree"
    
    # CPU
    log "Checking CPU..."
    nproc
    lscpu | grep -E "CPU|Architecture|Thread|Core"
    
    # Load average
    log "System load:"
    uptime
    
    # Check for out of memory kills
    if dmesg | grep -i "killed process" | tail -5 | grep -q .; then
        warn "Recent OOM kills detected:"
        dmesg | grep -i "killed process" | tail -5
    fi
}

# Detailed K3s service analysis
analyze_k3s_service() {
    echo -e "\n${YELLOW}=== K3S SERVICE ANALYSIS ===${NC}"
    
    # Service status
    log "K3s service status:"
    sudo systemctl status k3s --no-pager -l || true
    
    # Get detailed failure information
    log "Service failure details:"
    local exit_code=$(sudo systemctl show k3s --property=ExecMainStatus --value)
    local result=$(sudo systemctl show k3s --property=Result --value)
    local restart_count=$(sudo systemctl show k3s --property=NRestarts --value)
    
    info "Exit Code: $exit_code"
    info "Result: $result"
    info "Restart Count: $restart_count"
    
    # Analyze specific failure types
    if [[ "$result" == "exit-code" ]]; then
        warn "K3s exited with error code $exit_code"
        
        case "$exit_code" in
            1) warn "General error - check logs for specific cause" ;;
            2) warn "Misuse of shell command" ;;
            125) warn "Docker daemon error" ;;
            126) warn "Container command not executable" ;;
            127) warn "Container command not found" ;;
            *) warn "Unknown exit code: $exit_code" ;;
        esac
    elif [[ "$result" == "signal" ]]; then
        warn "K3s was killed by a signal"
    elif [[ "$result" == "timeout" ]]; then
        warn "K3s startup timed out"
    fi
    
    # Service configuration
    if [ -f "/etc/systemd/system/k3s.service" ]; then
        debug "K3s service file:"
        cat /etc/systemd/system/k3s.service
    fi
    
    # Check if service is enabled
    if systemctl is-enabled k3s >/dev/null 2>&1; then
        info "K3s service is enabled"
    else
        warn "K3s service is not enabled"
    fi
    
    # Check service failures
    log "Recent service failures:"
    sudo systemctl list-units --failed | grep k3s || info "No failed K3s services"
    
    # Check for coredumps
    if command -v coredumpctl &> /dev/null; then
        if coredumpctl list k3s 2>/dev/null | grep -q k3s; then
            warn "K3s coredumps found:"
            coredumpctl list k3s
        fi
    fi
}

# Analyze specific failure patterns
analyze_failure_patterns() {
    echo -e "\n${YELLOW}=== FAILURE PATTERN ANALYSIS ===${NC}"
    
    log "Analyzing common failure patterns..."
    
    # Check for port conflicts
    if sudo journalctl -u k3s --no-pager | grep -q "address already in use\|bind.*already in use"; then
        error "PORT CONFLICT DETECTED!"
        info "K3s cannot start because port 6443 is already in use"
        info "Solution:"
        echo "  sudo netstat -tlnp | grep :6443"
        echo "  sudo kill -9 <PID_OF_CONFLICTING_PROCESS>"
        echo "  sudo systemctl start k3s"
    fi
    
    # Check for disk space issues
    if sudo journalctl -u k3s --no-pager | grep -q "no space left\|disk full"; then
        error "DISK SPACE ISSUE DETECTED!"
        info "K3s cannot start due to insufficient disk space"
        info "Solution:"
        echo "  df -h  # Check available space"
        echo "  sudo apt clean"
        echo "  sudo rm -rf /tmp/*"
        echo "  sudo rm -rf /var/lib/rancher/k3s/server/logs/*"
    fi
    
    # Check for permission issues
    if sudo journalctl -u k3s --no-pager | grep -q "permission denied\|operation not permitted"; then
        error "PERMISSION ISSUE DETECTED!"
        info "K3s has permission problems"
        info "Solution:"
        echo "  sudo chmod +x /usr/local/bin/k3s"
        echo "  sudo chown -R root:root /etc/rancher/k3s/"
        echo "  sudo chown -R root:root /var/lib/rancher/k3s/"
    fi
    
    # Check for binary issues
    if sudo journalctl -u k3s --no-pager | grep -q "no such file\|cannot execute\|not found"; then
        error "BINARY ISSUE DETECTED!"
        info "K3s binary is missing or corrupted"
        info "Solution:"
        echo "  sudo /usr/local/bin/k3s-uninstall.sh"
        echo "  curl -sfL https://get.k3s.io | sh -s - --disable=traefik --write-kubeconfig-mode 644"
    fi
    
    # Check for network issues
    if sudo journalctl -u k3s --no-pager | grep -q "connection refused\|network unreachable\|timeout"; then
        error "NETWORK ISSUE DETECTED!"
        info "K3s has network connectivity problems"
        info "Solution:"
        echo "  ping -c 3 8.8.8.8  # Test internet"
        echo "  sudo systemctl restart networking"
        echo "  sudo systemctl restart k3s"
    fi
    
    # Check for memory issues
    if sudo journalctl -u k3s --no-pager | grep -q "out of memory\|killed\|oom"; then
        error "MEMORY ISSUE DETECTED!"
        info "K3s was killed due to insufficient memory"
        info "Solution:"
        echo "  free -h  # Check available memory"
        echo "  sudo swapon -a  # Enable swap if available"
        echo "  # Consider adding more RAM or swap space"
    fi
    
    # Check for systemd issues
    if sudo journalctl -u k3s --no-pager | grep -q "systemd.*failed\|unit.*failed"; then
        error "SYSTEMD ISSUE DETECTED!"
        info "Systemd service configuration problem"
        info "Solution:"
        echo "  sudo systemctl daemon-reload"
        echo "  sudo systemctl reset-failed k3s"
        echo "  sudo systemctl start k3s"
    fi
}

# Comprehensive K3s logs analysis
analyze_k3s_logs() {
    echo -e "\n${YELLOW}=== K3S LOGS ANALYSIS ===${NC}"
    
    # Recent logs
    log "Last 50 K3s log entries:"
    sudo journalctl -u k3s --no-pager -n 50 || true
    
    echo -e "\n${CYAN}--- Error Analysis ---${NC}"
    
    # Look for specific error patterns
    if sudo journalctl -u k3s --no-pager | grep -i "error" | tail -10 | grep -q .; then
        warn "Recent errors found:"
        sudo journalctl -u k3s --no-pager | grep -i "error" | tail -10
    fi
    
    if sudo journalctl -u k3s --no-pager | grep -i "failed" | tail -10 | grep -q .; then
        warn "Recent failures found:"
        sudo journalctl -u k3s --no-pager | grep -i "failed" | tail -10
    fi
    
    if sudo journalctl -u k3s --no-pager | grep -i "panic" | tail -5 | grep -q .; then
        error "Panic messages found:"
        sudo journalctl -u k3s --no-pager | grep -i "panic" | tail -5
    fi
    
    # Check for network issues
    if sudo journalctl -u k3s --no-pager | grep -i "network\|dns\|connection" | tail -10 | grep -q .; then
        warn "Network-related messages:"
        sudo journalctl -u k3s --no-pager | grep -i "network\|dns\|connection" | tail -10
    fi
    
    # Check for permission issues
    if sudo journalctl -u k3s --no-pager | grep -i "permission\|denied" | tail -10 | grep -q .; then
        warn "Permission-related messages:"
        sudo journalctl -u k3s --no-pager | grep -i "permission\|denied" | tail -10
    fi
}

# Check network configuration
check_network() {
    echo -e "\n${YELLOW}=== NETWORK CONFIGURATION ===${NC}"
    
    # Basic network info
    log "Network interfaces:"
    ip addr show
    
    # Check routing
    log "Routing table:"
    ip route show
    
    # Check DNS
    log "DNS configuration:"
    cat /etc/resolv.conf
    
    # Test DNS resolution
    log "Testing DNS resolution:"
    nslookup google.com || warn "DNS resolution failed"
    
    # Check for network conflicts
    log "Checking for IP conflicts..."
    if ip addr show | grep -E "10\.42\.|10\.43\." >/dev/null; then
        info "K3s default networks detected"
        ip addr show | grep -E "10\.42\.|10\.43\."
    fi
    
    # Check iptables (can interfere with K3s)
    log "IPTables rules count:"
    sudo iptables -L | wc -l
    debug "Recent iptables rules:"
    sudo iptables -L | tail -20
}

# Check processes and ports
check_processes_ports() {
    echo -e "\n${YELLOW}=== PROCESSES AND PORTS ===${NC}"
    
    # K3s processes
    log "K3s-related processes:"
    ps aux | grep -v grep | grep k3s || info "No K3s processes found"
    
    # Container runtime processes
    log "Container runtime processes:"
    ps aux | grep -v grep | grep -E "containerd|docker|crio" || info "No container runtime processes found"
    
    # Check critical ports using available tools
    log "Port usage check:"
    for port in 6443 6444 10250 10251 10252 2379 2380; do
        port_in_use=false
        
        if command -v ss >/dev/null 2>&1; then
            if ss -tlnp 2>/dev/null | grep ":$port " >/dev/null; then
                info "Port $port is in use:"
                ss -tlnp 2>/dev/null | grep ":$port "
                port_in_use=true
            fi
        elif command -v lsof >/dev/null 2>&1; then
            if lsof -i :$port 2>/dev/null | grep -q ":$port"; then
                info "Port $port is in use:"
                lsof -i :$port 2>/dev/null
                port_in_use=true
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -tlnp 2>/dev/null | grep ":$port " >/dev/null; then
                info "Port $port is in use:"
                netstat -tlnp 2>/dev/null | grep ":$port "
                port_in_use=true
            fi
        else
            # Test basic connectivity as fallback
            if timeout 1 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then
                info "Port $port appears to be in use (basic connectivity test)"
                port_in_use=true
            fi
        fi
        
        if [ "$port_in_use" = false ]; then
            debug "Port $port is free"
        fi
    done
}

# Check K3s files and directories
check_k3s_files() {
    echo -e "\n${YELLOW}=== K3S FILES AND DIRECTORIES ===${NC}"
    
    # K3s binary
    if [ -f "/usr/local/bin/k3s" ]; then
        info "K3s binary found:"
        ls -la /usr/local/bin/k3s
        /usr/local/bin/k3s --version
    else
        error "K3s binary not found at /usr/local/bin/k3s"
    fi
    
    # K3s directories
    for dir in "/etc/rancher/k3s" "/var/lib/rancher/k3s"; do
        if [ -d "$dir" ]; then
            info "Directory $dir exists:"
            sudo ls -la "$dir" 2>/dev/null || warn "Cannot list $dir"
        else
            warn "Directory $dir does not exist"
        fi
    done
    
    # K3s config file
    if [ -f "/etc/rancher/k3s/k3s.yaml" ]; then
        info "K3s config file found:"
        sudo ls -la /etc/rancher/k3s/k3s.yaml
        info "Config file permissions: $(sudo stat -c '%a' /etc/rancher/k3s/k3s.yaml)"
    else
        warn "K3s config file not found"
    fi
    
    # Check token file
    if [ -f "/var/lib/rancher/k3s/server/node-token" ]; then
        info "K3s node token exists"
    else
        warn "K3s node token not found"
    fi
}

# Test K3s connectivity
test_k3s_connectivity() {
    echo -e "\n${YELLOW}=== K3S CONNECTIVITY TEST ===${NC}"
    
    # Direct K3s kubectl test
    log "Testing direct K3s kubectl access..."
    if sudo k3s kubectl version >/dev/null 2>&1; then
        info "Direct K3s kubectl works"
        sudo k3s kubectl version
    else
        warn "Direct K3s kubectl failed"
    fi
    
    # Node status test
    log "Testing node status..."
    if sudo k3s kubectl get nodes >/dev/null 2>&1; then
        info "Can get nodes:"
        sudo k3s kubectl get nodes
    else
        warn "Cannot get nodes"
    fi
    
    # Pod status test
    log "Testing system pods..."
    if sudo k3s kubectl get pods -n kube-system >/dev/null 2>&1; then
        info "System pods:"
        sudo k3s kubectl get pods -n kube-system
    else
        warn "Cannot get system pods"
    fi
    
    # API server test
    log "Testing API server directly..."
    if curl -k https://127.0.0.1:6443/version >/dev/null 2>&1; then
        info "API server responds to direct connection"
    else
        warn "API server not responding to direct connection"
    fi
}

# Check system configuration
check_system_config() {
    echo -e "\n${YELLOW}=== SYSTEM CONFIGURATION ===${NC}"
    
    # Kernel version
    log "Kernel version:"
    uname -a
    
    # Check required kernel modules
    log "Checking required kernel modules..."
    for module in br_netfilter overlay; do
        if lsmod | grep -q "$module"; then
            info "Module $module is loaded"
        else
            warn "Module $module is not loaded"
        fi
    done
    
    # Check sysctl settings
    log "Important sysctl settings:"
    for setting in net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward; do
        value=$(sysctl -n "$setting" 2>/dev/null || echo "not set")
        info "$setting = $value"
    done
    
    # Check cgroup version
    log "Cgroup information:"
    if [ -f "/sys/fs/cgroup/cgroup.controllers" ]; then
        info "Using cgroup v2"
    elif [ -d "/sys/fs/cgroup/systemd" ]; then
        info "Using cgroup v1"
    else
        warn "Cannot determine cgroup version"
    fi
    
    # Check systemd version
    log "Systemd version:"
    systemctl --version | head -1
}

# Generate recommendations
generate_recommendations() {
    echo -e "\n${YELLOW}=== RECOMMENDATIONS ===${NC}"
    
    echo -e "${CYAN}Based on the analysis, here are some potential solutions:${NC}"
    echo
    
    echo "1. ${GREEN}Check system resources:${NC}"
    echo "   - Ensure you have at least 1GB free disk space"
    echo "   - Ensure you have at least 1GB free RAM"
    echo "   - Check: df -h && free -h"
    
    echo
    echo "2. ${GREEN}Restart K3s service:${NC}"
    echo "   sudo systemctl stop k3s"
    echo "   sudo systemctl start k3s"
    echo "   sudo journalctl -u k3s -f"
    
    echo
    echo "3. ${GREEN}Clean restart:${NC}"
    echo "   sudo systemctl stop k3s"
    echo "   sudo pkill -f k3s"
    echo "   sudo rm -rf /var/lib/rancher/k3s/server/logs/*"
    echo "   sudo systemctl start k3s"
    
    echo
    echo "4. ${GREEN}Complete reinstall:${NC}"
    echo "   sudo /usr/local/bin/k3s-uninstall.sh"
    echo "   curl -sfL https://get.k3s.io | sh -s - --disable=traefik --write-kubeconfig-mode 644"
    
    echo
    echo "5. ${GREEN}Check for conflicts:${NC}"
    echo "   sudo netstat -tlnp | grep :6443"
    echo "   sudo pkill -f 'kube-apiserver|minikube|kind'"
    echo "   docker stop \$(docker ps -q --filter 'publish=6443')"
    
    echo
    echo "6. ${GREEN}Manual debugging:${NC}"
    echo "   sudo k3s server --log /tmp/k3s.log"
    echo "   # Run in another terminal to see detailed logs"
    
    echo
    echo "7. ${GREEN}System requirements check:${NC}"
    echo "   # Ensure your system meets minimum requirements:"
    echo "   # - Ubuntu 16.04+ (20.04+ recommended)"
    echo "   # - 1GB+ RAM"
    echo "   # - 1GB+ disk space"
    echo "   # - Working internet connection"
}

# Main function
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}    K3s Advanced Diagnostic Tool${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}This script will analyze your K3s installation${NC}"
    echo -e "${CYAN}and help identify why it's not becoming ready.${NC}"
    echo
    
    check_system_resources
    analyze_k3s_service
    analyze_failure_patterns
    analyze_k3s_logs
    check_network
    check_processes_ports
    check_k3s_files
    test_k3s_connectivity
    check_system_config
    generate_recommendations
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}    Diagnostic Complete${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${YELLOW}If you're still having issues:${NC}"
    echo "1. Save this output to a file for reference"
    echo "2. Try the recommendations above"
    echo "3. Check the official K3s documentation"
    echo "4. Consider the system requirements"
    echo
    echo -e "${CYAN}To save this output:${NC}"
    echo "./k3s_advanced_diagnostics.sh > k3s_diagnostics_\$(date +%Y%m%d_%H%M%S).log 2>&1"
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Please do not run this script as root.${NC}"
    echo "The script will use sudo when necessary."
    exit 1
fi

# Run main function
main "$@"