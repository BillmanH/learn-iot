<#
.SYNOPSIS
    Build and run application locally for development
.DESCRIPTION
    This script sets up a local development environment for the specified
    application. It can run using Python virtual environment, Docker container,
    or uv (if available). Perfect for local testing before deployment.
.PARAMETER AppFolder
    Name of the application folder under iotopps (e.g., 'hello-flask')
.PARAMETER Mode
    Run mode: 'python', 'docker', or 'uv' (default: auto-detect)
.PARAMETER Port
    Local port to run on (default: 5000)
.PARAMETER Build
    Force rebuild of Docker image (docker mode only)
.PARAMETER Clean
    Clean up virtual environment before setup (python mode only)
.EXAMPLE
    .\Deploy-Local.ps1 -AppFolder "hello-flask"
.EXAMPLE
    .\Deploy-Local.ps1 -AppFolder "my-app" -Mode docker -Port 8080
.EXAMPLE
    .\Deploy-Local.ps1 -AppFolder "hello-flask" -Mode python -Clean
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AppFolder,
    
    [Parameter()]
    [ValidateSet('python', 'docker', 'uv', 'auto')]
    [string]$Mode = 'auto',
    
    [Parameter()]
    [int]$Port,
    
    [Parameter()]
    [switch]$Build,
    
    [Parameter()]
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

# Validate app folder
$appPath = Join-Path $PSScriptRoot $AppFolder
if (-not (Test-Path $appPath)) {
    Write-ColorOutput "[ERROR] Application folder not found: $appPath" -Color Red
    Write-Host "Available applications in iotopps:"
    Get-ChildItem $PSScriptRoot -Directory | ForEach-Object { Write-Host "  - $($_.Name)" }
    exit 1
}

# Check for required files
if (-not (Test-Path (Join-Path $appPath "Dockerfile"))) {
    Write-ColorOutput "[ERROR] Dockerfile not found in $appPath" -Color Red
    exit 1
}

# Try to load app-specific config
$appConfigPath = Join-Path $appPath "$($AppFolder)_config.json"
if (Test-Path $appConfigPath) {
    try {
        $config = Get-Content $appConfigPath -Raw | ConvertFrom-Json
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
        Write-ColorOutput "Warning: Could not load config from $appConfigPath - $($_.Exception.Message)" "Yellow"
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
    
    $venvPath = Join-Path $appPath ".venv"
    
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
    $activateScript = Join-Path $venvPath "Scripts\Activate.ps1"
    if (Test-Path $activateScript) {
        Write-ColorOutput "[ACTIVATE] Activating virtual environment..." "Cyan"
        & $activateScript
    }
    
    # Install dependencies if requirements.txt exists
    $requirementsPath = Join-Path $appPath "requirements.txt"
    if (Test-Path $requirementsPath) {
        Write-ColorOutput "[INSTALL] Installing dependencies..." "Cyan"
        pip install -r $requirementsPath
    } else {
        Write-ColorOutput "[WARNING] No requirements.txt found" "Yellow"
    }
    
    # Start the application (assumes Flask by default, can be customized)
    Write-ColorOutput "[START] Starting application on port $Port..." "Green"
    Write-ColorOutput "[INFO] Access your app at: http://localhost:$Port" "Yellow"
    Write-ColorOutput "[STOP] Press Ctrl+C to stop" "Red"
    
    # Change to app directory
    Push-Location $appPath
    try {
        # Try Flask first
        if (Test-Path (Join-Path $appPath "app.py")) {
            $env:FLASK_APP = "app.py"
            $env:FLASK_ENV = "development"
            python -m flask run --host=0.0.0.0 --port=$Port
        } else {
            # Try to find main Python file
            $mainFile = Get-ChildItem $appPath -Filter "*.py" | Select-Object -First 1
            if ($mainFile) {
                Write-ColorOutput "[INFO] Running $($mainFile.Name)..." "Cyan"
                python $mainFile.FullName
            } else {
                Write-ColorOutput "[ERROR] No Python entry point found" "Red"
                exit 1
            }
        }
    } finally {
        Pop-Location
    }
}

function Start-UvMode {
    Write-ColorOutput "[UV] Starting uv mode..." "Green"
    
    # Change to app directory
    Push-Location $appPath
    try {
        # Install dependencies with uv
        Write-ColorOutput "[INSTALL] Installing dependencies with uv..." "Cyan"
        uv sync
        
        # Start the application
        Write-ColorOutput "[START] Starting application on port $Port..." "Green"
        Write-ColorOutput "[INFO] Access your app at: http://localhost:$Port" "Yellow"
        Write-ColorOutput "[STOP] Press Ctrl+C to stop" "Red"
        
        # Try Flask first
        if (Test-Path (Join-Path $appPath "app.py")) {
            $env:FLASK_APP = "app.py"
            $env:FLASK_ENV = "development"
            uv run python -m flask run --host=0.0.0.0 --port=$Port
        } else {
            # Try to find main Python file
            $mainFile = Get-ChildItem $appPath -Filter "*.py" | Select-Object -First 1
            if ($mainFile) {
                Write-ColorOutput "[INFO] Running $($mainFile.Name)..." "Cyan"
                uv run python $mainFile.FullName
            } else {
                Write-ColorOutput "[ERROR] No Python entry point found" "Red"
                exit 1
            }
        }
    } finally {
        Pop-Location
    }
}

function Start-DockerMode {
    Write-ColorOutput "[DOCKER] Starting Docker container mode..." "Green"
    
    $imageName = "$AppFolder-local"
    $containerName = "$AppFolder-dev"
    
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
        Push-Location $appPath
        try {
            docker build -t $imageName .
            if ($LASTEXITCODE -ne 0) {
                throw "Docker build failed"
            }
        } finally {
            Pop-Location
        }
    }
    
    # Run container
    Write-ColorOutput "[DOCKER] Starting Docker container on port $Port..." "Green"
    Write-ColorOutput "[INFO] Access your app at: http://localhost:$Port" "Yellow"
    Write-ColorOutput "[STOP] Press Ctrl+C to stop" "Red"
    
    docker run --rm --name $containerName -p "${Port}:5000" $imageName
}

function Get-PreferredMode {
    if ($Mode -ne 'auto') {
        # If user explicitly requested docker but it's not available, error
        if ($Mode -eq 'docker' -and -not (Test-CommandExists 'docker')) {
            throw "Docker mode requested but docker is not installed or not in PATH"
        }
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
    Write-ColorOutput "🏠 Local Development Runner" "Magenta"
    Write-ColorOutput "=========================" "Magenta"
    Write-ColorOutput "Application: $AppFolder" "Cyan"
    Write-ColorOutput "" "White"
    
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
