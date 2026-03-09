# Python WASM Map Operator - Factory OEE Enrichment
#
# Implements the same OEE enrichment as modules/wasm/wasm-rust but in Python.
# This is a Map operator: receives one DataModel message, returns one enriched message.
#
# Build (local):
#   pip install "componentize-py==0.14"
#   git clone https://github.com/Azure-Samples/explore-iot-operations.git
#   cp explore-iot-operations/samples/wasm-python/schema ./schema  (all .wit files)
#   componentize-py -d ./schema -w map-impl bindings ./
#   componentize-py -d ./schema -w map-impl componentize oee_enrich -o oee_enrich.wasm
#
# Build (Docker, same as used in acr-task.yaml):
#   docker run --rm -v "$(pwd):/workspace" \
#     ghcr.io/azure-samples/explore-iot-operations/python-wasm-builder \
#     --app-name oee_enrich --app-type map
#
# The generated bindings are placed alongside this file by componentize-py.
# Do NOT commit the generated map_impl/ bindings directory.

import json
from map_impl import exports
from map_impl import imports
from map_impl.imports import types


# ---------------------------------------------------------------------------
# OEE calculation helpers
# ---------------------------------------------------------------------------

def _availability(status: str) -> float:
    """1.0 if machine is running, 0.0 if stopped/error."""
    if status in ("running", "active", "printing", "welding", "painting", "testing"):
        return 1.0
    if status in ("idle",):
        return 0.5
    return 0.0


def _quality_score(data: dict) -> float:
    """
    Derive a 0.0-1.0 quality score from the message payload.
    Mirrors the logic in modules/wasm/wasm-rust/src/transform.rs.
    """
    quality = data.get("quality")
    if isinstance(quality, str):
        if quality == "good":
            return 1.0
        if quality in ("scrap", "fail"):
            return 0.0
        if quality == "rework":
            return 0.5
        # null / in-progress
        return 1.0

    # Numeric good/scrap fields
    good = data.get("good")
    scrap = data.get("scrap")
    if good is not None and scrap is not None:
        try:
            g, s = float(good), float(scrap)
            total = g + s
            return g / total if total > 0 else 1.0
        except (TypeError, ValueError):
            pass

    # test_result field used by testing rigs
    test_result = data.get("test_result")
    if test_result is not None:
        return 1.0 if test_result == "pass" else 0.0

    return 1.0  # unknown -> assume good


def _performance(data: dict) -> float:
    """
    Compare actual cycle_time to an expected baseline by machine type.
    Returns a 0.0-1.0 performance ratio.
    """
    EXPECTED_CYCLE_TIMES = {
        "cnc": 120.0,
        "printer": 3600.0,
        "welder": 45.0,
        "painter": 90.0,
        "tester": 30.0,
    }

    cycle_time = data.get("cycle_time")
    if cycle_time is None:
        return 1.0

    try:
        ct = float(cycle_time)
    except (TypeError, ValueError):
        return 1.0

    # Infer machine type from machine_id (e.g. "cnc-001" -> "cnc")
    machine_id = data.get("machine_id", "")
    machine_type = machine_id.split("-")[0].lower() if machine_id else ""
    expected = EXPECTED_CYCLE_TIMES.get(machine_type, ct)

    if ct <= 0 or expected <= 0:
        return 1.0

    perf = expected / ct
    return min(1.0, perf)


def _alert_level(oee: float) -> str:
    if oee >= 0.85:
        return "ok"
    if oee >= 0.60:
        return "warning"
    return "critical"


def _enrich(data: dict) -> None:
    """
    Mutates data in-place, adding OEE fields under the '_aio' key.
    This mirrors the Rust transform but adds a 'lang' tag so we can
    tell Rust vs Python messages apart in downstream analytics.
    """
    status = data.get("status", "")
    avail = _availability(status)
    quality = _quality_score(data)
    perf = _performance(data)
    oee = avail * quality * perf

    data["_aio"] = {
        "oee": round(oee, 4),
        "availability": round(avail, 4),
        "quality": round(quality, 4),
        "performance": round(perf, 4),
        "alert_level": _alert_level(oee),
        "processor": "wasm-py",
        "sdk_version": "componentize-py-0.14",
    }


# ---------------------------------------------------------------------------
# WASM operator implementation
# ---------------------------------------------------------------------------

class Map(exports.Map):
    """
    AIO DataflowGraph Map operator.

    init()    - called once when the module loads; return True to proceed.
    process() - called for every message; return the (possibly modified) message.
    """

    def init(self, configuration) -> bool:
        imports.logger.log(
            imports.logger.Level.INFO,
            "oee-enrich-py",
            "Python OEE enrichment module initialised",
        )
        return True

    def process(self, message: types.DataModel) -> types.DataModel:
        # Only handle MQTT messages (DataModel_Message).
        # Pass through any other variants unchanged.
        if not isinstance(message, types.DataModel_Message):
            return message

        payload_variant = message.value.payload

        # Materialise the payload bytes (may be a host buffer or module-owned bytes).
        if isinstance(payload_variant, types.BufferOrBytes_Buffer):
            raw = payload_variant.value.read()
        elif isinstance(payload_variant, types.BufferOrBytes_Bytes):
            raw = payload_variant.value
        else:
            imports.logger.log(
                imports.logger.Level.ERROR,
                "oee-enrich-py",
                "Unexpected payload variant — passing through unchanged",
            )
            return message

        # Parse → enrich → re-serialise.
        try:
            data = json.loads(raw.decode("utf-8"))
            _enrich(data)
            enriched = json.dumps(data).encode("utf-8")
            message.value.payload = types.BufferOrBytes_Bytes(value=enriched)
        except Exception as exc:  # noqa: BLE001
            imports.logger.log(
                imports.logger.Level.ERROR,
                "oee-enrich-py",
                f"Failed to enrich message: {exc}",
            )

        return message
