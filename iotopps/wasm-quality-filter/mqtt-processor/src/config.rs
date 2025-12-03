use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::env;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub mqtt: MqttConfig,
    pub wasm: WasmConfig,
    pub health: HealthConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MqttConfig {
    pub broker_host: String,
    pub broker_port: u16,
    pub client_id: String,
    pub input_topic: String,
    pub output_topic: String,
    pub qos: u8,
    pub keep_alive: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WasmConfig {
    pub module_path: String,
    pub max_memory_mb: u64,
    pub timeout_seconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthConfig {
    pub check_interval_seconds: u64,
    pub unhealthy_threshold: u32,
}

impl AppConfig {
    pub fn load() -> Result<Self> {
        // Try to load from config file first
        if let Ok(config) = Self::load_from_file() {
            return Ok(config);
        }

        // Fallback to environment variables
        Self::load_from_env()
    }

    fn load_from_file() -> Result<Self> {
        let config_content = std::fs::read_to_string("config.toml")
            .context("Failed to read config.toml")?;
        
        let config: Self = toml::from_str(&config_content)
            .context("Failed to parse config.toml")?;
        
        Ok(config)
    }

    fn load_from_env() -> Result<Self> {
        let mqtt_broker = env::var("MQTT_BROKER")
            .unwrap_or_else(|_| "aio-broker.azure-iot-operations.svc.cluster.local".to_string());
        
        let mqtt_port = env::var("MQTT_PORT")
            .unwrap_or_else(|_| "1883".to_string())
            .parse::<u16>()
            .context("Invalid MQTT_PORT")?;

        let client_id = env::var("MQTT_CLIENT_ID")
            .unwrap_or_else(|_| format!("wasm-quality-filter-{}", uuid::Uuid::new_v4()));

        let input_topic = env::var("INPUT_TOPIC")
            .unwrap_or_else(|_| "azure-iot-operations/data/welding-stations".to_string());

        let output_topic = env::var("OUTPUT_TOPIC")
            .unwrap_or_else(|_| "azure-iot-operations/alerts/quality-control".to_string());

        let wasm_module_path = env::var("WASM_MODULE_PATH")
            .unwrap_or_else(|_| "wasm_quality_filter.wasm".to_string());

        let config = Self {
            mqtt: MqttConfig {
                broker_host: mqtt_broker,
                broker_port: mqtt_port,
                client_id,
                input_topic,
                output_topic,
                qos: 1, // QoS 1 (At least once)
                keep_alive: 60,
            },
            wasm: WasmConfig {
                module_path: wasm_module_path,
                max_memory_mb: 64,
                timeout_seconds: 30,
            },
            health: HealthConfig {
                check_interval_seconds: 30,
                unhealthy_threshold: 3,
            },
        };

        Ok(config)
    }

    /// Validate the configuration
    pub fn validate(&self) -> Result<()> {
        if self.mqtt.broker_host.is_empty() {
            anyhow::bail!("MQTT broker host cannot be empty");
        }

        if self.mqtt.input_topic.is_empty() {
            anyhow::bail!("Input topic cannot be empty");
        }

        if self.mqtt.output_topic.is_empty() {
            anyhow::bail!("Output topic cannot be empty");
        }

        if !std::path::Path::new(&self.wasm.module_path).exists() {
            anyhow::bail!("WASM module file does not exist: {}", self.wasm.module_path);
        }

        if self.wasm.max_memory_mb == 0 {
            anyhow::bail!("WASM max memory must be greater than 0");
        }

        Ok(())
    }
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            mqtt: MqttConfig {
                broker_host: "aio-broker.azure-iot-operations.svc.cluster.local".to_string(),
                broker_port: 1883,
                client_id: format!("wasm-quality-filter-{}", uuid::Uuid::new_v4()),
                input_topic: "azure-iot-operations/data/welding-stations".to_string(),
                output_topic: "azure-iot-operations/alerts/quality-control".to_string(),
                qos: 1,
                keep_alive: 60,
            },
            wasm: WasmConfig {
                module_path: "wasm_quality_filter.wasm".to_string(),
                max_memory_mb: 64,
                timeout_seconds: 30,
            },
            health: HealthConfig {
                check_interval_seconds: 30,
                unhealthy_threshold: 3,
            },
        }
    }
}