#!/bin/bash

# K3s Port Conflict Resolution Script
# This script checks for and resolves port conflicts on ports 6443 and 10257 that prevent K3s from starting

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

echo -e "${BLUE}=== K3s Port Conflict Resolution Script ===${NC}"
echo "This script will check for and resolve port conflicts that prevent K3s from starting."
echo "Checking ports: 6443 (API Server) and 10257 (Controller Manager)"
echo

# Check if a specific port is in use
check_port() {
    local port=$1
    # Try multiple methods to check the port
    if command -v ss >/dev/null 2>&1; then
        # Use ss (modern replacement for netstat)
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            return 0  # Port is in use
        fi
    elif command -v lsof >/dev/null 2>&1; then
        # Use lsof as fallback
        if lsof -i :$port 2>/dev/null | grep -q ":$port"; then
            return 0  # Port is in use
        fi
    elif command -v netstat >/dev/null 2>&1; then
        # Use netstat if available
        if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            return 0  # Port is in use
        fi
    else
        # Last resort: try to connect to the port
        if timeout 2 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            return 0  # Port is in use
        fi
    fi
    
    return 1  # Port is free
}

# Get process information for a specific port
get_port_info() {
    local port=$1
    # Try multiple methods to get process info
    if command -v ss >/dev/null 2>&1; then
        # Use ss (modern replacement for netstat)
        ss -tlnp 2>/dev/null | grep ":$port " | while read line; do
            # Extract PID and process name from ss output
            pid_process=$(echo "$line" | grep -o 'pid=[0-9]*' | cut -d'=' -f2)
            if [ -n "$pid_process" ]; then
                process_name=$(ps -p "$pid_process" -o comm= 2>/dev/null || echo "unknown")
                echo "PID: $pid_process, Process: $process_name"
            else
                # Try alternative parsing for ss output
                users_field=$(echo "$line" | awk '{print $6}')
                if [[ "$users_field" == *"pid="* ]]; then
                    pid=$(echo "$users_field" | sed 's/.*pid=\([0-9]*\).*/\1/')
                    process_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                    echo "PID: $pid, Process: $process_name"
                fi
            fi
        done
    elif command -v lsof >/dev/null 2>&1; then
        # Use lsof as fallback
        lsof -i :$port 2>/dev/null | grep ":$port" | while read line; do
            pid=$(echo "$line" | awk '{print $2}')
            process=$(echo "$line" | awk '{print $1}')
            echo "PID: $pid, Process: $process"
        done
    elif command -v netstat >/dev/null 2>&1; then
        # Use netstat if available
        netstat -tlnp 2>/dev/null | grep ":$port " | while read line; do
            pid=$(echo "$line" | awk '{print $7}' | cut -d'/' -f1)
            process=$(echo "$line" | awk '{print $7}' | cut -d'/' -f2)
            echo "PID: $pid, Process: $process"
        done
    else
        # Manual process search as last resort
        warn "No suitable tools found (ss, lsof, netstat). Searching for common processes..."
        pgrep -f "k3s\|kube\|minikube\|kind" | while read pid; do
            if [ -n "$pid" ]; then
                process_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                echo "PID: $pid, Process: $process_name"
            fi
        done
    fi
}

# Kill processes using a specific port
kill_port_processes() {
    local port=$1
    local process_info="$2"
    local pid=$(echo "$process_info" | grep "PID:" | cut -d' ' -f2 | cut -d',' -f1)
    local process_name=$(echo "$process_info" | grep "Process:" | cut -d' ' -f2)
    
    if [ -n "$pid" ] && [ "$pid" != "unknown" ] && [ "$pid" != "" ]; then
        info "Found process using port $port: PID $pid ($process_name)"
        
        # Check if it's a K3s process
        if echo "$process_name" | grep -q -E "(k3s|kube)"; then
            warn "Found K3s/Kubernetes process on port $port. This might be a stuck K3s process."
            echo -n "Kill this process? [y/N]: "
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                log "Killing PID $pid ($process_name)..."
                if kill -TERM "$pid" 2>/dev/null; then
                    sleep 2
                    if kill -0 "$pid" 2>/dev/null; then
                        warn "Process still running, using SIGKILL..."
                        kill -KILL "$pid" 2>/dev/null || true
                    fi
                    log "Process $pid killed successfully"
                    return 0
                else
                    error "Failed to kill process $pid"
                    return 1
                fi
            else
                warn "Skipping process termination"
                return 1
            fi
        else
            # Non-K3s process
            error "Non-K3s process detected on port $port: $process_name (PID: $pid)"
            echo "This could be Docker, minikube, kind, or another application."
            echo -n "Kill this process? [y/N]: "
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                log "Killing PID $pid ($process_name)..."
                if kill -TERM "$pid" 2>/dev/null; then
                    sleep 2
                    if kill -0 "$pid" 2>/dev/null; then
                        warn "Process still running, using SIGKILL..."
                        kill -KILL "$pid" 2>/dev/null || true
                    fi
                    log "Process $pid killed successfully"
                    return 0
                else
                    error "Failed to kill process $pid"
                    return 1
                fi
            else
                warn "Skipping process termination"
                return 1
            fi
        fi
    else
        warn "Could not determine PID for port $port"
        return 1
    fi
}

# Check and resolve conflicts for a specific port
check_and_fix_port() {
    local port=$1
    local port_name=$2
    
    info "Checking port $port ($port_name)..."
    
    if check_port $port; then
        error "Port $port is already in use!"
        info "Getting process information for port $port..."
        
        local process_info=$(get_port_info $port)
        if [ -n "$process_info" ]; then
            echo "Process using port $port:"
            echo "$process_info"
            echo
            
            if kill_port_processes $port "$process_info"; then
                sleep 2
                if check_port $port; then
                    error "Port $port is still in use after attempting to kill processes"
                    return 1
                else
                    log "Port $port is now free"
                    return 0
                fi
            else
                warn "Could not free port $port"
                return 1
            fi
        else
            warn "Could not identify process using port $port"
            return 1
        fi
    else
        log "Port $port is free"
        return 0
    fi
}

# Main execution
main() {
    log "Starting K3s port conflict resolution..."
    
    # Check current K3s status
    info "Checking K3s service status..."
    if systemctl is-active --quiet k3s 2>/dev/null; then
        warn "K3s service is currently running. Stopping it first..."
        sudo systemctl stop k3s || true
        sleep 3
    fi
    
    local ports_fixed=0
    local total_ports=2
    
    # Check port 6443 (API Server)
    if check_and_fix_port 6443 "Kube API Server"; then
        ((ports_fixed++))
    fi
    
    echo
    
    # Check port 10257 (Controller Manager)
    if check_and_fix_port 10257 "Kube Controller Manager"; then
        ((ports_fixed++))
    fi
    
    echo
    info "Port check summary: $ports_fixed/$total_ports ports are free"
    
    if [ $ports_fixed -eq $total_ports ]; then
        log "All required ports are now free. Starting K3s..."
        
        # Start K3s service
        if sudo systemctl start k3s; then
            log "K3s service started successfully"
            
            # Wait a moment and check status
            sleep 5
            if sudo systemctl is-active --quiet k3s; then
                log "K3s is running successfully!"
                info "Checking cluster status..."
                
                # Wait for K3s to be ready
                for i in {1..30}; do
                    if sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
                        log "K3s cluster is ready!"
                        sudo k3s kubectl get nodes
                        break
                    fi
                    echo -n "."
                    sleep 2
                done
                echo
                
            else
                error "K3s service failed to start properly"
                warn "Check the logs with: sudo journalctl -u k3s -f"
                return 1
            fi
        else
            error "Failed to start K3s service"
            return 1
        fi
    else
        error "Some ports are still in use. Cannot start K3s safely."
        warn "Please resolve the remaining port conflicts manually."
        return 1
    fi
}

# Check if running as root or with sudo
if [ "$EUID" -eq 0 ]; then
    warn "Running as root. This is fine for K3s operations."
elif command -v sudo >/dev/null 2>&1; then
    info "Will use sudo for system operations"
else
    error "This script requires root privileges or sudo access"
    exit 1
fi

# Run main function
main "$@"