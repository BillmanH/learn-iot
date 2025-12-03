#!/usr/bin/env python3
"""
Python Quality Filter for IoT Welding Operations

Replaces the WASM module with a pure Python implementation that:
- Subscribes to welding station MQTT messages
- Filters for quality control issues (scrap + cycle_time < 7s)
- Publishes alerts to quality control topic
- Provides health and metrics endpoints
"""

import asyncio
import json
import logging
import os
import signal
import sys
from datetime import datetime, timezone
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, asdict
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
import paho.mqtt.client as mqtt
from pydantic import BaseModel, Field
import structlog

# Configure structured logging
structlog.configure(
    processors=[
        structlog.stdlib.filter_by_level,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.stdlib.PositionalArgumentsFormatter(),
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.UnicodeDecoder(),
        structlog.processors.JSONRenderer()
    ],
    wrapper_class=structlog.stdlib.LoggerFactory(),
    logger_factory=structlog.stdlib.LoggerFactory(),
    cache_logger_on_first_use=True,
)

logger = structlog.get_logger()

# Configuration
@dataclass
class Config:
    """Application configuration"""
    mqtt_broker: str = os.getenv("MQTT_BROKER", "aio-broker.azure-iot-operations.svc.cluster.local")
    mqtt_port: int = int(os.getenv("MQTT_PORT", "1883"))
    mqtt_client_id: str = os.getenv("MQTT_CLIENT_ID", "python-quality-filter")
    input_topic: str = os.getenv("INPUT_TOPIC", "azure-iot-operations/data/welding-stations")
    output_topic: str = os.getenv("OUTPUT_TOPIC", "azure-iot-operations/alerts/quality-control")
    health_port: int = int(os.getenv("HEALTH_PORT", "8080"))
    log_level: str = os.getenv("LOG_LEVEL", "INFO")
    
    # Quality filter parameters
    quality_threshold: str = os.getenv("QUALITY_THRESHOLD", "scrap")
    cycle_time_threshold: float = float(os.getenv("CYCLE_TIME_THRESHOLD", "7.0"))

# Data Models
class WeldingMessage(BaseModel):
    """Welding station message structure"""
    machine_id: str
    station_id: str
    operator_id: str
    part_id: str
    quality: str
    last_cycle_time: float
    temperature: float
    current: float
    voltage: float
    timestamp: str
    shift: str
    maintenance_status: str

class QualityAlert(BaseModel):
    """Quality control alert structure"""
    alert_id: str
    machine_id: str
    station_id: str
    part_id: str
    alert_type: str = "quality_control"
    severity: str
    description: str
    trigger_conditions: Dict[str, Any]
    original_message: Dict[str, Any]
    timestamp: str
    impact_assessment: Dict[str, str]

class HealthStatus(BaseModel):
    """Health check response"""
    status: str
    timestamp: str
    version: str = "1.0.0"
    uptime_seconds: float
    checks: Dict[str, Dict[str, Any]]

class MetricsResponse(BaseModel):
    """Metrics response"""
    messages_processed: int
    alerts_generated: int
    errors_count: int
    uptime_seconds: float
    last_message_timestamp: Optional[str]

# Quality Filter Logic
class QualityFilter:
    """Core quality filtering logic"""
    
    def __init__(self, config: Config):
        self.config = config
        self.logger = structlog.get_logger("quality_filter")
    
    def should_trigger_alert(self, message: WeldingMessage) -> bool:
        """
        Determine if message should trigger a quality alert
        
        Trigger conditions:
        - Quality is "scrap" 
        - AND cycle_time < threshold (default 7.0 seconds)
        """
        quality_match = message.quality.lower() == self.config.quality_threshold.lower()
        cycle_time_issue = message.last_cycle_time < self.config.cycle_time_threshold
        
        should_alert = quality_match and cycle_time_issue
        
        self.logger.debug(
            "Quality filter evaluation",
            machine_id=message.machine_id,
            quality=message.quality,
            cycle_time=message.last_cycle_time,
            quality_match=quality_match,
            cycle_time_issue=cycle_time_issue,
            should_alert=should_alert
        )
        
        return should_alert
    
    def create_alert(self, message: WeldingMessage) -> QualityAlert:
        """Create a quality control alert from a welding message"""
        
        # Assess severity based on how far below threshold
        time_diff = self.config.cycle_time_threshold - message.last_cycle_time
        if time_diff > 2.0:
            severity = "critical"
            impact = "high"
        elif time_diff > 1.0:
            severity = "high" 
            impact = "medium"
        else:
            severity = "medium"
            impact = "low"
        
        alert = QualityAlert(
            alert_id=f"qa_{message.machine_id}_{int(datetime.now().timestamp() * 1000)}",
            machine_id=message.machine_id,
            station_id=message.station_id,
            part_id=message.part_id,
            severity=severity,
            description=f"Quality issue detected: {message.quality} part with fast cycle time ({message.last_cycle_time:.2f}s)",
            trigger_conditions={
                "quality": message.quality,
                "cycle_time": message.last_cycle_time,
                "cycle_time_threshold": self.config.cycle_time_threshold,
                "time_difference": time_diff
            },
            original_message=message.dict(),
            timestamp=datetime.now(timezone.utc).isoformat(),
            impact_assessment={
                "production_impact": impact,
                "recommendation": "Investigate machine speed and quality correlation",
                "priority": severity
            }
        )
        
        self.logger.info(
            "Quality alert created",
            alert_id=alert.alert_id,
            machine_id=alert.machine_id,
            severity=alert.severity,
            cycle_time=message.last_cycle_time
        )
        
        return alert

# Metrics Collection
class MetricsCollector:
    """Collect and track application metrics"""
    
    def __init__(self):
        self.start_time = datetime.now()
        self.messages_processed = 0
        self.alerts_generated = 0
        self.errors_count = 0
        self.last_message_timestamp: Optional[str] = None
    
    def record_message_processed(self):
        """Record a processed message"""
        self.messages_processed += 1
        self.last_message_timestamp = datetime.now(timezone.utc).isoformat()
    
    def record_alert_generated(self):
        """Record an alert generated"""
        self.alerts_generated += 1
    
    def record_error(self):
        """Record an error"""
        self.errors_count += 1
    
    def get_uptime_seconds(self) -> float:
        """Get uptime in seconds"""
        return (datetime.now() - self.start_time).total_seconds()
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert metrics to dictionary"""
        return {
            "messages_processed": self.messages_processed,
            "alerts_generated": self.alerts_generated,
            "errors_count": self.errors_count,
            "uptime_seconds": self.get_uptime_seconds(),
            "last_message_timestamp": self.last_message_timestamp
        }

# MQTT Handler
class MQTTHandler:
    """Handle MQTT connections and message processing"""
    
    def __init__(self, config: Config, quality_filter: QualityFilter, metrics: MetricsCollector):
        self.config = config
        self.quality_filter = quality_filter
        self.metrics = metrics
        self.logger = structlog.get_logger("mqtt_handler")
        
        # MQTT client setup
        self.client = mqtt.Client(client_id=config.mqtt_client_id)
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect
        self.client.on_log = self._on_log
        
        self.connected = False
        self.running = False
    
    def _on_connect(self, client, userdata, flags, rc):
        """MQTT connection callback"""
        if rc == 0:
            self.connected = True
            self.logger.info("Connected to MQTT broker", broker=self.config.mqtt_broker)
            
            # Subscribe to input topic
            result = client.subscribe(self.config.input_topic)
            if result[0] == 0:
                self.logger.info("Subscribed to topic", topic=self.config.input_topic)
            else:
                self.logger.error("Failed to subscribe to topic", topic=self.config.input_topic)
        else:
            self.logger.error("Failed to connect to MQTT broker", return_code=rc)
    
    def _on_disconnect(self, client, userdata, rc):
        """MQTT disconnection callback"""
        self.connected = False
        self.logger.warning("Disconnected from MQTT broker", return_code=rc)
    
    def _on_log(self, client, userdata, level, buf):
        """MQTT logging callback"""
        self.logger.debug("MQTT log", level=level, message=buf)
    
    def _on_message(self, client, userdata, msg):
        """MQTT message callback"""
        try:
            # Decode and parse message
            message_str = msg.payload.decode('utf-8')
            message_data = json.loads(message_str)
            
            self.logger.debug(
                "Received MQTT message",
                topic=msg.topic,
                payload_size=len(message_str)
            )
            
            # Validate and create welding message object
            welding_message = WeldingMessage(**message_data)
            self.metrics.record_message_processed()
            
            # Apply quality filter
            if self.quality_filter.should_trigger_alert(welding_message):
                alert = self.quality_filter.create_alert(welding_message)
                self._publish_alert(alert)
                self.metrics.record_alert_generated()
            
        except json.JSONDecodeError as e:
            self.logger.error("Failed to decode JSON message", error=str(e))
            self.metrics.record_error()
        except Exception as e:
            self.logger.error("Error processing message", error=str(e))
            self.metrics.record_error()
    
    def _publish_alert(self, alert: QualityAlert):
        """Publish quality alert to output topic"""
        try:
            alert_json = json.dumps(asdict(alert))
            result = self.client.publish(self.config.output_topic, alert_json)
            
            if result.rc == 0:
                self.logger.info(
                    "Quality alert published",
                    alert_id=alert.alert_id,
                    topic=self.config.output_topic
                )
            else:
                self.logger.error("Failed to publish alert", return_code=result.rc)
                self.metrics.record_error()
                
        except Exception as e:
            self.logger.error("Error publishing alert", error=str(e))
            self.metrics.record_error()
    
    async def start(self):
        """Start MQTT connection"""
        self.logger.info("Starting MQTT handler", broker=self.config.mqtt_broker)
        self.running = True
        
        try:
            self.client.connect(self.config.mqtt_broker, self.config.mqtt_port, 60)
            self.client.loop_start()
            
            # Wait for connection
            for _ in range(30):  # 30 second timeout
                if self.connected:
                    break
                await asyncio.sleep(1)
            
            if not self.connected:
                raise Exception("Failed to connect to MQTT broker within timeout")
                
        except Exception as e:
            self.logger.error("Failed to start MQTT handler", error=str(e))
            raise
    
    async def stop(self):
        """Stop MQTT connection"""
        self.logger.info("Stopping MQTT handler")
        self.running = False
        
        if self.client:
            self.client.loop_stop()
            self.client.disconnect()

# FastAPI Health and Metrics Server
def create_app(mqtt_handler: MQTTHandler, metrics: MetricsCollector, config: Config) -> FastAPI:
    """Create FastAPI application for health and metrics endpoints"""
    
    app = FastAPI(
        title="Python Quality Filter",
        description="IoT quality control filtering service",
        version="1.0.0"
    )
    
    @app.get("/health", response_model=HealthStatus)
    async def health():
        """Health check endpoint"""
        checks = {
            "mqtt_connection": {
                "status": "healthy" if mqtt_handler.connected else "unhealthy",
                "message": "Connected to MQTT broker" if mqtt_handler.connected else "Not connected to MQTT broker",
                "last_checked": datetime.now(timezone.utc).isoformat()
            },
            "message_processing": {
                "status": "healthy" if metrics.messages_processed > 0 else "warning",
                "message": f"Processed {metrics.messages_processed} messages",
                "last_checked": datetime.now(timezone.utc).isoformat()
            }
        }
        
        overall_status = "healthy" if all(check["status"] == "healthy" for check in checks.values()) else "unhealthy"
        
        return HealthStatus(
            status=overall_status,
            timestamp=datetime.now(timezone.utc).isoformat(),
            uptime_seconds=metrics.get_uptime_seconds(),
            checks=checks
        )
    
    @app.get("/metrics", response_model=MetricsResponse)
    async def get_metrics():
        """Metrics endpoint"""
        return MetricsResponse(**metrics.to_dict())
    
    @app.get("/config")
    async def get_config():
        """Configuration endpoint (non-sensitive values only)"""
        return {
            "input_topic": config.input_topic,
            "output_topic": config.output_topic,
            "quality_threshold": config.quality_threshold,
            "cycle_time_threshold": config.cycle_time_threshold,
            "version": "1.0.0"
        }
    
    return app

# Main Application
class QualityFilterApp:
    """Main application orchestrator"""
    
    def __init__(self):
        self.config = Config()
        self.metrics = MetricsCollector()
        self.quality_filter = QualityFilter(self.config)
        self.mqtt_handler = MQTTHandler(self.config, self.quality_filter, self.metrics)
        self.app = create_app(self.mqtt_handler, self.metrics, self.config)
        self.logger = structlog.get_logger("app")
        
        # Setup logging level
        logging.getLogger().setLevel(getattr(logging, self.config.log_level.upper()))
    
    async def start(self):
        """Start the application"""
        self.logger.info("Starting Python Quality Filter", config=asdict(self.config))
        
        # Start MQTT handler
        await self.mqtt_handler.start()
        
        # Start health/metrics server
        server_config = uvicorn.Config(
            self.app,
            host="0.0.0.0",
            port=self.config.health_port,
            log_level=self.config.log_level.lower(),
            access_log=False
        )
        server = uvicorn.Server(server_config)
        
        self.logger.info("Quality filter started successfully", health_port=self.config.health_port)
        
        # Run server
        await server.serve()
    
    async def stop(self):
        """Stop the application"""
        self.logger.info("Stopping Python Quality Filter")
        await self.mqtt_handler.stop()

# Signal handling for graceful shutdown
def setup_signal_handlers(app: QualityFilterApp):
    """Setup signal handlers for graceful shutdown"""
    
    def signal_handler(signum, frame):
        logger.info("Received signal, shutting down gracefully", signal=signum)
        asyncio.create_task(app.stop())
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

if __name__ == "__main__":
    # Create and run application
    app = QualityFilterApp()
    setup_signal_handlers(app)
    
    try:
        asyncio.run(app.start())
    except KeyboardInterrupt:
        logger.info("Application interrupted by user")
    except Exception as e:
        logger.error("Application error", error=str(e))
        sys.exit(1)