#!/usr/bin/env bash
# save_log.sh
# Uploads the most recent onvif_diag log file to a Kubernetes ConfigMap
# so it can be retrieved from a remote kubectl session.
# Usage: bash issues/save_log.sh

set -euo pipefail

NAMESPACE="azure-iot-operations"
CONFIGMAP_NAME="onvif-diag-log"
SCRIPT_DIR="$(dirname "$0")"

# Find the most recent log file
LOGFILE=$(ls -t "$SCRIPT_DIR"/onvif_diag_*.log 2>/dev/null | head -1)

if [ -z "$LOGFILE" ]; then
    echo "ERROR: No onvif_diag_*.log file found in $SCRIPT_DIR"
    echo "Run collect_onvif_diag.sh first."
    exit 1
fi

echo "Uploading: $LOGFILE"
echo "ConfigMap:  $CONFIGMAP_NAME in namespace $NAMESPACE"

kubectl create configmap "$CONFIGMAP_NAME" \
    --from-file=diag.log="$LOGFILE" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "Done. Retrieve from Windows with:"
echo "  kubectl get configmap $CONFIGMAP_NAME -n $NAMESPACE -o jsonpath='{.data.diag\.log}'"
