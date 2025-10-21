@echo off
REM Local development script for Sputnik on Windows
REM Run this to test the MQTT client locally before deploying

echo Starting Sputnik MQTT Beeper locally...
echo.
echo Make sure you have an MQTT broker running locally or set MQTT_BROKER
echo Default: localhost:1883
echo.

REM Set local development environment variables
set MQTT_BROKER=localhost
set MQTT_PORT=1883
set MQTT_TOPIC=sputnik/beep
set MQTT_CLIENT_ID=sputnik-local
set BEEP_INTERVAL=5

REM Install dependencies if needed
if not exist venv (
    echo Creating virtual environment...
    python -m venv venv
)

call venv\Scripts\activate.bat
pip install -r requirements.txt

REM Run the application
python app.py
