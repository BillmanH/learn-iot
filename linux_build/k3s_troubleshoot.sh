#!/bin/bash

# K3s Troubleshooting Script
# This script helps diagnose and fix K3s connectivity issues
# Author: K3s Troubleshooting Script
# Date: October 2025

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Check if running as root
check_root() {
    if [ "$EUID" -eq 0 ]; then
        error "Please do not run this script as root. Use sudo when prompted."
        exit 1
    fi
}

# Check port conflicts
check_ports() {
    log "Checking for port conflicts..."
    
    # Check port 6443 (Kubernetes API)
    if sudo netstat -tlnp 2>/dev/null | grep -q ":6443 "; then
        warn "Port 6443 is in use:"
        sudo netstat -tlnp 2>/dev/null | grep ":6443 "
        echo
        
        # Identify the process
        process=$(sudo netstat -tlnp 2>/dev/null | grep ":6443 " | awk '{print $7}' | head -1)
        info "Process using port 6443: $process"
        
        if [[ "$process" == *"k3s"* ]]; then
            info "K3s is using port 6443 - this might be a stuck process"
            return 1
        else
            info "Non-K3s process is using port 6443"
            return 2
        fi
    else
        log "Port 6443 is free"
        return 0
    fi
}

# Check K3s service status
check_k3s_service() {
    log "Checking K3s service status..."
    
    if systemctl list-unit-files | grep -q k3s.service; then
        info "K3s service is installed"
        
        if sudo systemctl is-active --quiet k3s; then
            info "K3s service is running"
            sudo systemctl status k3s --no-pager -l
        else
            warn "K3s service is not running"
            info "Service status:"
            sudo systemctl status k3s --no-pager -l || true
        fi
    else
        info "K3s service is not installed"
    fi
}

# Check K3s processes
check_k3s_processes() {
    log "Checking for K3s processes..."
    
    if pgrep -f k3s > /dev/null; then
        info "K3s processes found:"
        ps aux | grep -v grep | grep k3s
    else
        info "No K3s processes running"
    fi
}

# Check disk space
check_disk_space() {
    log "Checking disk space..."
    df -h
    
    # Check if root partition has less than 1GB free
    root_free=$(df / | awk 'NR==2 {print $4}' | sed 's/[^0-9]//g')
    if [ "$root_free" -lt 1000000 ]; then # Less than 1GB in KB
        warn "Low disk space on root partition!"
    fi
}

# Check memory
check_memory() {
    log "Checking memory usage..."
    free -h
    
    # Check if available memory is less than 1GB
    available_mem=$(free -m | awk 'NR==2{print $7}')
    if [ "$available_mem" -lt 1000 ]; then
        warn "Low available memory (less than 1GB)!"
    fi
}

# Check logs
check_logs() {
    log "Checking recent K3s logs..."
    
    if systemctl list-unit-files | grep -q k3s.service; then
        info "Recent K3s service logs:"
        sudo journalctl -u k3s --no-pager -n 20 || true
    else
        info "No K3s service found for log checking"
    fi
}

# Kill stuck K3s processes
kill_k3s_processes() {
    log "Stopping all K3s processes..."
    
    # Stop service first
    sudo systemctl stop k3s 2>/dev/null || true
    
    # Kill processes
    sudo pkill -f k3s || true
    
    # Wait a moment
    sleep 3
    
    # Force kill if still running
    if pgrep -f k3s > /dev/null; then
        warn "Force killing remaining K3s processes..."
        sudo pkill -9 -f k3s || true
    fi
    
    log "K3s processes stopped"
}

# Clean up port conflicts
cleanup_port_conflicts() {
    log "Attempting to clean up port conflicts..."
    
    # Get processes using port 6443
    processes=$(sudo netstat -tlnp 2>/dev/null | grep ":6443 " | awk '{print $7}' | cut -d'/' -f1 | sort -u)
    
    for pid in $processes; do
        if [ -n "$pid" ] && [ "$pid" != "-" ]; then
            process_name=$(ps -p $pid -o comm= 2>/dev/null || echo "unknown")
            warn "Killing process $pid ($process_name) using port 6443"
            sudo kill -TERM $pid 2>/dev/null || true
        fi
    done
    
    sleep 5
    
    # Force kill if still there
    processes=$(sudo netstat -tlnp 2>/dev/null | grep ":6443 " | awk '{print $7}' | cut -d'/' -f1 | sort -u)
    for pid in $processes; do
        if [ -n "$pid" ] && [ "$pid" != "-" ]; then
            warn "Force killing process $pid"
            sudo kill -9 $pid 2>/dev/null || true
        fi
    done
}

# Start K3s
start_k3s() {
    log "Starting K3s service..."
    
    sudo systemctl start k3s
    
    # Wait for it to start
    sleep 10
    
    # Check if it's running
    if sudo systemctl is-active --quiet k3s; then
        log "K3s service started successfully"
        return 0
    else
        error "Failed to start K3s service"
        return 1
    fi
}

# Test connectivity
test_connectivity() {
    log "Testing Kubernetes connectivity..."
    
    # Wait for API server to be ready
    local timeout=60
    local count=0
    
    while [ $count -lt $timeout ]; do
        if kubectl get nodes >/dev/null 2>&1; then
            log "Successfully connected to Kubernetes cluster"
            kubectl get nodes
            return 0
        fi
        
        sleep 2
        count=$((count + 2))
    done
    
    error "Failed to connect to Kubernetes cluster after $timeout seconds"
    return 1
}

# Main troubleshooting function
main() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}K3s Troubleshooting Script${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
    
    check_root
    
    log "Starting K3s diagnostics..."
    
    # Check system resources
    check_disk_space
    check_memory
    
    # Check for conflicts
    port_status=$(check_ports; echo $?)
    
    # Check K3s status
    check_k3s_service
    check_k3s_processes
    check_logs
    
    echo
    echo -e "${YELLOW}=== Diagnosis Summary ===${NC}"
    
    if [ "$port_status" -eq 1 ]; then
        warn "Port 6443 is occupied by K3s - likely a stuck process"
        read -p "Do you want to stop K3s processes and restart? (y/N): " restart_k3s
        if [[ "$restart_k3s" =~ ^[Yy]$ ]]; then
            kill_k3s_processes
            sleep 5
            start_k3s
            test_connectivity
        fi
    elif [ "$port_status" -eq 2 ]; then
        warn "Port 6443 is occupied by a non-K3s process"
        read -p "Do you want to stop the conflicting process? (y/N): " stop_conflict
        if [[ "$stop_conflict" =~ ^[Yy]$ ]]; then
            cleanup_port_conflicts
            sleep 5
            if systemctl list-unit-files | grep -q k3s.service; then
                start_k3s
                test_connectivity
            else
                info "K3s is not installed. Please run the installation script."
            fi
        fi
    else
        # Port is free, check if K3s is just not running
        if systemctl list-unit-files | grep -q k3s.service; then
            if ! sudo systemctl is-active --quiet k3s; then
                info "K3s is installed but not running"
                read -p "Do you want to start K3s? (y/N): " start_k3s_service
                if [[ "$start_k3s_service" =~ ^[Yy]$ ]]; then
                    start_k3s
                    test_connectivity
                fi
            else
                # K3s is running but kubectl might not be configured
                info "K3s is running, testing connectivity..."
                if ! test_connectivity; then
                    warn "K3s is running but kubectl cannot connect"
                    info "This might be a kubectl configuration issue"
                    echo "Try running: "
                    echo "  mkdir -p ~/.kube"
                    echo "  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config"
                    echo "  sudo chown \$(id -u):\$(id -g) ~/.kube/config"
                    echo "  chmod 0600 ~/.kube/config"
                fi
            fi
        else
            info "K3s is not installed. Please run the installation script."
        fi
    fi
    
    echo
    log "Troubleshooting completed!"
}

# Run main function
main "$@"