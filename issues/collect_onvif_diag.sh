#!/usr/bin/env bash
# collect_onvif_diag.sh
# Run on the NUC directly (not through Arc proxy). Captures ONVIF connector
# diagnostics and the raw SOAP traffic to the camera to diagnose auth failure.
# Output: issues/onvif_diag_<timestamp>.log

set -euo pipefail

LOGFILE="$(dirname "$0")/onvif_diag_$(date -u +%Y%m%dT%H%M%SZ).log"
CAMERA_IP="10.0.0.48"
CAMERA_PORT="2020"
NAMESPACE="azure-iot-operations"
POD="azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0"
PCAP_FILE="/tmp/onvif_capture_$$.pcap"
CAPTURE_SECONDS=35   # long enough to catch one connector retry

log() { echo "$@" | tee -a "$LOGFILE"; }

log "=== ONVIF Connector Diagnostics ==="
log "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "Log file:  $LOGFILE"
log ""

# --- 1. Connector pod status ---
log "--- 1. Connector pod status ---"
kubectl get pod "$POD" -n "$NAMESPACE" -o wide 2>&1 | tee -a "$LOGFILE"
log ""

# --- 2. Pod IP ---
POD_IP=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "unknown")
log "Connector pod IP: $POD_IP"
log ""

# --- 3. Credential files actually mounted in the connector ---
log "--- 3. Mounted credentials (direct from pod filesystem via /proc) ---"
# Find PID of the connector process on the host
CONTAINER_ID=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | sed 's|containerd://||')
if [ -n "$CONTAINER_ID" ]; then
    # Look up the host PID for the container
    HOST_PID=$(crictl inspect "$CONTAINER_ID" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['pid'])" 2>/dev/null || echo "")
    if [ -n "$HOST_PID" ]; then
        CREDS_DIR="/proc/$HOST_PID/root/etc/akri/secrets/device_endpoint_auth/azureiotoperationsconnectorforonvif-8404-612d9fbf"
        log "Container PID: $HOST_PID"
        # Print credentials to screen only — NOT written to log file
        USERNAME=$(cat "$CREDS_DIR/tapo-desk_tapo-onvif-desk_username" 2>/dev/null || echo "ERROR: could not read")
        PASSWORD=$(cat "$CREDS_DIR/tapo-desk_tapo-onvif-desk_password" 2>/dev/null || echo "ERROR: could not read")
        echo ""
        echo "  *** CREDENTIAL CHECK (screen only, not in log) ***"
        echo "  Username: '$USERNAME' (${#USERNAME} chars)"
        echo "  Password: '$PASSWORD' (${#PASSWORD} chars)"
        echo "  *****"
        echo ""
        log "Username length: ${#USERNAME} chars"
        log "Password length: ${#PASSWORD} chars"
        log "Username hex:"
        echo -n "$USERNAME" | xxd 2>&1 | tee -a "$LOGFILE"
        log "Password hex: (redacted from log)"
        echo -n "$PASSWORD" | xxd 2>&1   # screen only
        log ""
    else
        log "Could not determine host PID for container"
    fi
else
    log "Could not get container ID"
fi

# --- 4. Recent connector logs ---
log "--- 4. Connector logs (last 60 lines) ---"
kubectl logs "$POD" -n "$NAMESPACE" --tail=60 2>&1 | tee -a "$LOGFILE"
log ""

# --- 5. Capture live SOAP traffic with tcpdump ---
log "--- 5. Capturing ONVIF SOAP traffic for ${CAPTURE_SECONDS}s (tcpdump) ---"
log "    Camera: $CAMERA_IP:$CAMERA_PORT"
log "    Waiting for connector to send a request..."

if ! command -v tcpdump &>/dev/null; then
    log "tcpdump not found — skipping packet capture (install with: sudo apt-get install -y tcpdump)"
else
    # Run tcpdump in background, capture traffic between pod and camera
    sudo tcpdump -i any -s 0 -w "$PCAP_FILE" \
        "host $CAMERA_IP and port $CAMERA_PORT" 2>&1 &
    TCPDUMP_PID=$!
    log "tcpdump PID: $TCPDUMP_PID — capturing for ${CAPTURE_SECONDS}s..."

    # Delete+wait for pod restart to trigger a fresh connection attempt
    log "Restarting connector pod to force immediate auth attempt..."
    kubectl delete pod "$POD" -n "$NAMESPACE" 2>&1 | tee -a "$LOGFILE"
    kubectl wait pod "$POD" -n "$NAMESPACE" --for=condition=Ready --timeout=60s 2>&1 | tee -a "$LOGFILE"

    # Wait for the capture window
    sleep "$CAPTURE_SECONDS"
    sudo kill "$TCPDUMP_PID" 2>/dev/null || true
    wait "$TCPDUMP_PID" 2>/dev/null || true

    log "Capture complete: $PCAP_FILE"
    log ""

    # Decode SOAP bodies from the capture
    log "--- 5a. SOAP request bodies (ASCII extract from pcap) ---"
    if command -v strings &>/dev/null; then
        strings "$PCAP_FILE" | grep -A 30 "Envelope\|UsernameToken\|wsse:" | head -100 | tee -a "$LOGFILE" || true
    fi
    log ""

    # Human-readable decode with tcpdump -A (no external tools needed)
    log "--- 5b. Raw tcpdump -A decode ---"
    sudo tcpdump -A -r "$PCAP_FILE" 2>&1 | grep -A 5 "Username\|Password\|Nonce\|Created\|NotAuth\|SOAP\|Envelope" | head -80 | tee -a "$LOGFILE" || true
    log ""

    # Copy pcap to issues folder for wireshark analysis
    PCAP_OUT="$(dirname "$0")/onvif_capture_$(date -u +%Y%m%dT%H%M%SZ).pcap"
    cp "$PCAP_FILE" "$PCAP_OUT"
    log "Pcap saved to: $PCAP_OUT"
    rm -f "$PCAP_FILE"
fi

# --- 6. Post-restart logs ---
log "--- 6. Connector logs after restart ---"
sleep 5
kubectl logs "$POD" -n "$NAMESPACE" --tail=30 2>&1 | tee -a "$LOGFILE"
log ""

# --- 7. Node clock check ---
log "--- 7. Node clock ---"
log "NUC clock (date -u): $(date -u)"
log "NUC hwclock:         $(sudo hwclock --utc 2>/dev/null || echo 'hwclock unavailable')"
log ""

log "=== Done. Log saved to: $LOGFILE ==="
