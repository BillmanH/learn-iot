use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};
use crate::message_parser::WeldingMessage;

/// Quality control alert structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QualityControlAlert {
    pub alert_type: String,
    pub source_machine: String,
    pub timestamp: String,
    pub trigger_conditions: TriggerConditions,
    pub assembly_details: AssemblyDetails,
    pub severity: String,
    pub recommended_action: String,
    pub line_info: Option<LineInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TriggerConditions {
    pub quality: String,
    pub cycle_time: f64,
    pub threshold: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssemblyDetails {
    #[serde(rename = "type")]
    pub assembly_type: String,
    pub id: String,
    pub station_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LineInfo {
    pub line: String,
    pub station: String,
}

/// Quality control filter constants
pub const CYCLE_TIME_THRESHOLD: f64 = 7.0;
pub const SCRAP_QUALITY: &str = "scrap";

/// Main filter logic - determines if a quality control alert should be triggered
/// 
/// Condition: quality == "scrap" AND cycle_time < 7.0
pub fn should_trigger_alert(message: &WeldingMessage) -> bool {
    message.quality.to_lowercase() == SCRAP_QUALITY && 
    message.last_cycle_time < CYCLE_TIME_THRESHOLD
}

/// Generate a quality control alert from a welding message
pub fn generate_quality_alert(message: &WeldingMessage) -> QualityControlAlert {
    let now = Utc::now();
    let severity = determine_severity(message);
    let recommended_action = determine_recommended_action(message);
    let line_info = message.get_line_info()
        .map(|(line, station)| LineInfo { line, station });

    QualityControlAlert {
        alert_type: "quality_control".to_string(),
        source_machine: message.machine_id.clone(),
        timestamp: now.to_rfc3339(),
        trigger_conditions: TriggerConditions {
            quality: message.quality.clone(),
            cycle_time: message.last_cycle_time,
            threshold: CYCLE_TIME_THRESHOLD,
        },
        assembly_details: AssemblyDetails {
            assembly_type: message.assembly_type.clone(),
            id: message.assembly_id.clone(),
            station_id: message.station_id.clone(),
        },
        severity,
        recommended_action,
        line_info,
    }
}

/// Determine alert severity based on how far below threshold the cycle time is
fn determine_severity(message: &WeldingMessage) -> String {
    let deviation = CYCLE_TIME_THRESHOLD - message.last_cycle_time;
    
    match deviation {
        d if d >= 2.0 => "high".to_string(),    // cycle_time <= 5.0
        d if d >= 1.0 => "medium".to_string(),  // cycle_time <= 6.0
        _ => "low".to_string(),                 // cycle_time < 7.0 but > 6.0
    }
}

/// Determine recommended action based on cycle time and other factors
fn determine_recommended_action(message: &WeldingMessage) -> String {
    let deviation = CYCLE_TIME_THRESHOLD - message.last_cycle_time;
    
    match deviation {
        d if d >= 2.0 => "immediate_inspection_required".to_string(),
        d if d >= 1.0 => "investigate_welding_parameters".to_string(),
        _ => "monitor_next_cycle".to_string(),
    }
}

/// Additional utility functions for quality analysis
pub struct QualityAnalyzer;

impl QualityAnalyzer {
    /// Check if the welding parameters indicate potential equipment issues
    pub fn check_equipment_health(message: &WeldingMessage) -> bool {
        // Very short cycle times with scrap quality might indicate equipment malfunction
        message.last_cycle_time < 5.0 && message.quality == SCRAP_QUALITY
    }

    /// Estimate the impact level of the quality issue
    pub fn estimate_impact(message: &WeldingMessage) -> String {
        match message.assembly_type.as_str() {
            "FrameAssembly" | "EngineMount" => "critical".to_string(),
            "WingJoint" | "DockingPort" => "high".to_string(),
            "HullSeam" => "medium".to_string(),
            _ => "low".to_string(),
        }
    }

    /// Generate additional context for the alert
    pub fn get_context_info(message: &WeldingMessage) -> String {
        let impact = Self::estimate_impact(message);
        let equipment_issue = Self::check_equipment_health(message);
        
        if equipment_issue {
            format!("Potential equipment malfunction detected. Assembly impact: {}. Consider immediate maintenance.", impact)
        } else {
            format!("Quality deviation detected. Assembly impact: {}. Review welding parameters.", impact)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_message(quality: &str, cycle_time: f64) -> WeldingMessage {
        WeldingMessage {
            machine_id: "LINE-1-STATION-C-01".to_string(),
            timestamp: "2025-12-02T15:30:00Z".to_string(),
            status: "running".to_string(),
            last_cycle_time: cycle_time,
            quality: quality.to_string(),
            assembly_type: "FrameAssembly".to_string(),
            assembly_id: "FA-001-2025-001".to_string(),
            station_id: "LINE-1-STATION-C".to_string(),
        }
    }

    #[test]
    fn test_should_trigger_alert_scrap_fast_cycle() {
        let message = create_test_message("scrap", 6.5);
        assert!(should_trigger_alert(&message));
    }

    #[test]
    fn test_should_not_trigger_alert_scrap_slow_cycle() {
        let message = create_test_message("scrap", 7.5);
        assert!(!should_trigger_alert(&message));
    }

    #[test]
    fn test_should_not_trigger_alert_good_fast_cycle() {
        let message = create_test_message("good", 6.0);
        assert!(!should_trigger_alert(&message));
    }

    #[test]
    fn test_should_not_trigger_alert_good_slow_cycle() {
        let message = create_test_message("good", 8.0);
        assert!(!should_trigger_alert(&message));
    }

    #[test]
    fn test_determine_severity_high() {
        let message = create_test_message("scrap", 4.5); // deviation = 2.5
        let severity = determine_severity(&message);
        assert_eq!(severity, "high");
    }

    #[test]
    fn test_determine_severity_medium() {
        let message = create_test_message("scrap", 5.5); // deviation = 1.5
        let severity = determine_severity(&message);
        assert_eq!(severity, "medium");
    }

    #[test]
    fn test_determine_severity_low() {
        let message = create_test_message("scrap", 6.8); // deviation = 0.2
        let severity = determine_severity(&message);
        assert_eq!(severity, "low");
    }

    #[test]
    fn test_generate_quality_alert() {
        let message = create_test_message("scrap", 6.0);
        let alert = generate_quality_alert(&message);

        assert_eq!(alert.alert_type, "quality_control");
        assert_eq!(alert.source_machine, "LINE-1-STATION-C-01");
        assert_eq!(alert.trigger_conditions.quality, "scrap");
        assert_eq!(alert.trigger_conditions.cycle_time, 6.0);
        assert_eq!(alert.trigger_conditions.threshold, 7.0);
        assert_eq!(alert.assembly_details.assembly_type, "FrameAssembly");
        assert!(alert.line_info.is_some());
    }

    #[test]
    fn test_quality_analyzer_equipment_health() {
        let message = create_test_message("scrap", 4.0);
        assert!(QualityAnalyzer::check_equipment_health(&message));

        let message2 = create_test_message("scrap", 6.0);
        assert!(!QualityAnalyzer::check_equipment_health(&message2));

        let message3 = create_test_message("good", 4.0);
        assert!(!QualityAnalyzer::check_equipment_health(&message3));
    }

    #[test]
    fn test_quality_analyzer_impact_estimation() {
        let mut message = create_test_message("scrap", 6.0);
        
        message.assembly_type = "FrameAssembly".to_string();
        assert_eq!(QualityAnalyzer::estimate_impact(&message), "critical");

        message.assembly_type = "WingJoint".to_string();
        assert_eq!(QualityAnalyzer::estimate_impact(&message), "high");

        message.assembly_type = "HullSeam".to_string();
        assert_eq!(QualityAnalyzer::estimate_impact(&message), "medium");

        message.assembly_type = "OtherPart".to_string();
        assert_eq!(QualityAnalyzer::estimate_impact(&message), "low");
    }

    #[test]
    fn test_quality_analyzer_context_info() {
        let message = create_test_message("scrap", 4.0); // Should trigger equipment issue
        let context = QualityAnalyzer::get_context_info(&message);
        assert!(context.contains("Potential equipment malfunction"));
        assert!(context.contains("critical")); // FrameAssembly is critical

        let message2 = create_test_message("scrap", 6.0); // Normal quality issue
        let context2 = QualityAnalyzer::get_context_info(&message2);
        assert!(context2.contains("Quality deviation"));
        assert!(context2.contains("Review welding parameters"));
    }
}