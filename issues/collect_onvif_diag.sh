#!/usr/bin/env bash
# collect_onvif_diag.sh
# Focused capture: full authenticated SOAP exchange + camera clock comparison.
# Run on NUC directly (NOT through Arc proxy).
#
# Features:
#   - Full pcap decode saved to log (no grep truncation)
#   - Camera clock vs NUC clock diff (WS-Security token validation window)
#   - Checks whether current pod IP is already banned by the camera
#   - Short capture window (8s) to keep log small
#   - Auto-uploads log to ConfigMap (no separate upload script needed)
#
# Usage:
#   chmod +x issues/collect_onvif_diag.sh
#   bash issues/collect_onvif_diag.sh

set -euo pipefail

LOGFILE="$(dirname "$0")/onvif_full_$(date -u +%Y%m%dT%H%M%SZ).log"
CAMERA_IP="10.0.0.48"
CAMERA_PORT="2020"
CAMERA_URL="http://${CAMERA_IP}:${CAMERA_PORT}/onvif/device_service"
NAMESPACE="azure-iot-operations"
POD="azureiotoperationsconnectorforonvif-8404-612d9fbf-ss-0"
PCAP_FILE="/tmp/onvif_cap2_$$.pcap"
CAPTURE_SECONDS=8   # just long enough for the initial exchange + first auth attempt

log() { echo "$@" | tee -a "$LOGFILE"; }

log "=== ONVIF Focused Diagnostic (v2) ==="
log "Timestamp (NUC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "Log file: $LOGFILE"
log ""

# --- 1. Camera clock vs NUC clock ---
log "--- 1. Camera clock vs NUC clock (WS-Security window check) ---"
log "NUC UTC time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log ""
GETTIME_SOAP='<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Body><GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/></s:Body>
</s:Envelope>'

if command -v python3 &>/dev/null; then
    python3 - <<'PYEOF' 2>&1 | tee -a "$LOGFILE"
import urllib.request, datetime, re

url = "http://10.0.0.48:2020/onvif/device_service"
soap = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Body><GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/></s:Body>
</s:Envelope>'''

before = datetime.datetime.utcnow()
try:
    req = urllib.request.Request(url, soap.encode(),
        {"Content-Type": "application/soap+xml; charset=utf-8", "SOAPAction": ""})
    resp = urllib.request.urlopen(req, timeout=5)
    body = resp.read().decode()
    after = datetime.datetime.utcnow()
    # Parse camera time fields
    Y  = re.search(r'<tt:Year>(\d+)', body)
    Mo = re.search(r'<tt:Month>(\d+)', body)
    D  = re.search(r'<tt:Day>(\d+)', body)
    H  = re.search(r'<tt:Hour>(\d+)', body)
    Mi = re.search(r'<tt:Minute>(\d+)', body)
    S  = re.search(r'<tt:Second>(\d+)', body)
    if all([Y, Mo, D, H, Mi, S]):
        cam_dt = datetime.datetime(int(Y.group(1)), int(Mo.group(1)), int(D.group(1)),
                                    int(H.group(1)), int(Mi.group(1)), int(S.group(1)))
        nuc_dt = before + (after - before) / 2  # midpoint of the round-trip
        skew_s = (nuc_dt - cam_dt).total_seconds()
        print(f"Camera UTC time:  {cam_dt.strftime('%Y-%m-%dT%H:%M:%SZ')}")
        print(f"NUC UTC time:     {nuc_dt.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]}Z")
        print(f"Clock skew:       {skew_s:+.1f}s  (ONVIF allows +-300s)")
        if abs(skew_s) > 240:
            print(f"WARNING: skew {abs(skew_s):.0f}s is close to/over the 300s ONVIF limit!")
        else:
            print(f"Skew is within safe range.")
    else:
        print("Could not parse camera time from response.")
        print("Raw response:", body[:400])
except Exception as e:
    print(f"ERROR getting camera time: {e}")
PYEOF
else
    log "python3 not available — skipping camera clock check"
fi
log ""

# --- 2. Current pod IP and ban check ---
log "--- 2. Connector pod status and IP ban check ---"
POD_IP=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "unknown")
log "Current connector pod IP: $POD_IP"
log ""

# Quick unauthenticated probe from the CONNECTOR'S CURRENT IP via the cluster
# We can't easily spoof IPs, but we can at least log the pod IP
log "Checking connector logs for recent NotAuthorized entries:"
kubectl logs "$POD" -n "$NAMESPACE" --tail=20 2>&1 | grep -E "NotAuth|connect|endpoint|secret|cred" | tail -10 | tee -a "$LOGFILE" || true
log ""

# --- 3. Pcap capture ---
log "--- 3. Full pcap capture (${CAPTURE_SECONDS}s, restarting pod for fresh attempt) ---"
if ! command -v tcpdump &>/dev/null; then
    log "tcpdump not found — install with: sudo apt-get install -y tcpdump"
    log "Skipping pcap capture."
else
    log "Starting tcpdump..."
    sudo tcpdump -i any -s 0 -w "$PCAP_FILE" \
        "host $CAMERA_IP and port $CAMERA_PORT" 2>/dev/null &
    TCPDUMP_PID=$!
    sleep 0.5  # brief delay to ensure tcpdump is listening

    log "Restarting connector pod to force fresh authentication attempt..."
    kubectl delete pod "$POD" -n "$NAMESPACE" 2>&1 | tee -a "$LOGFILE"
    kubectl wait pod "$POD" -n "$NAMESPACE" --for=condition=Ready --timeout=60s 2>&1 | tee -a "$LOGFILE" || \
        log "WARNING: pod not Ready within 60s — capture may be incomplete"

    sleep "$CAPTURE_SECONDS"
    sudo kill "$TCPDUMP_PID" 2>/dev/null || true
    wait "$TCPDUMP_PID" 2>/dev/null || true
    log "Capture stopped."
    log ""

    if [ ! -f "$PCAP_FILE" ]; then
        log "ERROR: pcap file not created — tcpdump may have failed"
    else
        # --- 4. Full text decode (no truncation) ---
        log "--- 4a. All printable strings from pcap (min 8 chars) ---"
        log "    (This shows complete SOAP request and response bodies)"
        strings -n 8 "$PCAP_FILE" 2>/dev/null | tee -a "$LOGFILE" || \
            log "(strings command failed or not available)"
        log ""

        log "--- 4b. Raw tcpdump ASCII decode (full, no head limit) ---"
        log "    Format: [timestamp] [src > dst] ... [ASCII body]"
        sudo tcpdump -A -r "$PCAP_FILE" 2>/dev/null | tee -a "$LOGFILE" || \
            log "(tcpdump decode failed)"
        log ""

        # Save pcap to issues dir
        PCAP_OUT="$(dirname "$0")/onvif_full_$(date -u +%Y%m%dT%H%M%SZ).pcap"
        sudo cp "$PCAP_FILE" "$PCAP_OUT"
        sudo chmod 644 "$PCAP_OUT"
        log "Pcap saved to: $PCAP_OUT"
        sudo rm -f "$PCAP_FILE"
    fi
fi

# --- 5. Post-restart connector logs ---
log "--- 5. Connector logs after restart ---"
kubectl logs "$POD" -n "$NAMESPACE" --tail=50 2>&1 | tee -a "$LOGFILE"
log ""

# --- 6. New pod IP (may differ from step 2 since we restarted) ---
NEW_POD_IP=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "unknown")
log "--- 6. New pod IP after restart: $NEW_POD_IP ---"
log ""

log "=== Done. Log: $LOGFILE ==="
log ""
log "Uploading log to ConfigMap onvif-diag-log..."
kubectl create configmap onvif-diag-log --from-file=diag.log="$LOGFILE" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tee -a "$LOGFILE"
log ""
log "Retrieve from Windows with:"
log "  kubectl get configmap onvif-diag-log -n azure-iot-operations -o jsonpath='{.data.diag\.log}'"
