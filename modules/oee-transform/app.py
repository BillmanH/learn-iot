"""
OEE Transform - MQTT subscription → enrich → re-publish

Subscribes to factory/# on the AIO MQTT broker, runs every message through
the OEE enrichment logic, and re-publishes to factory/transformed/<subpath>.

Authentication: Kubernetes ServiceAccountToken (K8S-SAT), same pattern used
by edgemqttsim.

Build:
  az acr build --registry <ACR> --image oee-transform:latest .

Deploy:
  kubectl apply -f deployment.yaml
"""

import json
import logging
import os
import ssl
import time
from pathlib import Path

import paho.mqtt.client as mqtt

import transform

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MQTT_BROKER    = os.environ.get("MQTT_BROKER",    "aio-broker.azure-iot-operations.svc.cluster.local")
MQTT_PORT      = int(os.environ.get("MQTT_PORT",  "18883"))
INPUT_TOPIC    = os.environ.get("INPUT_TOPIC",    "factory/#")
OUTPUT_PREFIX  = os.environ.get("OUTPUT_PREFIX",  "factory/transformed")
CLIENT_ID      = os.environ.get("MQTT_CLIENT_ID", f"oee-transform-{os.getpid()}")
AUTH_METHOD    = os.environ.get("MQTT_AUTH_METHOD", "K8S-SAT")
SAT_TOKEN_PATH = os.environ.get("SAT_TOKEN_PATH",  "/var/run/secrets/tokens/broker-sat")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------
_stats = {"received": 0, "published": 0, "errors": 0}


def _log_stats():
    log.info(
        "Stats: received=%d published=%d errors=%d",
        _stats["received"], _stats["published"], _stats["errors"],
    )


# ---------------------------------------------------------------------------
# MQTT helpers
# ---------------------------------------------------------------------------

def _read_sat_token() -> str | None:
    p = Path(SAT_TOKEN_PATH)
    if p.exists():
        token = p.read_text().strip()
        log.info("SAT token loaded from %s (%d chars)", SAT_TOKEN_PATH, len(token))
        return token
    log.error("SAT token not found at %s", SAT_TOKEN_PATH)
    return None


def _output_topic(input_topic: str) -> str:
    """
    factory/cnc          → factory/transformed/cnc
    factory/line1/welder → factory/transformed/line1/welder
    """
    prefix = INPUT_TOPIC.rstrip("/#")         # "factory"
    suffix = input_topic[len(prefix):].lstrip("/")  # "cnc" or "line1/welder"
    return f"{OUTPUT_PREFIX}/{suffix}" if suffix else OUTPUT_PREFIX


# ---------------------------------------------------------------------------
# Callbacks
# ---------------------------------------------------------------------------

def on_connect(client, userdata, flags, reason_code, properties=None):
    rc = reason_code.value if hasattr(reason_code, "value") else reason_code
    if rc == 0:
        log.info("Connected to broker %s:%d", MQTT_BROKER, MQTT_PORT)
        client.subscribe(INPUT_TOPIC, qos=1)
        log.info("Subscribed to %s", INPUT_TOPIC)
    else:
        log.error("Connection failed with code %s", reason_code)


def on_disconnect(client, userdata, disconnect_flags, reason_code, properties=None):
    log.warning("Disconnected (reason=%s) — will reconnect", reason_code)


def on_message(client, userdata, msg):
    _stats["received"] += 1
    try:
        payload_str = msg.payload.decode("utf-8")
        enriched_str = transform.process(payload_str)
        out_topic = _output_topic(msg.topic)
        client.publish(out_topic, enriched_str, qos=1)
        _stats["published"] += 1

        if _stats["received"] % 100 == 0:
            _log_stats()

    except Exception as e:
        _stats["errors"] += 1
        log.error("Error processing message from %s: %s", msg.topic, e)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def build_client() -> mqtt.Client:
    client = mqtt.Client(
        client_id=CLIENT_ID,
        protocol=mqtt.MQTTv5,
    )
    client.on_connect    = on_connect
    client.on_disconnect = on_disconnect
    client.on_message    = on_message

    if AUTH_METHOD == "K8S-SAT":
        token = _read_sat_token()
        if token:
            client.username_pw_set(username=token, password=None)
        else:
            log.warning("Proceeding without SAT token (will likely fail auth)")

    # TLS — AIO broker requires TLS even on the internal cluster port
    tls_ctx = ssl.create_default_context()
    tls_ctx.check_hostname = False
    tls_ctx.verify_mode = ssl.CERT_NONE
    client.tls_set_context(tls_ctx)

    return client


def main():
    log.info("OEE Transform starting — %s → %s", INPUT_TOPIC, OUTPUT_PREFIX)
    client = build_client()

    while True:
        try:
            client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
            client.loop_forever()
        except Exception as e:
            log.error("Connection error: %s — retrying in 5s", e)
            time.sleep(5)


if __name__ == "__main__":
    main()
