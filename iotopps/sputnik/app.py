import paho.mqtt.client as mqtt
import time
import os
import json
import queue
import threading
import ssl
from datetime import datetime

# MQTT Configuration from environment variables
MQTT_BROKER = os.environ.get('MQTT_BROKER', 'localhost')
MQTT_PORT = int(os.environ.get('MQTT_PORT', '18883'))  # Default AIO MQTT port
MQTT_TOPIC = os.environ.get('MQTT_TOPIC', 'sputnik/beep')
MQTT_CLIENT_ID = os.environ.get('MQTT_CLIENT_ID', f'sputnik-{os.getpid()}')
INTERVAL = int(os.environ.get('BEEP_INTERVAL', '6'))

# Global connection state
is_connected = threading.Event()
message_queue = queue.Queue(maxsize=100)  # Buffer up to 100 messages

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
        5: "Not authorized"
    }
    
    if rc == 0:
        print(f"Connected to MQTT broker at {MQTT_BROKER}:{MQTT_PORT}")
        is_connected.set()
    else:
        error_message = connection_codes.get(rc, f"Unknown error (code: {rc})")
        print(f"Failed to connect: {error_message}")
        is_connected.clear()

def on_disconnect(client, userdata, rc):
    """Called when the client disconnects from the broker."""
    is_connected.clear()
    if rc != 0:
        print(f"Unexpected disconnection. Code: {rc}")
    else:
        print("Disconnected successfully")

def on_publish(client, userdata, mid):
    """Called when a message has been published to the broker."""
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
    # Create MQTT client with a unique ID and persistent session
    client = mqtt.Client(client_id=MQTT_CLIENT_ID,
                        protocol=mqtt.MQTTv5,
                        transport="tcp")  # Azure IoT Operations supports MQTT v5
    
    # For MQTT v5, we need to configure specific properties
    # CONNECT packet type is 1 in MQTT protocol
    properties = mqtt.Properties(packetType=1)  # 1 = CONNECT packet
    properties.SessionExpiryInterval = 0  # Clean session behavior
    client._connect_properties = properties
    
    # For demo/development only: Allow insecure TLS
    client.tls_set(cert_reqs=ssl.CERT_NONE, tls_version=ssl.PROTOCOL_TLS)
    client.tls_insecure_set(True)
    
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
    print(f"Connecting to MQTT broker {MQTT_BROKER}:{MQTT_PORT} with TLS...")
    try:
        client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
        client.loop_start()  # Start network loop in separate thread
    except Exception as e:
        print(f"Error connecting to MQTT broker: {e}")
        return

    # Send beep messages periodically
    beep_count = 0
    try:
        while True:
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
                print(f"Beep #{beep_count} sent to {MQTT_TOPIC}")
            except Exception as e:
                print(f"Error publishing message: {e}")
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
