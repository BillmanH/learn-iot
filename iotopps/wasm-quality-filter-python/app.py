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
import ssl
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

# Configure standard logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

def get_logger(name: str):
    """Get a simple logger"""
    return logging.getLogger(name)

def get_sat_token(token_path: str) -> Optional[str]:
    """Read the ServiceAccountToken from the mounted volume."""
    logger = get_logger("auth")
    try:
        token_file = Path(token_path)
        if token_file.exists():
            token = token_file.read_text().strip()
            logger.info(f"Read SAT token from {token_path} ({len(token)} chars)")
            return token
        else:
            logger.error(f"SAT token file not found at {token_path}")
            return None
    except Exception as e:
        logger.error(f"Error reading SAT token: {e}")
        return None

# Configuration
@dataclass
class Config:
    """Application configuration"""
    mqtt_broker: str = os.getenv("MQTT_BROKER", "aio-broker.azure-iot-operations.svc.cluster.local")
    mqtt_port: int = int(os.getenv("MQTT_PORT", "18883"))  # MQTTS port
    mqtt_client_id: str = os.getenv("MQTT_CLIENT_ID", "wasm-quality-filter-python")
    input_topic: str = os.getenv("INPUT_TOPIC", "azure-iot-operations/data/welding-stations")
    output_topic: str = os.getenv("OUTPUT_TOPIC", "azure-iot-operations/alerts/quality-control")
    health_port: int = int(os.getenv("HEALTH_PORT", "8080"))
    log_level: str = os.getenv("LOG_LEVEL", "INFO")
    
    # Authentication configuration
    auth_method: str = os.getenv("MQTT_AUTH_METHOD", "K8S-SAT")  # Default to SAT
    sat_token_path: str = os.getenv("SAT_TOKEN_PATH", "/var/run/secrets/tokens/broker-sat")
    
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
        self.logger = get_logger("quality_filter")
    
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
            f"Quality filter evaluation - machine_id={message.machine_id}, "
            f"quality={message.quality}, cycle_time={message.last_cycle_time}, "
            f"should_alert={should_alert}"
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
            f"Quality alert created - alert_id={alert.alert_id}, "
            f"machine_id={alert.machine_id}, severity={alert.severity}, "
            f"cycle_time={message.last_cycle_time}"
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
        self.last_heartbeat = datetime.now()
    
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
    
    def record_heartbeat(self):
        """Record heartbeat timestamp"""
        self.last_heartbeat = datetime.now()
    
    def get_uptime_seconds(self) -> float:
        """Get uptime in seconds"""
        return (datetime.now() - self.start_time).total_seconds()
    
    def get_time_since_last_message(self) -> Optional[float]:
        """Get seconds since last message"""
        if self.last_message_timestamp:
            last_msg = datetime.fromisoformat(self.last_message_timestamp.replace('Z', '+00:00'))
            return (datetime.now(timezone.utc) - last_msg).total_seconds()
        return None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert metrics to dictionary"""
        return {
            "messages_processed": self.messages_processed,
            "alerts_generated": self.alerts_generated,
            "errors_count": self.errors_count,
            "uptime_seconds": self.get_uptime_seconds(),
            "last_message_timestamp": self.last_message_timestamp,
            "time_since_last_message_seconds": self.get_time_since_last_message(),
            "last_heartbeat": self.last_heartbeat.isoformat()
        }

# MQTT Handler
class MQTTHandler:
    """Handle MQTT connections and message processing"""
    
    def __init__(self, config: Config, quality_filter: QualityFilter, metrics: MetricsCollector):
        self.config = config
        self.quality_filter = quality_filter
        self.metrics = metrics
        self.logger = get_logger("mqtt_handler")
        
        # MQTT client setup - try MQTT v5 first, fallback to v3.1.1
        try:
            self.client = mqtt.Client(
                client_id=config.mqtt_client_id,
                protocol=mqtt.MQTTv5,
                transport="tcp"
            )
            self.mqtt_version = "5"
            self.logger.info("Using MQTT v5 protocol")
        except (AttributeError, TypeError):
            # Fallback for older paho-mqtt versions
            self.client = mqtt.Client(
                client_id=config.mqtt_client_id,
                protocol=mqtt.MQTTv311,
                transport="tcp"
            )
            self.mqtt_version = "3.1.1"
            self.logger.warning("MQTT v5 not available, using MQTT v3.1.1")
        
        # Configure TLS for encrypted connection
        self.logger.info("Setting up TLS connection...")
        self.client.tls_set(
            ca_certs=None,  # Don't verify server cert (self-signed in cluster)
            cert_reqs=ssl.CERT_NONE,
            tls_version=ssl.PROTOCOL_TLS_CLIENT,
            ciphers=None
        )
        self.client.tls_insecure_set(True)
        self.logger.info("TLS configured (encrypted connection, no server verification)")
        
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect
        self.client.on_log = self._on_log
        
        self.connected = False
        self.running = False
    
    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        """MQTT connection callback - compatible with both MQTT v3 and v5"""
        # Handle both MQTT v3 (reason_code is int) and v5 (reason_code is ReasonCodes object)
        if hasattr(reason_code, 'value'):
            rc = reason_code.value  # Extract the numeric value from ReasonCodes (MQTT v5)
        else:
            rc = reason_code  # Numeric value for MQTT v3
            
        if rc == 0:
            self.connected = True
            self.logger.info(f"Connected to MQTT broker: {self.config.mqtt_broker}:{self.config.mqtt_port}")
            if properties and self.mqtt_version == "5":
                self.logger.info(f"Connection properties: {properties}")
            
            # Subscribe to input topic
            result = client.subscribe(self.config.input_topic)
            if result[0] == 0:
                self.logger.info(f"Subscribed to topic: {self.config.input_topic}")
            else:
                self.logger.error(f"Failed to subscribe to topic: {self.config.input_topic}")
        else:
            # Enhanced error reporting for MQTT v5, basic for v3
            if self.mqtt_version == "5":
                # MQTT v5 CONNACK Reason Codes
                connack_codes = {
                    0: "Success",
                    1: "Connection refused - unacceptable protocol version",
                    2: "Connection refused - identifier rejected", 
                    3: "Connection refused - server unavailable",
                    4: "Connection refused - bad username or password",
                    5: "Connection refused - not authorized",
                    128: "Unspecified error",
                    129: "Malformed packet",
                    130: "Protocol error",
                    131: "Implementation specific error",
                    132: "Unsupported protocol version",
                    133: "Client identifier not valid",
                    134: "Bad username or password",
                    135: "Not authorized",
                    136: "Server unavailable",
                    137: "Server busy",
                    138: "Banned",
                    140: "Bad authentication method",
                    144: "Topic name invalid",
                    149: "Packet too large",
                    151: "Quota exceeded",
                    153: "Payload format invalid",
                    155: "Retain not supported",
                    156: "QoS not supported",
                    157: "Use another server",
                    158: "Server moved",
                    159: "Connection rate exceeded"
                }
                error_message = connack_codes.get(rc, f"Unknown CONNACK error (code: {rc})")
                self.logger.error(f"Failed to connect: {error_message}")
                self.logger.error(f"CONNACK reason code: {rc}")
                if properties:
                    self.logger.error(f"Error properties: {properties}")
            else:
                # MQTT v3 error codes
                connack_codes = {
                    1: "Connection refused - incorrect protocol version",
                    2: "Connection refused - invalid client identifier",
                    3: "Connection refused - server unavailable",
                    4: "Connection refused - bad username or password",
                    5: "Connection refused - not authorized"
                }
                error_message = connack_codes.get(rc, f"Unknown error (code: {rc})")
                self.logger.error(f"Failed to connect: {error_message}")
            self.connected = False
    
    def _on_disconnect(self, client, userdata, reason_code, properties=None):
        """MQTT disconnection callback - compatible with both MQTT v3 and v5"""
        self.connected = False
        
        # Handle MQTT v5 ReasonCodes object vs MQTT v3 integer
        if hasattr(reason_code, 'value'):
            rc = reason_code.value
        else:
            rc = reason_code
        
        if rc != 0:
            if self.mqtt_version == "5" and properties:
                self.logger.warning(f"Unexpected disconnection, return code: {rc}")
                self.logger.warning(f"Disconnect properties: {properties}")
            else:
                self.logger.warning(f"Unexpected disconnection, return code: {rc}")
        else:
            self.logger.info("Disconnected successfully")
    
    def _on_log(self, client, userdata, level, buf):
        """MQTT logging callback"""
        self.logger.debug(f"MQTT log - level: {level}, message: {buf}")
    
    def _on_message(self, client, userdata, msg):
        """MQTT message callback"""
        try:
            # Decode and parse message
            message_str = msg.payload.decode('utf-8')
            message_data = json.loads(message_str)
            
            self.logger.debug(
                f"Received MQTT message - topic: {msg.topic}, "
                f"payload_size: {len(message_str)}"
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
            self.logger.error(f"Failed to decode JSON message: {str(e)}")
            self.metrics.record_error()
        except Exception as e:
            self.logger.error(f"Error processing message: {str(e)}")
            self.metrics.record_error()
    
    def _publish_alert(self, alert: QualityAlert):
        """Publish quality alert to output topic"""
        try:
            alert_json = json.dumps(asdict(alert))
            result = self.client.publish(self.config.output_topic, alert_json)
            
            if result.rc == 0:
                self.logger.info(
                    f"Quality alert published - alert_id: {alert.alert_id}, "
                    f"topic: {self.config.output_topic}"
                )
            else:
                self.logger.error(f"Failed to publish alert, return code: {result.rc}")
                self.metrics.record_error()
                
        except Exception as e:
            self.logger.error(f"Error publishing alert: {str(e)}")
            self.metrics.record_error()
    
    async def start(self):
        """Start MQTT connection with retry logic"""
        self.logger.info(f"Starting MQTT handler, broker: {self.config.mqtt_broker}")
        self.running = True
        
        max_retries = 3
        retry_delay = 5  # seconds
        
        for attempt in range(max_retries):
            try:
                self.logger.info(f"MQTT connection attempt {attempt + 1}/{max_retries}")
                
                # Test network connectivity first
                import socket
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(10)
                result = sock.connect_ex((self.config.mqtt_broker, self.config.mqtt_port))
                sock.close()
                
                if result != 0:
                    raise ConnectionError(f"Cannot reach MQTT broker at {self.config.mqtt_broker}:{self.config.mqtt_port}")
                
                self.logger.info("Network connectivity to MQTT broker confirmed")
                
                # Configure K8S-SAT authentication if enabled
                connect_properties = None
                if self.config.auth_method == 'K8S-SAT':
                    self.logger.info("Configuring ServiceAccountToken (K8S-SAT) authentication...")
                    token = get_sat_token(self.config.sat_token_path)
                    if not token:
                        raise ConnectionError("Cannot connect without SAT token")
                    
                    # Handle different paho-mqtt versions
                    try:
                        # For paho-mqtt 2.0+
                        connect_properties = mqtt.Properties(mqtt.PacketTypes.CONNECT)
                        connect_properties.AuthenticationMethod = 'K8S-SAT'
                        connect_properties.AuthenticationData = token.encode('utf-8')
                        self.logger.info("Using MQTT v5 with paho-mqtt 2.0+")
                    except AttributeError:
                        # For paho-mqtt 1.x - fallback to username/password
                        self.logger.warning("paho-mqtt 1.x detected, using username/password auth instead of MQTT v5")
                        self.client.username_pw_set("", token)
                        connect_properties = None
                    
                    self.logger.info("K8S-SAT authentication configured")
                    self.logger.info(f"Token length: {len(token)} characters")
                else:
                    self.logger.warning(f"Unknown authentication method '{self.config.auth_method}'")
                
                # Connect to MQTT
                self.client.connect(self.config.mqtt_broker, self.config.mqtt_port, 60, properties=connect_properties)
                self.client.loop_start()
                
                # Wait for connection with shorter timeout per attempt
                connection_timeout = 10  # seconds per attempt
                for i in range(connection_timeout):
                    if self.connected:
                        self.logger.info("✅ MQTT connection established successfully")
                        self.logger.info(f"🎯 Monitoring topic: {self.config.input_topic}")
                        self.logger.info(f"📢 Publishing alerts to: {self.config.output_topic}")
                        self.logger.info("🔍 Quality Filter Active - Looking for scrap parts with cycle_time < 7s")
                        return  # Success!
                    await asyncio.sleep(1)
                
                # If we get here, connection timed out
                self.client.loop_stop()
                self.client.disconnect()
                raise TimeoutError(f"MQTT connection timeout after {connection_timeout} seconds")
                
            except Exception as e:
                self.logger.warning(f"MQTT connection attempt {attempt + 1} failed: {str(e)}")
                
                if attempt < max_retries - 1:
                    self.logger.info(f"Retrying in {retry_delay} seconds...")
                    await asyncio.sleep(retry_delay)
                    retry_delay *= 2  # Exponential backoff
                else:
                    self.logger.error(f"All MQTT connection attempts failed. Last error: {str(e)}")
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
        title="WASM Quality Filter (Python)",
        description="IoT quality control filtering service - Python replacement for WASM module",
        version="1.0.0"
    )
    
    @app.get("/health", response_model=HealthStatus)
    async def health():
        """Health check endpoint"""
        checks = {
            "mqtt_connection": {
                "status": "healthy" if mqtt_handler.connected else "unhealthy",
                "message": f"Connected to {config.mqtt_broker}" if mqtt_handler.connected else f"Not connected to {config.mqtt_broker}",
                "last_checked": datetime.now(timezone.utc).isoformat(),
                "broker": config.mqtt_broker,
                "port": config.mqtt_port,
                "auth_method": config.auth_method,
                "tls_enabled": True if config.mqtt_port == 18883 else False
            },
            "message_processing": {
                "status": "healthy" if metrics.messages_processed > 0 else "warning",
                "message": f"Processed {metrics.messages_processed} messages, generated {metrics.alerts_generated} alerts",
                "last_checked": datetime.now(timezone.utc).isoformat(),
                "last_message": metrics.last_message_timestamp or "None"
            },
            "application": {
                "status": "healthy",
                "message": f"Running for {metrics.get_uptime_seconds():.1f} seconds",
                "last_checked": datetime.now(timezone.utc).isoformat(),
                "version": "1.0.0"
            }
        }
        
        # Determine overall status
        mqtt_ok = checks["mqtt_connection"]["status"] == "healthy"
        processing_ok = checks["message_processing"]["status"] in ["healthy", "warning"]
        
        if mqtt_ok and processing_ok:
            overall_status = "healthy"
        elif mqtt_ok:
            overall_status = "warning"  # MQTT works but no messages yet
        else:
            overall_status = "unhealthy"  # MQTT connection failed
        
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
        self.logger = get_logger("app")
        
        # Setup logging level
        logging.getLogger().setLevel(getattr(logging, self.config.log_level.upper()))
    
    async def _heartbeat_loop(self):
        """Background task that logs periodic status updates"""
        await asyncio.sleep(30)  # Wait 30 seconds before first heartbeat
        
        while True:
            try:
                self.metrics.record_heartbeat()
                uptime = self.metrics.get_uptime_seconds()
                
                # Log status every 2 minutes
                if self.mqtt_handler.connected:
                    time_since_msg = self.metrics.get_time_since_last_message()
                    if time_since_msg is None:
                        self.logger.info(f"💓 Heartbeat: Connected, waiting for messages (uptime: {uptime:.0f}s)")
                    elif time_since_msg > 300:  # 5 minutes
                        self.logger.info(f"💓 Heartbeat: Connected, no messages for {time_since_msg:.0f}s (uptime: {uptime:.0f}s)")
                    else:
                        self.logger.info(f"💓 Heartbeat: Active - {self.metrics.messages_processed} messages, {self.metrics.alerts_generated} alerts (uptime: {uptime:.0f}s)")
                else:
                    self.logger.warning(f"💓 Heartbeat: MQTT disconnected (uptime: {uptime:.0f}s)")
                
                await asyncio.sleep(120)  # Log every 2 minutes
                
            except Exception as e:
                self.logger.error(f"Heartbeat error: {e}")
                await asyncio.sleep(60)  # Retry in 1 minute on error
    
    async def start(self):
        """Start the application with better error handling"""
        self.logger.info("=" * 70)
        self.logger.info("🚀 WASM Quality Filter (Python) - Azure IoT Operations")
        self.logger.info(f"   Authentication Method: {self.config.auth_method}")
        self.logger.info(f"   MQTT Broker: {self.config.mqtt_broker}:{self.config.mqtt_port}")
        self.logger.info(f"   TLS Encryption: {'Enabled' if self.config.mqtt_port == 18883 else 'Disabled'}")
        self.logger.info(f"   Input Topic: {self.config.input_topic}")
        self.logger.info(f"   Output Topic: {self.config.output_topic}")
        self.logger.info("=" * 70)
        
        try:
            # Start MQTT handler with retries
            await self.mqtt_handler.start()
            
            # Start heartbeat task
            heartbeat_task = asyncio.create_task(self._heartbeat_loop())
            
            # Start health/metrics server
            server_config = uvicorn.Config(
                self.app,
                host="0.0.0.0",
                port=self.config.health_port,
                log_level=self.config.log_level.lower(),
                access_log=False
            )
            server = uvicorn.Server(server_config)
            
            self.logger.info("🚀 Quality filter started successfully!")
            self.logger.info(f"🏥 Health endpoint available at: http://0.0.0.0:{self.config.health_port}/health")
            self.logger.info(f"📊 Metrics endpoint available at: http://0.0.0.0:{self.config.health_port}/metrics")
            self.logger.info("=" * 70)
            
            # Run server
            await server.serve()
            
        except Exception as e:
            self.logger.error(f"Failed to start application: {str(e)}")
            # Try to continue with limited functionality (health endpoint only)
            self.logger.warning("Starting in degraded mode - health endpoint only")
            
            server_config = uvicorn.Config(
                self.app,
                host="0.0.0.0", 
                port=self.config.health_port,
                log_level=self.config.log_level.lower(),
                access_log=False
            )
            server = uvicorn.Server(server_config)
            await server.serve()
    
    async def stop(self):
        """Stop the application"""
        self.logger.info("Stopping WASM Quality Filter (Python)")
        await self.mqtt_handler.stop()

# Signal handling for graceful shutdown
def setup_signal_handlers(app: QualityFilterApp):
    """Setup signal handlers for graceful shutdown"""
    logger = get_logger("signal_handler")
    
    def signal_handler(signum, frame):
        logger.info(f"Received signal {signum}, shutting down gracefully")
        asyncio.create_task(app.stop())
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

if __name__ == "__main__":
    # Create and run application
    app = QualityFilterApp()
    setup_signal_handlers(app)
    logger = get_logger("main")
    
    try:
        asyncio.run(app.start())
    except KeyboardInterrupt:
        logger.info("Application interrupted by user")
    except Exception as e:
        logger.error(f"Application error: {str(e)}")
        sys.exit(1)