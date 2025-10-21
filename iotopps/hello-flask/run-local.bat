@echo off
REM Simple batch script to run Flask app locally
REM This script will try uv first, then fall back to python virtual environment

echo [FLASK] Flask Local Development Runner
echo =================================

cd /d "%~dp0"

REM Check if uv is available
where uv >nul 2>&1
if %errorlevel% == 0 (
    echo [UV] Using uv to run the application...
    echo [INSTALL] Installing dependencies...
    uv sync
    echo [FLASK] Starting Flask application on port 5000...
    echo [INFO] Access your app at: http://localhost:5000
    echo [INFO] Health check at: http://localhost:5000/health
    echo [STOP] Press Ctrl+C to stop
    set FLASK_APP=app.py
    set FLASK_ENV=development
    uv run python -m flask run --host=0.0.0.0 --port=5000
    goto :end
)

REM Fall back to Python virtual environment
echo [PYTHON] Using Python virtual environment...

REM Create virtual environment if it doesn't exist
if not exist ".venv" (
    echo [SETUP] Creating Python virtual environment...
    python -m venv .venv
)

REM Activate virtual environment
echo [ACTIVATE] Activating virtual environment...
call .venv\Scripts\activate.bat

REM Install dependencies
echo [INSTALL] Installing dependencies...
pip install -r requirements.txt

REM Start Flask app
echo [FLASK] Starting Flask application on port 5000...
echo [INFO] Access your app at: http://localhost:5000
echo [INFO] Health check at: http://localhost:5000/health
echo [STOP] Press Ctrl+C to stop

set FLASK_APP=app.py
set FLASK_ENV=development
python -m flask run --host=0.0.0.0 --port=5000

:end