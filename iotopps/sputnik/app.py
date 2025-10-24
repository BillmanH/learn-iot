import paho.mqtt.client as mqtt
import time
import os
import json
from datetime import datetime

# MQTT Configuration from environment variables
MQTT_BROKER = os.environ.get('MQTT_BROKER', 'localhost')
MQTT_PORT = int(os.environ.get('MQTT_PORT', '1883'))
MQTT_TOPIC = os.environ.get('MQTT_TOPIC', 'sputnik/beep')
MQTT_CLIENT_ID = os.environ.get('MQTT_CLIENT_ID', 'sputnik')
INTERVAL = int(os.environ.get('BEEP_INTERVAL', '6'))  # seconds between beeps

def on_connect(client, userdata, flags, rc):
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
    else:
        error_message = connection_codes.get(rc, f"Unknown error (code: {rc})")
        print(f"Failed to connect: {error_message}")

def on_publish(client, userdata, mid):
    print(f"Message published (mid: {mid})")

def main():
    # Create MQTT client
    client = mqtt.Client(client_id=MQTT_CLIENT_ID)
    client.on_connect = on_connect
    client.on_publish = on_publish

    # Connect to broker
    print(f"Connecting to MQTT broker {MQTT_BROKER}:{MQTT_PORT}...")
    try:
        client.connect(MQTT_BROKER, MQTT_PORT, 60)
        client.loop_start()
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
            if not client.is_connected():
                print(f"Lost connection to MQTT broker. Attempting to reconnect...")
                try:
                    client.reconnect()
                except Exception as e:
                    print(f"Reconnection failed: {e}")
                    time.sleep(5)  # Wait before next attempt
                    continue

            try:
                result = client.publish(MQTT_TOPIC, payload, qos=1)
                if result.rc == mqtt.MQTT_ERR_SUCCESS:
                    print(f"Beep #{beep_count} sent to {MQTT_TOPIC}")
                else:
                    print(f"Failed to send beep #{beep_count}. Error code: {result.rc}")
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
