use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricsData {
    pub messages_received: u64,
    pub messages_processed: u64,
    pub alerts_generated: u64,
    pub processing_errors: u64,
    pub connection_errors: u64,
    pub publish_errors: u64,
    pub avg_processing_latency_ms: f64,
    pub max_processing_latency_ms: u64,
    pub uptime_seconds: u64,
    pub filter_hit_rate: f64,
    pub timestamp: String,
}

pub struct MetricsCollector {
    messages_received: AtomicU64,
    messages_processed: AtomicU64,
    alerts_generated: AtomicU64,
    processing_errors: AtomicU64,
    connection_errors: AtomicU64,
    publish_errors: AtomicU64,
    processing_latencies: Arc<RwLock<Vec<Duration>>>,
    start_time: Instant,
}

impl MetricsCollector {
    pub fn new() -> Self {
        Self {
            messages_received: AtomicU64::new(0),
            messages_processed: AtomicU64::new(0),
            alerts_generated: AtomicU64::new(0),
            processing_errors: AtomicU64::new(0),
            connection_errors: AtomicU64::new(0),
            publish_errors: AtomicU64::new(0),
            processing_latencies: Arc::new(RwLock::new(Vec::new())),
            start_time: Instant::now(),
        }
    }

    pub fn increment_messages_received(&self) {
        self.messages_received.fetch_add(1, Ordering::Relaxed);
    }

    pub fn increment_messages_processed(&self) {
        self.messages_processed.fetch_add(1, Ordering::Relaxed);
    }

    pub fn increment_alerts_generated(&self) {
        self.alerts_generated.fetch_add(1, Ordering::Relaxed);
    }

    pub fn increment_processing_errors(&self) {
        self.processing_errors.fetch_add(1, Ordering::Relaxed);
    }

    pub fn increment_connection_errors(&self) {
        self.connection_errors.fetch_add(1, Ordering::Relaxed);
    }

    pub fn increment_publish_errors(&self) {
        self.publish_errors.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_processing_latency(&self, latency: Duration) {
        tokio::spawn({
            let latencies = self.processing_latencies.clone();
            async move {
                let mut latencies = latencies.write().await;
                latencies.push(latency);
                
                // Keep only the last 1000 measurements to prevent unbounded growth
                if latencies.len() > 1000 {
                    latencies.drain(0..500); // Remove oldest 500
                }
            }
        });
    }

    pub fn get_metrics(&self) -> MetricsData {
        let messages_received = self.messages_received.load(Ordering::Relaxed);
        let messages_processed = self.messages_processed.load(Ordering::Relaxed);
        let alerts_generated = self.alerts_generated.load(Ordering::Relaxed);
        let processing_errors = self.processing_errors.load(Ordering::Relaxed);
        let connection_errors = self.connection_errors.load(Ordering::Relaxed);
        let publish_errors = self.publish_errors.load(Ordering::Relaxed);
        let uptime = self.start_time.elapsed();

        // Calculate filter hit rate (percentage of processed messages that generated alerts)
        let filter_hit_rate = if messages_processed > 0 {
            (alerts_generated as f64 / messages_processed as f64) * 100.0
        } else {
            0.0
        };

        // Calculate latency statistics (this is a simplified version)
        let (avg_latency_ms, max_latency_ms) = {
            // For now, we'll use blocking to get latency stats
            // In a production system, you might want to cache these values
            let latencies = futures::executor::block_on(async {
                self.processing_latencies.read().await.clone()
            });

            if latencies.is_empty() {
                (0.0, 0)
            } else {
                let total_ms: u64 = latencies.iter().map(|d| d.as_millis() as u64).sum();
                let avg_ms = total_ms as f64 / latencies.len() as f64;
                let max_ms = latencies.iter().map(|d| d.as_millis() as u64).max().unwrap_or(0);
                (avg_ms, max_ms)
            }
        };

        MetricsData {
            messages_received,
            messages_processed,
            alerts_generated,
            processing_errors,
            connection_errors,
            publish_errors,
            avg_processing_latency_ms: avg_latency_ms,
            max_processing_latency_ms: max_latency_ms,
            uptime_seconds: uptime.as_secs(),
            filter_hit_rate,
            timestamp: chrono::Utc::now().to_rfc3339(),
        }
    }

    /// Reset all metrics (useful for testing)
    pub fn reset(&self) {
        self.messages_received.store(0, Ordering::Relaxed);
        self.messages_processed.store(0, Ordering::Relaxed);
        self.alerts_generated.store(0, Ordering::Relaxed);
        self.processing_errors.store(0, Ordering::Relaxed);
        self.connection_errors.store(0, Ordering::Relaxed);
        self.publish_errors.store(0, Ordering::Relaxed);
        
        tokio::spawn({
            let latencies = self.processing_latencies.clone();
            async move {
                let mut latencies = latencies.write().await;
                latencies.clear();
            }
        });
    }

    /// Get a summary string for logging
    pub fn get_summary(&self) -> String {
        let metrics = self.get_metrics();
        format!(
            "Processed: {}, Alerts: {}, Errors: {}, Hit Rate: {:.1}%, Avg Latency: {:.2}ms",
            metrics.messages_processed,
            metrics.alerts_generated,
            metrics.processing_errors,
            metrics.filter_hit_rate,
            metrics.avg_processing_latency_ms
        )
    }
}

impl Default for MetricsCollector {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn test_metrics_collector_creation() {
        let collector = MetricsCollector::new();
        let metrics = collector.get_metrics();
        
        assert_eq!(metrics.messages_received, 0);
        assert_eq!(metrics.messages_processed, 0);
        assert_eq!(metrics.alerts_generated, 0);
        assert_eq!(metrics.processing_errors, 0);
    }

    #[tokio::test]
    async fn test_increment_counters() {
        let collector = MetricsCollector::new();
        
        collector.increment_messages_received();
        collector.increment_messages_processed();
        collector.increment_alerts_generated();
        collector.increment_processing_errors();
        
        let metrics = collector.get_metrics();
        assert_eq!(metrics.messages_received, 1);
        assert_eq!(metrics.messages_processed, 1);
        assert_eq!(metrics.alerts_generated, 1);
        assert_eq!(metrics.processing_errors, 1);
    }

    #[tokio::test]
    async fn test_latency_recording() {
        let collector = MetricsCollector::new();
        
        collector.record_processing_latency(Duration::from_millis(10));
        collector.record_processing_latency(Duration::from_millis(20));
        
        // Give some time for async operations
        tokio::time::sleep(Duration::from_millis(10)).await;
        
        let metrics = collector.get_metrics();
        assert!(metrics.avg_processing_latency_ms > 0.0);
        assert!(metrics.max_processing_latency_ms > 0);
    }

    #[tokio::test]
    async fn test_filter_hit_rate_calculation() {
        let collector = MetricsCollector::new();
        
        // Process 10 messages, generate 3 alerts
        for _ in 0..10 {
            collector.increment_messages_processed();
        }
        for _ in 0..3 {
            collector.increment_alerts_generated();
        }
        
        let metrics = collector.get_metrics();
        assert_eq!(metrics.filter_hit_rate, 30.0);
    }

    #[tokio::test]
    async fn test_reset_metrics() {
        let collector = MetricsCollector::new();
        
        collector.increment_messages_received();
        collector.increment_processing_errors();
        
        let metrics_before = collector.get_metrics();
        assert!(metrics_before.messages_received > 0);
        assert!(metrics_before.processing_errors > 0);
        
        collector.reset();
        
        let metrics_after = collector.get_metrics();
        assert_eq!(metrics_after.messages_received, 0);
        assert_eq!(metrics_after.processing_errors, 0);
    }

    #[test]
    fn test_get_summary() {
        let collector = MetricsCollector::new();
        
        collector.increment_messages_processed();
        collector.increment_alerts_generated();
        
        let summary = collector.get_summary();
        assert!(summary.contains("Processed: 1"));
        assert!(summary.contains("Alerts: 1"));
        assert!(summary.contains("Hit Rate: 100.0%"));
    }
}