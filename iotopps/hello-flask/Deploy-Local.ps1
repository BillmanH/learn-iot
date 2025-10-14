<#
.SYNOPSIS
    Build and run Flask application locally for development
.DESCRIPTION
    This script sets up a local development environment for the Flask hello-world
    application. It can run using Python virtual environment, Docker container,
    or uv (if available). Perfect for local testing before deployment.
.PARAMETER Mode
    Run mode: 'python', 'docker', or 'uv' (default: auto-detect)
.PARAMETER Port
    Local port to run on (default: 5000)
.PARAMETER Build
    Force rebuild of Docker image (docker mode only)
.PARAMETER Clean
    Clean up virtual environment before setup (python mode only)
.EXAMPLE
    .\Deploy-Local.ps1
.EXAMPLE
    .\Deploy-Local.ps1 -Mode docker -Port 8080
.EXAMPLE
    .\Deploy-Local.ps1 -Mode python -Clean
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('python', 'docker', 'uv', 'auto')]
    [string]$Mode = 'auto',
    
    [Parameter()]
    [int]$Port,
    
    [Parameter()]
    [switch]$Build,
    
    [Parameter()]
    [switch]$Clean,
    
    [Parameter()]
    [string]$HelloFlaskConfigPath = "$PSScriptRoot\hello_flask_config.json"
)

$ErrorActionPreference = 'Stop'

# Load configuration if available
if (Test-Path $HelloFlaskConfigPath) {
    try {
        $config = Get-Content $HelloFlaskConfigPath -Raw | ConvertFrom-Json
        if (-not $Port -and $config.development -and $config.development.localPort) {
            $Port = $config.development.localPort
        }
        if ($config.development -and $config.development.autoMode -and $Mode -eq 'auto') {
            $preferredMode = $config.development.preferredRuntime
            if ($preferredMode -and $preferredMode -ne 'auto') {
                $Mode = $preferredMode
            }
        }
    } catch {
        Write-ColorOutput "Warning: Could not load config from $HelloFlaskConfigPath - $($_.Exception.Message)" "Yellow"
    }
}

# Set default port if still not set
if (-not $Port) { $Port = 5000 }

function Write-ColorOutput {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Test-CommandExists {
    param([string]$Command)
    try {
        Get-Command $Command -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Start-PythonMode {
    Write-ColorOutput "[PYTHON] Starting Python virtual environment mode..." "Green"
    
    $venvPath = "$PSScriptRoot\.venv"
    
    if ($Clean -and (Test-Path $venvPath)) {
        Write-ColorOutput "[CLEAN] Cleaning existing virtual environment..." "Yellow"
        Remove-Item -Recurse -Force $venvPath
    }
    
    # Create virtual environment if it doesn't exist
    if (-not (Test-Path $venvPath)) {
        Write-ColorOutput "[SETUP] Creating Python virtual environment..." "Cyan"
        python -m venv $venvPath
    }
    
    # Activate virtual environment
    $activateScript = "$venvPath\Scripts\Activate.ps1"
    if (Test-Path $activateScript) {
        Write-ColorOutput "[ACTIVATE] Activating virtual environment..." "Cyan"
        & $activateScript
    }
    
    # Install dependencies
    Write-ColorOutput "[INSTALL] Installing dependencies..." "Cyan"
    pip install -r requirements.txt
    
    # Start Flask app
    Write-ColorOutput "[FLASK] Starting Flask application on port $Port..." "Green"
    Write-ColorOutput "[INFO] Access your app at: http://localhost:$Port" "Yellow"
    Write-ColorOutput "[INFO] Health check at: http://localhost:$Port/health" "Yellow"
    Write-ColorOutput "[STOP] Press Ctrl+C to stop" "Red"
    
    $env:FLASK_APP = "app.py"
    $env:FLASK_ENV = "development"
    python -m flask run --host=0.0.0.0 --port=$Port
}

function Start-UvMode {
    Write-ColorOutput "[UV] Starting uv mode..." "Green"
    
    # Install dependencies with uv
    Write-ColorOutput "[INSTALL] Installing dependencies with uv..." "Cyan"
    uv sync
    
    # Start Flask app
    Write-ColorOutput "[FLASK] Starting Flask application on port $Port..." "Green"
    Write-ColorOutput "[INFO] Access your app at: http://localhost:$Port" "Yellow"
    Write-ColorOutput "[INFO] Health check at: http://localhost:$Port/health" "Yellow"
    Write-ColorOutput "[STOP] Press Ctrl+C to stop" "Red"
    
    $env:FLASK_APP = "app.py"
    $env:FLASK_ENV = "development"
    uv run python -m flask run --host=0.0.0.0 --port=$Port
}

function Start-DockerMode {
    Write-ColorOutput "[DOCKER] Starting Docker container mode..." "Green"
    
    $imageName = "hello-flask-local"
    $containerName = "hello-flask-dev"
    
    # Stop and remove existing container
    $existingContainer = docker ps -a --filter "name=$containerName" --format "{{.Names}}" 2>$null
    if ($existingContainer -eq $containerName) {
        Write-ColorOutput "[STOP] Stopping existing container..." "Yellow"
        docker stop $containerName 2>$null | Out-Null
        docker rm $containerName 2>$null | Out-Null
    }
    
    # Build image if requested or if it doesn't exist
    $imageExists = docker images --filter "reference=$imageName" --format "{{.Repository}}" 2>$null
    if ($Build -or (-not $imageExists)) {
        Write-ColorOutput "[BUILD] Building Docker image..." "Cyan"
        docker build -t $imageName .
        if ($LASTEXITCODE -ne 0) {
            throw "Docker build failed"
        }
    }
    
    # Run container
    Write-ColorOutput "[DOCKER] Starting Docker container on port $Port..." "Green"
    Write-ColorOutput "[INFO] Access your app at: http://localhost:$Port" "Yellow"
    Write-ColorOutput "[INFO] Health check at: http://localhost:$Port/health" "Yellow"
    Write-ColorOutput "[STOP] Press Ctrl+C to stop" "Red"
    
    docker run --rm --name $containerName -p "${Port}:5000" $imageName
}

function Get-PreferredMode {
    if ($Mode -ne 'auto') {
        return $Mode
    }
    
    # Auto-detect best available mode
    if (Test-CommandExists 'uv') {
        Write-ColorOutput "✨ Auto-detected: uv is available, using uv mode" "Green"
        return 'uv'
    }
    elseif (Test-CommandExists 'docker') {
        Write-ColorOutput "✨ Auto-detected: Docker is available, using docker mode" "Green"
        return 'docker'
    }
    elseif (Test-CommandExists 'python') {
        Write-ColorOutput "✨ Auto-detected: Python is available, using python mode" "Green"
        return 'python'
    }
    else {
        throw "No suitable runtime found. Please install Python, Docker, or uv."
    }
}

# Main execution
try {
    Write-ColorOutput "🏠 Flask Local Development Runner" "Magenta"
    Write-ColorOutput "=================================" "Magenta"
    
    # Change to script directory
    Set-Location $PSScriptRoot
    
    $selectedMode = Get-PreferredMode
    
    switch ($selectedMode) {
        'python' { Start-PythonMode }
        'uv' { Start-UvMode }
        'docker' { Start-DockerMode }
        default { throw "Invalid mode: $selectedMode" }
    }
}
catch {
    Write-ColorOutput "❌ Error: $($_.Exception.Message)" "Red"
    exit 1
}
finally {
    if ($selectedMode -eq 'docker') {
        Write-ColorOutput "🧹 Cleaning up Docker container..." "Yellow"
        docker stop $containerName 2>$null | Out-Null
    }
}