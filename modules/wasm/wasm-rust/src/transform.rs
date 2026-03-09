/// Core transformation logic for factory telemetry messages.
///
/// Takes a raw JSON message from the edgemqttsim and enriches it with:
///   - OEE component scores (Availability, Quality, Performance)
///   - Alert level classification
///   - Normalised quality field
///   - Processing metadata (version, processed_at)

use serde::{Deserialize, Serialize};
use serde_json::Value;

// ──────────────────────────────────────────────────────────────────────────────
// Input message schema (mirrors edgemqttsim output)
// ──────────────────────────────────────────────────────────────────────────────

/// Loosely typed input so we accept all machine variants (cnc, printer, welder…)
/// Optional fields handle the fact that different machines emit different keys.
#[derive(Deserialize, Debug)]
pub struct FactoryMessage {
    // Common fields (all machines)
    pub timestamp: Option<String>,
    pub machine_id: Option<String>,
    pub station_id: Option<String>,
    pub status: Option<String>,
    pub message_type: Option<String>,

    // Quality / production (cnc, printer, welding, painting)
    pub quality: Option<Value>,   // String "good"/"scrap"/"rework" or null
    pub good: Option<Value>,      // Numeric 0/1 or null
    pub scrap: Option<Value>,     // Numeric 0/1 or null
    pub rework: Option<Value>,    // Numeric 0/1 or null

    // Timing
    pub cycle_time: Option<f64>,

    // Part tracking
    pub part_type: Option<String>,
    pub part_id: Option<String>,
    pub progress: Option<f64>,    // 3D printer progress 0.0-1.0

    // Welding / painting specifics
    pub assembly_type: Option<String>,
    pub color: Option<String>,

    // Testing rig specifics
    pub test_result: Option<String>,
    pub issues_found: Option<Value>,

    // Business events (orders / dispatch)
    pub order_id: Option<String>,
    pub product_type: Option<String>,
    pub quantity: Option<Value>,
    pub destination: Option<String>,
    pub carrier: Option<String>,

    // Catch-all so we don't lose unknown fields
    #[serde(flatten)]
    pub extra: std::collections::HashMap<String, Value>,
}

// ──────────────────────────────────────────────────────────────────────────────
// Output schema additions
// ──────────────────────────────────────────────────────────────────────────────

#[derive(Serialize, Debug)]
pub struct TransformedMessage {
    // ── Original fields (pass-through) ──────────────────────────────────────
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub station_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quality: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub good: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scrap: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rework: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cycle_time: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub part_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub part_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub assembly_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub test_result: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub issues_found: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub product_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quantity: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destination: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub carrier: Option<String>,

    // ── Enriched fields ──────────────────────────────────────────────────────

    /// Machine availability component of OEE.
    /// 1.0  = actively producing
    /// 0.5  = planned downtime (idle, warming, cooling, drying)
    /// 0.0  = unplanned stop (faulted, error)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oee_availability: Option<f64>,

    /// Quality component of OEE (good units / total units).
    /// Null for machines where a cycle has not yet completed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oee_quality: Option<f64>,

    /// Human-readable quality category: "good" | "scrap" | "rework" | "in_progress"
    pub quality_normalised: String,

    /// Classification of the current message.
    /// "normal" | "warning" | "critical"
    pub alert_level: AlertLevel,

    /// Short human-readable reason for a non-normal alert level.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub alert_reason: Option<String>,

    /// Test pass/fail recast as a boolean for easier downstream filtering.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub test_passed: Option<bool>,

    /// Processing metadata
    pub processing_module_version: &'static str,

    // Preserve any extra fields the simulator may add in future
    #[serde(flatten)]
    pub extra: std::collections::HashMap<String, Value>,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum AlertLevel {
    Normal,
    Warning,
    Critical,
}

// ──────────────────────────────────────────────────────────────────────────────
// Transform logic
// ──────────────────────────────────────────────────────────────────────────────

pub fn process(input: &str) -> String {
    match serde_json::from_str::<FactoryMessage>(input) {
        Ok(msg) => {
            let transformed = enrich(msg);
            serde_json::to_string(&transformed)
                .unwrap_or_else(|e| error_payload(&format!("serialise error: {e}")))
        }
        Err(e) => {
            // Emit an error wrapper rather than swallowing the original message
            error_payload(&format!("parse error: {e} | raw: {input}"))
        }
    }
}

fn enrich(msg: FactoryMessage) -> TransformedMessage {
    let status_str = msg.status.as_deref().unwrap_or("unknown");

    // ── OEE Availability ────────────────────────────────────────────────────
    let oee_availability = availability_score(status_str);

    // ── OEE Quality ─────────────────────────────────────────────────────────
    let (oee_quality, quality_normalised) = quality_components(&msg);

    // ── Test result ─────────────────────────────────────────────────────────
    let test_passed = msg
        .test_result
        .as_deref()
        .map(|r| r.eq_ignore_ascii_case("pass"));

    // ── Alert level ─────────────────────────────────────────────────────────
    let (alert_level, alert_reason) = classify_alert(
        status_str,
        &quality_normalised,
        oee_availability,
        test_passed,
        msg.issues_found.as_ref(),
    );

    TransformedMessage {
        timestamp: msg.timestamp,
        machine_id: msg.machine_id,
        station_id: msg.station_id,
        status: msg.status,
        message_type: msg.message_type,
        quality: msg.quality,
        good: msg.good,
        scrap: msg.scrap,
        rework: msg.rework,
        cycle_time: msg.cycle_time,
        part_type: msg.part_type,
        part_id: msg.part_id,
        progress: msg.progress,
        assembly_type: msg.assembly_type,
        color: msg.color,
        test_result: msg.test_result,
        issues_found: msg.issues_found,
        order_id: msg.order_id,
        product_type: msg.product_type,
        quantity: msg.quantity,
        destination: msg.destination,
        carrier: msg.carrier,
        oee_availability,
        oee_quality,
        quality_normalised,
        alert_level,
        alert_reason,
        test_passed,
        processing_module_version: env!("CARGO_PKG_VERSION"),
        extra: msg.extra,
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Map machine status to an OEE availability score.
fn availability_score(status: &str) -> Option<f64> {
    match status {
        // Active production
        "running" | "testing" => Some(1.0),
        // Planned / transitional downtime
        "idle" | "warming_up" | "cooling" | "drying" | "calibrating" => Some(0.5),
        // Unplanned / fault stop
        "faulted" | "error" | "maintenance" => Some(0.0),
        // Business events don't have a machine availability
        "order_placed" | "dispatched" => None,
        _ => None,
    }
}

/// Derive both the OEE quality ratio and the normalised quality string.
fn quality_components(msg: &FactoryMessage) -> (Option<f64>, String) {
    // Prefer the string "quality" field emitted by newer message versions
    if let Some(q) = &msg.quality {
        if let Some(s) = q.as_str() {
            return match s {
                "good" => (Some(1.0), "good".to_string()),
                "scrap" => (Some(0.0), "scrap".to_string()),
                "rework" => (Some(0.5), "rework".to_string()),
                _ => (None, s.to_string()),
            };
        }
        if q.is_null() {
            return (None, "in_progress".to_string());
        }
    }

    // Fall back to numeric good/scrap/rework fields
    let good = value_as_f64(msg.good.as_ref()).unwrap_or(0.0);
    let scrap = value_as_f64(msg.scrap.as_ref()).unwrap_or(0.0);
    let rework = value_as_f64(msg.rework.as_ref()).unwrap_or(0.0);
    let total = good + scrap + rework;

    if total == 0.0 {
        return (None, "in_progress".to_string());
    }

    let quality_ratio = good / total;
    let label = if scrap > 0.0 {
        "scrap"
    } else if rework > 0.0 {
        "rework"
    } else {
        "good"
    };

    (Some(quality_ratio), label.to_string())
}

/// Determine alert level and reason.
fn classify_alert(
    status: &str,
    quality_normalised: &str,
    availability: Option<f64>,
    test_passed: Option<bool>,
    issues_found: Option<&Value>,
) -> (AlertLevel, Option<String>) {
    // Faulted machine → critical
    if status == "faulted" || status == "error" {
        return (
            AlertLevel::Critical,
            Some(format!("machine status: {status}")),
        );
    }

    // Failed test → critical
    if test_passed == Some(false) {
        let issues = issues_found
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        return (
            AlertLevel::Critical,
            Some(format!("test FAILED with {issues} issue(s)")),
        );
    }

    // Scrap produced → warning
    if quality_normalised == "scrap" {
        return (AlertLevel::Warning, Some("scrap part produced".to_string()));
    }

    // Rework required → warning
    if quality_normalised == "rework" {
        return (
            AlertLevel::Warning,
            Some("rework required".to_string()),
        );
    }

    // Unplanned downtime already caught by "faulted"; planned downtime is normal
    if availability == Some(0.0) {
        return (
            AlertLevel::Warning,
            Some(format!("machine in maintenance: {status}")),
        );
    }

    (AlertLevel::Normal, None)
}

fn value_as_f64(v: Option<&Value>) -> Option<f64> {
    v?.as_f64()
}

fn error_payload(reason: &str) -> String {
    format!(
        r#"{{"transform_error":true,"reason":{reason_json},"processing_module_version":{ver_json}}}"#,
        reason_json = serde_json::to_string(reason).unwrap_or_default(),
        ver_json = serde_json::to_string(env!("CARGO_PKG_VERSION")).unwrap_or_default(),
    )
}

// ──────────────────────────────────────────────────────────────────────────────
// Unit tests
// ──────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn process_json(json: &str) -> Value {
        let out = process(json);
        serde_json::from_str(&out).expect("output should be valid JSON")
    }

    #[test]
    fn cnc_good_part_is_normal() {
        let v = process_json(r#"{
            "timestamp": "2026-03-05T10:00:00Z",
            "machine_id": "CNC-01",
            "station_id": "LINE-1-STATION-A",
            "status": "running",
            "message_type": "cnc_machine",
            "good": 1,
            "scrap": 0,
            "cycle_time": 12.5,
            "part_type": "HullPanel",
            "part_id": "HullPanel-001"
        }"#);
        assert_eq!(v["alert_level"], "normal");
        assert_eq!(v["oee_availability"], 1.0);
        assert_eq!(v["oee_quality"], 1.0);
        assert_eq!(v["quality_normalised"], "good");
        assert_eq!(v["processing_module_version"], "0.1.0");
    }

    #[test]
    fn cnc_scrap_is_warning() {
        let v = process_json(r#"{
            "machine_id": "CNC-02",
            "status": "running",
            "good": 0,
            "scrap": 1,
            "cycle_time": 14.0
        }"#);
        assert_eq!(v["alert_level"], "warning");
        assert_eq!(v["oee_quality"], 0.0);
        assert_eq!(v["quality_normalised"], "scrap");
    }

    #[test]
    fn faulted_machine_is_critical() {
        let v = process_json(r#"{
            "machine_id": "WELD-01",
            "status": "faulted"
        }"#);
        assert_eq!(v["alert_level"], "critical");
        assert_eq!(v["oee_availability"], 0.0);
    }

    #[test]
    fn failed_test_is_critical() {
        let v = process_json(r#"{
            "machine_id": "QA-01",
            "status": "testing",
            "test_result": "fail",
            "issues_found": 3
        }"#);
        assert_eq!(v["alert_level"], "critical");
        assert_eq!(v["test_passed"], false);
    }

    #[test]
    fn passing_test_is_normal() {
        let v = process_json(r#"{
            "machine_id": "QA-01",
            "status": "testing",
            "test_result": "pass",
            "issues_found": 0
        }"#);
        assert_eq!(v["alert_level"], "normal");
        assert_eq!(v["test_passed"], true);
    }

    #[test]
    fn printer_in_progress_quality_is_in_progress() {
        let v = process_json(r#"{
            "machine_id": "3DP-01",
            "status": "running",
            "quality": null,
            "progress": 0.45
        }"#);
        assert_eq!(v["quality_normalised"], "in_progress");
    }

    #[test]
    fn idle_machine_has_half_availability() {
        let v = process_json(r#"{
            "machine_id": "CNC-03",
            "status": "idle"
        }"#);
        assert_eq!(v["oee_availability"], 0.5);
        assert_eq!(v["alert_level"], "normal");
    }

    #[test]
    fn welding_rework_is_warning() {
        let v = process_json(r#"{
            "machine_id": "WELD-02",
            "status": "running",
            "quality": "rework"
        }"#);
        assert_eq!(v["alert_level"], "warning");
        assert_eq!(v["oee_quality"], 0.5);
        assert_eq!(v["quality_normalised"], "rework");
    }

    #[test]
    fn business_event_passes_through() {
        let v = process_json(r#"{
            "message_type": "customer_order",
            "order_id": "ORD-001",
            "product_type": "FullSpaceship",
            "quantity": 2
        }"#);
        assert_eq!(v["order_id"], "ORD-001");
        // Business events have no availability score
        assert!(v["oee_availability"].is_null());
    }

    #[test]
    fn malformed_input_returns_error_payload() {
        let out = process("not json at all");
        let v: Value = serde_json::from_str(&out).expect("error payload is valid JSON");
        assert_eq!(v["transform_error"], true);
    }
}
