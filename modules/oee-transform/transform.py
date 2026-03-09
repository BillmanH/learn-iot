"""
OEE Transform logic - ported from modules/wasm/src/transform.rs

Enriches raw factory telemetry messages with:
  - OEE Availability score (1.0 / 0.5 / 0.0)
  - OEE Quality score
  - Normalised quality label
  - Alert level classification (normal / warning / critical)
  - Test pass/fail boolean
  - Processing metadata
"""

import json
from datetime import datetime, timezone

MODULE_VERSION = "0.1.0"


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def process(message_str: str) -> str:
    """Parse, enrich and return a JSON string. Never raises — returns an error
    payload on parse failure so the pipeline keeps moving."""
    try:
        msg = json.loads(message_str)
    except Exception as e:
        return json.dumps({
            "transform_error": True,
            "reason": f"parse error: {e}",
            "processing_module_version": MODULE_VERSION,
        })

    try:
        enriched = enrich(msg)
        return json.dumps(enriched)
    except Exception as e:
        return json.dumps({
            "transform_error": True,
            "reason": f"enrich error: {e}",
            "processing_module_version": MODULE_VERSION,
        })


# ---------------------------------------------------------------------------
# Enrichment
# ---------------------------------------------------------------------------

def enrich(msg: dict) -> dict:
    status = msg.get("status", "unknown")

    oee_availability = _availability_score(status)
    oee_quality, quality_normalised = _quality_components(msg)

    test_result = msg.get("test_result")
    test_passed = (test_result.lower() == "pass") if isinstance(test_result, str) else None

    alert_level, alert_reason = _classify_alert(
        status,
        quality_normalised,
        oee_availability,
        test_passed,
        msg.get("issues_found"),
    )

    out = dict(msg)  # pass all original fields through unchanged

    if oee_availability is not None:
        out["oee_availability"] = oee_availability
    if oee_quality is not None:
        out["oee_quality"] = oee_quality

    out["quality_normalised"] = quality_normalised
    out["alert_level"] = alert_level
    if alert_reason is not None:
        out["alert_reason"] = alert_reason
    if test_passed is not None:
        out["test_passed"] = test_passed

    out["processing_module_version"] = MODULE_VERSION

    return out


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _availability_score(status: str):
    """Map machine status to OEE availability (1.0 / 0.5 / 0.0 / None)."""
    return {
        # Active production
        "running":     1.0,
        "testing":     1.0,
        # Planned / transitional downtime
        "idle":        0.5,
        "warming_up":  0.5,
        "cooling":     0.5,
        "drying":      0.5,
        "calibrating": 0.5,
        # Unplanned stop
        "faulted":     0.0,
        "error":       0.0,
        "maintenance": 0.0,
    }.get(status)  # returns None for business events / unknown


def _quality_components(msg: dict):
    """Return (oee_quality, quality_normalised) from message fields."""
    quality = msg.get("quality")

    if isinstance(quality, str):
        return {
            "good":   (1.0, "good"),
            "scrap":  (0.0, "scrap"),
            "rework": (0.5, "rework"),
        }.get(quality, (None, quality))

    if quality is None and "quality" in msg:
        # explicit null → in-progress
        return (None, "in_progress")

    # Fall back to numeric good / scrap / rework fields
    good   = _to_float(msg.get("good"),   0.0)
    scrap  = _to_float(msg.get("scrap"),  0.0)
    rework = _to_float(msg.get("rework"), 0.0)
    total  = good + scrap + rework

    if total == 0.0:
        return (None, "in_progress")

    ratio = good / total
    if scrap > 0:
        label = "scrap"
    elif rework > 0:
        label = "rework"
    else:
        label = "good"

    return (ratio, label)


def _classify_alert(status, quality_normalised, availability, test_passed, issues_found):
    """Return (alert_level, alert_reason | None)."""
    if status in ("faulted", "error"):
        return ("critical", f"machine status: {status}")

    if test_passed is False:
        issues = int(issues_found) if isinstance(issues_found, (int, float)) else 0
        return ("critical", f"test FAILED with {issues} issue(s)")

    if quality_normalised == "scrap":
        return ("warning", "scrap part produced")

    if quality_normalised == "rework":
        return ("warning", "rework required")

    if availability == 0.0:
        return ("warning", f"machine in maintenance: {status}")

    return ("normal", None)


def _to_float(value, default: float) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default
