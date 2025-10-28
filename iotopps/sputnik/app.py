import paho.mqtt.client as mqtt
import time
import os
import json
import queue
import threading
import ssl
from datetime import datetime
from pathlib import Path

# MQTT Configuration from environment variables
MQTT_BROKER = os.environ.get('MQTT_BROKER', 'localhost')
MQTT_PORT = int(os.environ.get('MQTT_PORT', '18883'))  # Default AIO MQTT port
MQTT_TOPIC = os.environ.get('MQTT_TOPIC', 'sputnik/beep')
MQTT_CLIENT_ID = os.environ.get('MQTT_CLIENT_ID', f'sputnik-{os.getpid()}')
INTERVAL = int(os.environ.get('BEEP_INTERVAL', '6'))

# ServiceAccountToken authentication settings
AUTH_METHOD = os.environ.get('MQTT_AUTH_METHOD', 'K8S-SAT')  # Default to SAT
SAT_TOKEN_PATH = os.environ.get('SAT_TOKEN_PATH', '/var/run/secrets/tokens/broker-sat')

# Global connection state
is_connected = threading.Event()
message_queue = queue.Queue(maxsize=100)  # Buffer up to 100 messages

def get_sat_token():
    """Read the ServiceAccountToken from the mounted volume."""
    try:
        token_path = Path(SAT_TOKEN_PATH)
        if token_path.exists():
            token = token_path.read_text().strip()
            print(f"[OK] Read SAT token from {SAT_TOKEN_PATH} ({len(token)} chars)")
            return token
        else:
            print(f"[ERROR] SAT token file not found at {SAT_TOKEN_PATH}")
            return None
    except Exception as e:
        print(f"[ERROR] Error reading SAT token: {e}")
        return None

def on_connect(client, userdata, flags, reason_code, properties=None):
    """Called when the client connects to the broker. MQTT v5 includes properties parameter."""
    # For MQTT v5, reason_code is a ReasonCodes object
    if hasattr(reason_code, 'value'):
        rc = reason_code.value  # Extract the numeric value from ReasonCodes
    else:
        rc = reason_code  # Fall back to numeric value for MQTT v3

    connection_codes = {
        0: "Connected successfully",
        1: "Incorrect protocol version",
        2: "Invalid client identifier",
        3: "Server unavailable",
        4: "Bad username or password",
        5: "Not authorized",
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
    
    if rc == 0:
        print(f"Connected successfully to MQTT broker at {MQTT_BROKER}:{MQTT_PORT}")
        if properties:
            print(f"Connection properties: {properties}")
        is_connected.set()
    else:
        error_message = connection_codes.get(rc, f"Unknown error (code: {rc})")
        print(f"Failed to connect: {error_message}")
        if properties:
            print(f"Error properties: {properties}")
        is_connected.clear()

def on_disconnect(client, userdata, reason_code, properties=None):
    """Called when the client disconnects from the broker. MQTT v5 includes properties parameter."""
    is_connected.clear()
    
    # Handle MQTT v5 ReasonCodes object
    if hasattr(reason_code, 'value'):
        rc = reason_code.value
    else:
        rc = reason_code
        
    if rc != 0:
        print(f"Unexpected disconnection. Code: {rc}")
    else:
        print("Disconnected successfully")

def on_publish(client, userdata, mid, properties=None):
    """Called when a message has been published to the broker. MQTT v5 includes properties parameter."""
    print(f"Message published (mid: {mid})")

def publish_message(client, topic, message, qos=1, retain=False):
    """Thread-safe message publishing with retry logic."""
    try:
        message_queue.put_nowait(message)
    except queue.Full:
        print("Message queue full - dropping oldest message")
        try:
            message_queue.get_nowait()  # Remove oldest message
            message_queue.put_nowait(message)  # Try again with new message
        except (queue.Empty, queue.Full):
            print("Failed to queue message")
            return False
    return True

def process_message_queue(client):
    """Process messages from the queue and publish to broker."""
    while True:
        try:
            message = message_queue.get(timeout=1.0)  # Wait up to 1 second for a message
            if is_connected.is_set():
                result = client.publish(MQTT_TOPIC, json.dumps(message), qos=1)
                result.wait_for_publish()
                print(f"Beep #{message['beep_count']} sent to {MQTT_TOPIC}")
            else:
                # If not connected, put message back in queue
                message_queue.put(message)
                time.sleep(1)  # Wait before retrying
        except queue.Empty:
            continue  # No messages to process
        except Exception as e:
            print(f"Error publishing message: {e}")
            time.sleep(1)  # Wait before retrying

def main():
    print("=" * 60)
    print("Sputnik MQTT Client - Azure IoT Operations")
    print(f"Authentication Method: {AUTH_METHOD}")
    print("=" * 60)
    print("\nInitializing MQTT client...")
    
    # Create MQTT client with MQTT v5 support
    client = mqtt.Client(
        client_id=MQTT_CLIENT_ID,
        protocol=mqtt.MQTTv5,
        transport="tcp"
    )
    
    # For MQTT v5, configure connection properties
    properties = mqtt.Properties(packetType=1)  # 1 = CONNECT packet
    properties.SessionExpiryInterval = 0  # Clean session behavior
    client._connect_properties = properties
    
    # Configure TLS for encrypted connection
    print("\nSetting up TLS connection...")
    client.tls_set(
        ca_certs=None,  # Don't verify server cert (self-signed in cluster)
        cert_reqs=ssl.CERT_NONE,
        tls_version=ssl.PROTOCOL_TLS_CLIENT,
        ciphers=None
    )
    # Disable hostname verification for internal cluster DNS names
    client.tls_insecure_set(True)
    print("[OK] TLS configured (encrypted connection, no server verification)")
    
    # Configure authentication method
    if AUTH_METHOD == 'K8S-SAT':
        print("\nConfiguring ServiceAccountToken (K8S-SAT) authentication...")
        token = get_sat_token()
        if not token:
            print("[ERROR] Cannot connect without SAT token")
            return
        
        # For MQTT v5 K8S-SAT authentication with paho-mqtt:
        # Use username_pw_set with special values for Azure IoT Operations
        # Username must be empty or specific format, password is the token
        client.username_pw_set(username="", password=token)
        print("[OK] K8S-SAT authentication configured")
    else:
        print(f"\nWarning: Unknown authentication method '{AUTH_METHOD}', proceeding without auth...")
    
    print("\nMQTT client configuration complete")
    
    # Set callbacks
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_publish = on_publish
    
    # Enable automatic reconnection with exponential backoff
    client.reconnect_delay_set(min_delay=1, max_delay=60)
    client.enable_logger()  # Enable built-in logging
    
    # Start message processing thread
    message_processor = threading.Thread(
        target=process_message_queue,
        args=(client,),
        daemon=True
    )
    message_processor.start()
    
    # Connect to broker
    print(f"\nConnecting to MQTT broker {MQTT_BROKER}:{MQTT_PORT}...")
    try:
        # Note: MQTT v5 enhanced auth properties are already set in client._connect_properties
        # The paho-mqtt library will use them automatically during connect
        client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
        client.loop_start()  # Start network loop in separate thread
        
        # Wait a moment for connection to establish
        print("Waiting for connection to establish...")
        time.sleep(2)
        
    except Exception as e:
        print(f"[ERROR] Error connecting to MQTT broker: {e}")
        return

    # Send beep messages periodically
    print(f"\n{'=' * 60}")
    print(f"Starting beep transmission (interval: {INTERVAL}s)")
    print(f"Topic: {MQTT_TOPIC}")
    print(f"{'=' * 60}\n")
    
    beep_count = 0
    try:
        while True:
            # Check if connected before trying to publish
            if not is_connected.is_set():
                print("! Waiting for connection before publishing...")
                time.sleep(1)
                continue
                
            beep_count += 1
            message = {
                'message': 'beep',
                'timestamp': datetime.utcnow().isoformat(),
                'hostname': os.environ.get('HOSTNAME', 'unknown'),
                'beep_count': beep_count
            }
            
            payload = json.dumps(message)
            try:
                # The publish() call will automatically wait for reconnection if disconnected
                result = client.publish(MQTT_TOPIC, payload, qos=1)
                result.wait_for_publish()  # Wait for message to be published
                print(f"[OK] Beep #{beep_count} sent to {MQTT_TOPIC}")
            except Exception as e:
                print(f"[ERROR] Error publishing message: {e}")
                time.sleep(1)  # Brief pause before retry
            
            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        client.loop_stop()
        client.disconnect()

if __name__ == '__main__':
    print("Sputnik MQTT Beeper v1.0.0")
    print(f"Configuration:")
    print(f"  Broker: {MQTT_BROKER}:{MQTT_PORT}")
    print(f"  Topic: {MQTT_TOPIC}")
    print(f"  Interval: {INTERVAL}s")
    print("="*50)
    main()
