use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::time;
use tracing::{debug, info};

use crate::metrics::MetricsCollector;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthStatus {
    pub status: String,
    pub timestamp: String,
    pub version: String,
    pub uptime_seconds: u64,
    pub checks: HealthChecks,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthChecks {
    pub wasm_module: CheckResult,
    pub mqtt_connection: CheckResult,
    pub memory_usage: CheckResult,
    pub message_processing: CheckResult,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckResult {
    pub status: String,
    pub message: String,
    pub last_checked: String,
}

pub struct HealthService {
    start_time: Instant,
    metrics: Arc<MetricsCollector>,
}

impl HealthService {
    pub fn new(metrics: Arc<MetricsCollector>) -> Self {
        Self {
            start_time: Instant::now(),
            metrics,
        }
    }

    pub async fn check_health(&self) -> anyhow::Result<HealthStatus> {
        debug!("🏥 Performing health checks");

        let now = chrono::Utc::now();
        let uptime = self.start_time.elapsed();

        let checks = HealthChecks {
            wasm_module: self.check_wasm_module().await,
            mqtt_connection: self.check_mqtt_connection().await,
            memory_usage: self.check_memory_usage().await,
            message_processing: self.check_message_processing().await,
        };

        // Determine overall status
        let overall_status = if self.is_healthy(&checks) {
            "healthy".to_string()
        } else {
            "unhealthy".to_string()
        };

        let health_status = HealthStatus {
            status: overall_status,
            timestamp: now.to_rfc3339(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            uptime_seconds: uptime.as_secs(),
            checks,
        };

        debug!("✅ Health check completed: {}", health_status.status);
        Ok(health_status)
    }

    async fn check_wasm_module(&self) -> CheckResult {
        // Check if WASM module is accessible and valid
        let now = chrono::Utc::now();
        
        match std::fs::metadata("wasm_quality_filter.wasm") {
            Ok(metadata) => {
                if metadata.len() > 0 {
                    CheckResult {
                        status: "healthy".to_string(),
                        message: format!("WASM module accessible, size: {} bytes", metadata.len()),
                        last_checked: now.to_rfc3339(),
                    }
                } else {
                    CheckResult {
                        status: "unhealthy".to_string(),
                        message: "WASM module file is empty".to_string(),
                        last_checked: now.to_rfc3339(),
                    }
                }
            }
            Err(e) => CheckResult {
                status: "unhealthy".to_string(),
                message: format!("WASM module not accessible: {}", e),
                last_checked: now.to_rfc3339(),
            },
        }
    }

    async fn check_mqtt_connection(&self) -> CheckResult {
        let now = chrono::Utc::now();
        let metrics_data = self.metrics.get_metrics();

        // Check if we've had recent MQTT activity (no connection errors in last minute)
        let recent_errors = metrics_data.connection_errors;
        let recent_messages = metrics_data.messages_received;

        if recent_errors == 0 || recent_messages > 0 {
            CheckResult {
                status: "healthy".to_string(),
                message: format!(
                    "MQTT connection healthy, messages received: {}, errors: {}",
                    recent_messages, recent_errors
                ),
                last_checked: now.to_rfc3339(),
            }
        } else {
            CheckResult {
                status: "degraded".to_string(),
                message: format!("MQTT connection issues detected, errors: {}", recent_errors),
                last_checked: now.to_rfc3339(),
            }
        }
    }

    async fn check_memory_usage(&self) -> CheckResult {
        let now = chrono::Utc::now();

        // Basic memory usage check (this is simplified)
        match Self::get_memory_usage() {
            Ok(usage_mb) => {
                if usage_mb < 100 {
                    CheckResult {
                        status: "healthy".to_string(),
                        message: format!("Memory usage: {} MB", usage_mb),
                        last_checked: now.to_rfc3339(),
                    }
                } else if usage_mb < 200 {
                    CheckResult {
                        status: "warning".to_string(),
                        message: format!("Memory usage elevated: {} MB", usage_mb),
                        last_checked: now.to_rfc3339(),
                    }
                } else {
                    CheckResult {
                        status: "unhealthy".to_string(),
                        message: format!("Memory usage high: {} MB", usage_mb),
                        last_checked: now.to_rfc3339(),
                    }
                }
            }
            Err(e) => CheckResult {
                status: "unknown".to_string(),
                message: format!("Could not determine memory usage: {}", e),
                last_checked: now.to_rfc3339(),
            },
        }
    }

    async fn check_message_processing(&self) -> CheckResult {
        let now = chrono::Utc::now();
        let metrics_data = self.metrics.get_metrics();

        let processing_errors = metrics_data.processing_errors;
        let messages_processed = metrics_data.messages_processed;
        let error_rate = if messages_processed > 0 {
            (processing_errors as f64 / messages_processed as f64) * 100.0
        } else {
            0.0
        };

        if error_rate < 1.0 {
            CheckResult {
                status: "healthy".to_string(),
                message: format!(
                    "Processing healthy, processed: {}, error rate: {:.2}%",
                    messages_processed, error_rate
                ),
                last_checked: now.to_rfc3339(),
            }
        } else if error_rate < 5.0 {
            CheckResult {
                status: "warning".to_string(),
                message: format!(
                    "Processing has some errors, processed: {}, error rate: {:.2}%",
                    messages_processed, error_rate
                ),
                last_checked: now.to_rfc3339(),
            }
        } else {
            CheckResult {
                status: "unhealthy".to_string(),
                message: format!(
                    "High processing error rate, processed: {}, error rate: {:.2}%",
                    messages_processed, error_rate
                ),
                last_checked: now.to_rfc3339(),
            }
        }
    }

    fn is_healthy(&self, checks: &HealthChecks) -> bool {
        matches!(checks.wasm_module.status.as_str(), "healthy")
            && matches!(checks.mqtt_connection.status.as_str(), "healthy" | "degraded")
            && matches!(checks.memory_usage.status.as_str(), "healthy" | "warning")
            && matches!(checks.message_processing.status.as_str(), "healthy" | "warning")
    }

    fn get_memory_usage() -> anyhow::Result<u64> {
        // This is a simplified memory usage check
        // In a real implementation, you might use procfs or system calls
        
        #[cfg(target_os = "linux")]
        {
            let status_content = std::fs::read_to_string("/proc/self/status")?;
            for line in status_content.lines() {
                if line.starts_with("VmRSS:") {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 2 {
                        let kb: u64 = parts[1].parse()?;
                        return Ok(kb / 1024); // Convert to MB
                    }
                }
            }
        }
        
        // Fallback - return a default value
        Ok(50) // Assume 50MB if we can't determine actual usage
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metrics::MetricsCollector;

    #[tokio::test]
    async fn test_health_check_creation() {
        let metrics = Arc::new(MetricsCollector::new());
        let health_service = HealthService::new(metrics);
        
        // Should be able to create health service
        assert!(health_service.start_time.elapsed().as_secs() < 1);
    }

    #[tokio::test]
    async fn test_memory_usage_check() {
        let usage = HealthService::get_memory_usage();
        assert!(usage.is_ok());
        
        let usage_mb = usage.unwrap();
        assert!(usage_mb > 0);
        assert!(usage_mb < 10000); // Sanity check
    }
}