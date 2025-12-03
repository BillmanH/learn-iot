use wasm_bindgen::prelude::*;
use serde_json;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};

mod message_parser;
mod filter_logic;

use message_parser::WeldingMessage;
use filter_logic::QualityControlAlert;

// WASM bindgen exports for JavaScript environments
#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = console)]
    fn log(s: &str);
}

// Macro for console logging from WASM
macro_rules! console_log {
    ($($t:tt)*) => (log(&format_args!($($t)*).to_string()))
}

// C-compatible interface for non-JavaScript WASM runtimes
#[no_mangle]
pub extern "C" fn process_message(input_ptr: *const c_char) -> *mut c_char {
    if input_ptr.is_null() {
        return std::ptr::null_mut();
    }

    let c_str = unsafe { CStr::from_ptr(input_ptr) };
    let input = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };

    match process_welding_message(input) {
        Some(result) => {
            match CString::new(result) {
                Ok(c_string) => c_string.into_raw(),
                Err(_) => std::ptr::null_mut(),
            }
        },
        None => std::ptr::null_mut(),
    }
}

// Free memory allocated by process_message
#[no_mangle]
pub extern "C" fn free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { 
            let _ = CString::from_raw(ptr); 
        }
    }
}

// JavaScript-compatible interface
#[wasm_bindgen]
pub fn process_welding_message_js(input: &str) -> Option<String> {
    process_welding_message(input)
}

// Core processing logic
pub fn process_welding_message(input: &str) -> Option<String> {
    console_log!("Processing welding message: {}", input);
    
    // Parse the incoming welding message
    let welding_message = match message_parser::parse_welding_message(input) {
        Ok(msg) => msg,
        Err(e) => {
            console_log!("Failed to parse welding message: {}", e);
            return None;
        }
    };

    console_log!("Parsed message - Machine: {}, Quality: {}, Cycle Time: {}", 
                 welding_message.machine_id, welding_message.quality, welding_message.last_cycle_time);

    // Apply quality filter logic
    if filter_logic::should_trigger_alert(&welding_message) {
        console_log!("Quality alert triggered for machine: {}", welding_message.machine_id);
        
        // Generate quality control alert
        let alert = filter_logic::generate_quality_alert(&welding_message);
        
        match serde_json::to_string(&alert) {
            Ok(json) => {
                console_log!("Generated quality alert: {}", json);
                Some(json)
            },
            Err(e) => {
                console_log!("Failed to serialize quality alert: {}", e);
                None
            }
        }
    } else {
        console_log!("No quality alert needed for machine: {}", welding_message.machine_id);
        None
    }
}

// Initialize the WASM module
#[wasm_bindgen(start)]
pub fn main() {
    console_log!("WASM Quality Filter Module initialized");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_process_valid_welding_message_triggers_alert() {
        let input = r#"{
            "machine_id": "LINE-1-STATION-C-01",
            "timestamp": "2025-12-02T15:30:00Z",
            "status": "running",
            "last_cycle_time": 6.5,
            "quality": "scrap",
            "assembly_type": "FrameAssembly",
            "assembly_id": "FA-001-2025-001",
            "station_id": "LINE-1-STATION-C"
        }"#;

        let result = process_welding_message(input);
        assert!(result.is_some(), "Should generate quality alert for scrap with cycle_time < 7");
        
        let alert_json = result.unwrap();
        assert!(alert_json.contains("quality_control"));
        assert!(alert_json.contains("LINE-1-STATION-C-01"));
    }

    #[test]
    fn test_process_valid_welding_message_no_alert() {
        let input = r#"{
            "machine_id": "LINE-1-STATION-C-02",
            "timestamp": "2025-12-02T15:30:00Z",
            "status": "running",
            "last_cycle_time": 8.0,
            "quality": "scrap",
            "assembly_type": "FrameAssembly",
            "assembly_id": "FA-001-2025-002",
            "station_id": "LINE-1-STATION-C"
        }"#;

        let result = process_welding_message(input);
        assert!(result.is_none(), "Should not generate alert for scrap with cycle_time >= 7");
    }

    #[test]
    fn test_process_good_quality_no_alert() {
        let input = r#"{
            "machine_id": "LINE-1-STATION-C-03",
            "timestamp": "2025-12-02T15:30:00Z",
            "status": "running",
            "last_cycle_time": 6.0,
            "quality": "good",
            "assembly_type": "FrameAssembly",
            "assembly_id": "FA-001-2025-003",
            "station_id": "LINE-1-STATION-C"
        }"#;

        let result = process_welding_message(input);
        assert!(result.is_none(), "Should not generate alert for good quality");
    }

    #[test]
    fn test_process_invalid_json() {
        let input = r#"{"invalid": json"#;
        let result = process_welding_message(input);
        assert!(result.is_none(), "Should handle invalid JSON gracefully");
    }
}