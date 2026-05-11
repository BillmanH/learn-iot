#!/usr/bin/env bash
# upload_diag.sh — uploads the most recent onvif_full_*.log to the onvif-diag-log ConfigMap
LOGFILE=$(ls -t "$(dirname "$0")"/onvif_full_*.log 2>/dev/null | head -1)
if [ -z "$LOGFILE" ]; then
    echo "ERROR: No onvif_full_*.log found. Run collect_onvif_diag.sh first."
    exit 1
fi
echo "Uploading: $LOGFILE"
kubectl create configmap onvif-diag-log --from-file=diag.log="$LOGFILE" \
    -n azure-iot-operations --dry-run=client -o yaml | kubectl apply -f -
echo "Done."
