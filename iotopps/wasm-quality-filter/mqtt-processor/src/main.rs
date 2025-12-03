use anyhow::{Context, Result};
use rumqttc::{AsyncClient, MqttOptions, QoS};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tracing::{error, info, warn};
use warp::Filter;

mod config;
mod wasm_runtime;
mod health;
mod metrics;

use config::AppConfig;
use wasm_runtime::WasmQualityFilter;
use health::HealthService;
use metrics::MetricsCollector;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    info!("🚀 Starting WASM Quality Filter MQTT Processor");

    // Load configuration
    let config = AppConfig::load().context("Failed to load configuration")?;
    info!("📋 Configuration loaded successfully");
    info!("📡 MQTT Broker: {}", config.mqtt.broker_host);
    info!("📨 Input Topic: {}", config.mqtt.input_topic);
    info!("📤 Output Topic: {}", config.mqtt.output_topic);

    // Initialize WASM runtime
    let wasm_filter = WasmQualityFilter::new(&config.wasm.module_path)
        .context("Failed to initialize WASM runtime")?;
    let wasm_filter = Arc::new(wasm_filter);
    info!("🧠 WASM Quality Filter module loaded");

    // Initialize metrics collector
    let metrics = Arc::new(MetricsCollector::new());

    // Initialize health service
    let health_service = HealthService::new(metrics.clone());

    // Setup MQTT client
    let mqtt_options = MqttOptions::new(&config.mqtt.client_id, &config.mqtt.broker_host, config.mqtt.broker_port);
    let (mqtt_client, mut mqtt_eventloop) = AsyncClient::new(mqtt_options, 10);
    
    // Subscribe to input topic
    mqtt_client
        .subscribe(&config.mqtt.input_topic, QoS::AtLeastOnce)
        .await
        .context("Failed to subscribe to input topic")?;
    
    info!("📡 Subscribed to topic: {}", config.mqtt.input_topic);

    // Create message processing channel
    let (tx, mut rx) = mpsc::channel::<(String, String)>(100);

    // Clone references for tasks
    let mqtt_client_clone = mqtt_client.clone();
    let wasm_filter_clone = wasm_filter.clone();
    let metrics_clone = metrics.clone();
    let output_topic = config.mqtt.output_topic.clone();

    // Start MQTT event loop task
    let mqtt_task = {
        let tx = tx.clone();
        let metrics = metrics.clone();
        tokio::spawn(async move {
            info!("🔄 Starting MQTT event loop");
            loop {
                match mqtt_eventloop.poll().await {
                    Ok(rumqttc::Event::Incoming(rumqttc::Packet::Publish(publish))) => {
                        let topic = publish.topic.clone();
                        let payload = String::from_utf8_lossy(&publish.payload).to_string();
                        
                        metrics.increment_messages_received();
                        
                        if let Err(e) = tx.send((topic, payload)).await {
                            error!("Failed to send message to processing queue: {}", e);
                        }
                    }
                    Ok(_) => {} // Other MQTT events
                    Err(e) => {
                        error!("MQTT connection error: {}", e);
                        metrics.increment_connection_errors();
                        tokio::time::sleep(Duration::from_secs(5)).await;
                    }
                }
            }
        })
    };

    // Start message processing task
    let processing_task = tokio::spawn(async move {
        info!("⚙️ Starting message processing task");
        while let Some((topic, payload)) = rx.recv().await {
            let start_time = std::time::Instant::now();
            
            match wasm_filter_clone.process_message(&payload).await {
                Ok(Some(alert)) => {
                    // Quality control alert generated
                    info!("🚨 Quality alert generated for topic: {}", topic);
                    
                    // Publish alert to output topic
                    if let Err(e) = mqtt_client_clone
                        .publish(&output_topic, QoS::AtLeastOnce, false, alert)
                        .await
                    {
                        error!("Failed to publish quality alert: {}", e);
                        metrics_clone.increment_publish_errors();
                    } else {
                        metrics_clone.increment_alerts_generated();
                        info!("✅ Quality alert published successfully");
                    }
                }
                Ok(None) => {
                    // No alert needed for this message
                    tracing::debug!("No quality alert needed for message from topic: {}", topic);
                }
                Err(e) => {
                    error!("Failed to process message: {}", e);
                    metrics_clone.increment_processing_errors();
                }
            }
            
            let processing_duration = start_time.elapsed();
            metrics_clone.record_processing_latency(processing_duration);
            metrics_clone.increment_messages_processed();
        }
    });

    // Start health check HTTP server
    let health_routes = warp::path("health")
        .and(warp::get())
        .and_then({
            let health_service = health_service.clone();
            move || {
                let health_service = health_service.clone();
                async move {
                    match health_service.check_health().await {
                        Ok(status) => Ok(warp::reply::json(&status)),
                        Err(_) => Err(warp::reject::not_found()),
                    }
                }
            }
        });

    let metrics_routes = warp::path("metrics")
        .and(warp::get())
        .and_then({
            let metrics = metrics.clone();
            move || {
                let metrics = metrics.clone();
                async move {
                    let metrics_data = metrics.get_metrics();
                    Ok::<_, warp::Rejection>(warp::reply::json(&metrics_data))
                }
            }
        });

    let routes = health_routes.or(metrics_routes);
    
    let http_server = warp::serve(routes).run(([0, 0, 0, 0], 8080));

    info!("🌐 Health check server started on http://0.0.0.0:8080");
    info!("💊 Health endpoint: http://0.0.0.0:8080/health");
    info!("📊 Metrics endpoint: http://0.0.0.0:8080/metrics");

    // Run all tasks concurrently
    tokio::select! {
        result = mqtt_task => {
            error!("MQTT task ended unexpectedly: {:?}", result);
        }
        result = processing_task => {
            error!("Processing task ended unexpectedly: {:?}", result);
        }
        result = http_server => {
            error!("HTTP server ended unexpectedly: {:?}", result);
        }
        _ = tokio::signal::ctrl_c() => {
            info!("🛑 Received shutdown signal, gracefully shutting down...");
        }
    }

    info!("👋 WASM Quality Filter MQTT Processor stopped");
    Ok(())
}