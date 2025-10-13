#!/bin/bash

# K3s Port 6443 Conflict Resolver
# This script identifies and resolves port 6443 conflicts for K3s

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING: $1${NC}"; }
error() { echo -e "${RED}[$(date +'%H:%M:%S')] ERROR: $1${NC}"; }
info() { echo -e "${BLUE}[$(date +'%H:%M:%S')] INFO: $1${NC}"; }

# Check if port 6443 is in use
check_port_6443() {
    if sudo netstat -tlnp 2>/dev/null | grep -q ":6443 "; then
        return 0  # Port is in use
    else
        return 1  # Port is free
    fi
}

# Get process information for port 6443
get_port_6443_info() {
    sudo netstat -tlnp 2>/dev/null | grep ":6443 " | while read line; do
        pid=$(echo "$line" | awk '{print $7}' | cut -d'/' -f1)
        process=$(echo "$line" | awk '{print $7}' | cut -d'/' -f2)
        echo "PID: $pid, Process: $process"
    done
}

# Kill processes using port 6443
kill_port_6443_processes() {
    local process_info="$1"
    local pid=$(echo "$process_info" | grep "PID:" | cut -d' ' -f2 | cut -d',' -f1)
    local process_name=$(echo "$process_info" | grep "Process:" | cut -d' ' -f2)
    
    if [ -n "$pid" ] && [ "$pid" != "-" ]; then
        info "Attempting to stop process $pid ($process_name)"
        
        # Try graceful termination first
        if sudo kill -TERM "$pid" 2>/dev/null; then
            log "Sent TERM signal to process $pid"
            sleep 3
            
            # Check if process is still running
            if kill -0 "$pid" 2>/dev/null; then
                warn "Process $pid still running, force killing..."
                sudo kill -9 "$pid" 2>/dev/null || true
            fi
        else
            warn "Failed to send TERM signal, trying force kill..."
            sudo kill -9 "$pid" 2>/dev/null || true
        fi
    fi
}

# Handle K3s specific processes
handle_k3s_processes() {
    log "Handling K3s processes..."
    
    # Stop K3s service
    sudo systemctl stop k3s 2>/dev/null || true
    
    # Kill K3s processes
    sudo pkill -f k3s 2>/dev/null || true
    
    # Wait for processes to die
    sleep 5
    
    log "K3s processes handled"
}

# Handle other Kubernetes distributions
handle_other_k8s() {
    log "Handling other Kubernetes distributions..."
    
    # Minikube
    if command -v minikube >/dev/null 2>&1; then
        info "Stopping minikube..."
        minikube stop 2>/dev/null || true
        minikube delete 2>/dev/null || true
    fi
    
    # Kind
    if command -v kind >/dev/null 2>&1; then
        info "Stopping kind clusters..."
        kind delete cluster 2>/dev/null || true
    fi
    
    # Generic kubernetes processes
    sudo pkill -f kube-apiserver 2>/dev/null || true
    sudo pkill -f kubelet 2>/dev/null || true
    
    log "Other Kubernetes distributions handled"
}

# Handle Docker containers
handle_docker_containers() {
    if command -v docker >/dev/null 2>&1; then
        log "Handling Docker containers using port 6443..."
        
        # Find containers using port 6443
        local containers=$(docker ps -q --filter "publish=6443" 2>/dev/null || true)
        
        if [ -n "$containers" ]; then
            info "Stopping Docker containers using port 6443..."
            echo "$containers" | xargs docker stop 2>/dev/null || true
        fi
        
        # Check for any containers with port 6443 in their port mappings
        docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Ports}}" | grep 6443 | while read line; do
            container_id=$(echo "$line" | awk '{print $1}')
            container_name=$(echo "$line" | awk '{print $2}')
            info "Stopping container $container_name ($container_id)"
            docker stop "$container_id" 2>/dev/null || true
        done
        
        log "Docker containers handled"
    fi
}

# Main resolution function
resolve_port_conflict() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}    K3s Port 6443 Conflict Resolver${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    if ! check_port_6443; then
        log "Port 6443 is free! No conflict detected."
        return 0
    fi
    
    warn "Port 6443 is in use. Analyzing..."
    
    # Get detailed information about what's using the port
    local port_info=$(get_port_6443_info)
    echo -e "${YELLOW}Process(es) using port 6443:${NC}"
    echo "$port_info"
    echo
    
    # Ask user for confirmation
    read -p "Do you want to automatically resolve this conflict? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Manual resolution selected. Here's what you can do:"
        echo
        echo "1. For K3s processes:"
        echo "   sudo systemctl stop k3s"
        echo "   sudo pkill -f k3s"
        echo
        echo "2. For other Kubernetes:"
        echo "   sudo pkill -f kube-apiserver"
        echo "   minikube stop"
        echo "   kind delete cluster"
        echo
        echo "3. For Docker containers:"
        echo "   docker stop \$(docker ps -q --filter \"publish=6443\")"
        echo
        echo "4. For specific process (replace <PID>):"
        echo "   sudo kill -9 <PID>"
        return 0
    fi
    
    # Automatic resolution
    log "Starting automatic conflict resolution..."
    
    # Check what type of process is using the port
    if echo "$port_info" | grep -q "k3s"; then
        info "Detected K3s process conflict"
        handle_k3s_processes
    elif echo "$port_info" | grep -qE "kube|minikube|kind"; then
        info "Detected other Kubernetes distribution"
        handle_other_k8s
    else
        info "Detected unknown process, attempting to kill..."
        echo "$port_info" | while read line; do
            kill_port_6443_processes "$line"
        done
    fi
    
    # Handle Docker containers
    handle_docker_containers
    
    # Wait a moment for processes to fully terminate
    log "Waiting for processes to terminate..."
    sleep 5
    
    # Check if port is now free
    if ! check_port_6443; then
        log "SUCCESS: Port 6443 is now free!"
        
        # Try to start K3s
        read -p "Do you want to start K3s now? (y/N): " start_k3s
        if [[ "$start_k3s" =~ ^[Yy]$ ]]; then
            log "Starting K3s..."
            sudo systemctl start k3s
            
            # Monitor startup for a few seconds
            log "Monitoring K3s startup..."
            timeout 30 sudo journalctl -u k3s -f &
            MONITOR_PID=$!
            
            sleep 10
            kill $MONITOR_PID 2>/dev/null || true
            
            # Check if K3s is running
            if sudo systemctl is-active --quiet k3s; then
                log "K3s started successfully!"
                sudo k3s kubectl get nodes 2>/dev/null || warn "K3s is starting, nodes may not be ready yet"
            else
                error "K3s failed to start. Check logs with: sudo journalctl -u k3s -f"
            fi
        fi
    else
        error "FAILED: Port 6443 is still in use!"
        warn "Manual intervention required:"
        get_port_6443_info
        echo
        echo "Try these commands manually:"
        echo "sudo netstat -tlnp | grep :6443"
        echo "sudo kill -9 <PID_FROM_OUTPUT>"
    fi
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    error "Please do not run this script as root."
    exit 1
fi

# Run the resolver
resolve_port_conflict