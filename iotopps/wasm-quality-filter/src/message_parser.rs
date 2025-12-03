use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct WeldingMessage {
    pub machine_id: String,
    pub timestamp: String,
    pub status: String,
    pub last_cycle_time: f64,
    pub quality: String,
    pub assembly_type: String,
    pub assembly_id: String,
    pub station_id: String,
}

impl WeldingMessage {
    /// Parse timestamp to DateTime if possible
    pub fn get_timestamp(&self) -> Result<DateTime<Utc>, chrono::ParseError> {
        DateTime::parse_from_rfc3339(&self.timestamp)
            .map(|dt| dt.with_timezone(&Utc))
    }

    /// Check if the message represents a valid welding operation
    pub fn is_valid_operation(&self) -> bool {
        !self.machine_id.is_empty() 
            && !self.quality.is_empty()
            && self.last_cycle_time > 0.0
            && matches!(self.quality.as_str(), "good" | "scrap" | "rework")
            && matches!(self.status.as_str(), "running" | "idle" | "cooling" | "faulted")
    }

    /// Extract line and station information from machine_id
    pub fn get_line_info(&self) -> Option<(String, String)> {
        // Expected format: "LINE-{line}-STATION-{station}-{machine_num}"
        let parts: Vec<&str> = self.machine_id.split('-').collect();
        if parts.len() >= 4 && parts[0] == "LINE" && parts[2] == "STATION" {
            Some((format!("LINE-{}", parts[1]), format!("STATION-{}", parts[3])))
        } else {
            None
        }
    }
}

/// Parse a JSON string into a WeldingMessage
pub fn parse_welding_message(json_str: &str) -> Result<WeldingMessage, Box<dyn std::error::Error>> {
    let message: WeldingMessage = serde_json::from_str(json_str)?;
    
    if !message.is_valid_operation() {
        return Err("Invalid welding operation data".into());
    }
    
    Ok(message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_valid_welding_message() {
        let json = r#"{
            "machine_id": "LINE-1-STATION-C-01",
            "timestamp": "2025-12-02T15:30:00Z",
            "status": "running",
            "last_cycle_time": 6.5,
            "quality": "scrap",
            "assembly_type": "FrameAssembly",
            "assembly_id": "FA-001-2025-001",
            "station_id": "LINE-1-STATION-C"
        }"#;

        let result = parse_welding_message(json);
        assert!(result.is_ok());
        
        let message = result.unwrap();
        assert_eq!(message.machine_id, "LINE-1-STATION-C-01");
        assert_eq!(message.quality, "scrap");
        assert_eq!(message.last_cycle_time, 6.5);
        assert!(message.is_valid_operation());
    }

    #[test]
    fn test_parse_invalid_quality() {
        let json = r#"{
            "machine_id": "LINE-1-STATION-C-01",
            "timestamp": "2025-12-02T15:30:00Z",
            "status": "running",
            "last_cycle_time": 6.5,
            "quality": "invalid_quality",
            "assembly_type": "FrameAssembly",
            "assembly_id": "FA-001-2025-001",
            "station_id": "LINE-1-STATION-C"
        }"#;

        let result = parse_welding_message(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_invalid_json() {
        let json = r#"{"invalid": json"#;
        let result = parse_welding_message(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_get_line_info() {
        let message = WeldingMessage {
            machine_id: "LINE-1-STATION-C-01".to_string(),
            timestamp: "2025-12-02T15:30:00Z".to_string(),
            status: "running".to_string(),
            last_cycle_time: 6.5,
            quality: "scrap".to_string(),
            assembly_type: "FrameAssembly".to_string(),
            assembly_id: "FA-001-2025-001".to_string(),
            station_id: "LINE-1-STATION-C".to_string(),
        };

        let line_info = message.get_line_info();
        assert!(line_info.is_some());
        
        let (line, station) = line_info.unwrap();
        assert_eq!(line, "LINE-1");
        assert_eq!(station, "STATION-C");
    }

    #[test]
    fn test_get_timestamp() {
        let message = WeldingMessage {
            machine_id: "LINE-1-STATION-C-01".to_string(),
            timestamp: "2025-12-02T15:30:00Z".to_string(),
            status: "running".to_string(),
            last_cycle_time: 6.5,
            quality: "scrap".to_string(),
            assembly_type: "FrameAssembly".to_string(),
            assembly_id: "FA-001-2025-001".to_string(),
            station_id: "LINE-1-STATION-C".to_string(),
        };

        let timestamp = message.get_timestamp();
        assert!(timestamp.is_ok());
    }

    #[test]
    fn test_is_valid_operation() {
        let mut message = WeldingMessage {
            machine_id: "LINE-1-STATION-C-01".to_string(),
            timestamp: "2025-12-02T15:30:00Z".to_string(),
            status: "running".to_string(),
            last_cycle_time: 6.5,
            quality: "scrap".to_string(),
            assembly_type: "FrameAssembly".to_string(),
            assembly_id: "FA-001-2025-001".to_string(),
            station_id: "LINE-1-STATION-C".to_string(),
        };

        assert!(message.is_valid_operation());

        // Test invalid cycle time
        message.last_cycle_time = 0.0;
        assert!(!message.is_valid_operation());

        // Test empty machine_id
        message.last_cycle_time = 6.5;
        message.machine_id = "".to_string();
        assert!(!message.is_valid_operation());
    }
}