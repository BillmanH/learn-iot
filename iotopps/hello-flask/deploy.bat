@echo off
REM deploy.bat - Build and deploy Flask app to IoT Edge K3s cluster (Windows)

setlocal EnableDelayedExpansion

REM Load configuration from JSON file using PowerShell
set CONFIG_FILE=hello_flask_config.json

if not exist "%CONFIG_FILE%" (
    echo ERROR: Configuration file %CONFIG_FILE% not found
    echo Please create the configuration file with your registry settings
    exit /b 1
)

echo Loading configuration from %CONFIG_FILE%...

REM Use PowerShell to parse JSON and export to temp batch file
powershell -Command "try { $cfg = Get-Content '%CONFIG_FILE%' | ConvertFrom-Json; Write-Output \"set REGISTRY_TYPE=$($cfg.registry.type)\"; Write-Output \"set REGISTRY_NAME=$($cfg.registry.name)\"; Write-Output \"set IMAGE_NAME=$($cfg.image.name)\"; Write-Output \"set IMAGE_TAG=$($cfg.image.tag)\" } catch { Write-Output \"echo ERROR: Failed to parse %CONFIG_FILE%\"; Write-Output \"exit /b 1\" }" > temp_config.bat

call temp_config.bat
del temp_config.bat

echo === Flask IoT Edge Deployment Script ===
echo Configuration loaded: Registry=%REGISTRY_TYPE%/%REGISTRY_NAME%, Image=%IMAGE_NAME%:%IMAGE_TAG%
echo.

REM Validate configuration
if "%REGISTRY_NAME%"=="your-registry-name" (
    echo ERROR: Please update registry.name in %CONFIG_FILE%
    echo Edit %CONFIG_FILE% and set your Docker Hub username or ACR name
    exit /b 1
)

REM Build full image name based on registry type
if "%REGISTRY_TYPE%"=="acr" (
    set FULL_IMAGE_NAME=%REGISTRY_NAME%.azurecr.io/%IMAGE_NAME%:%IMAGE_TAG%
) else (
    set FULL_IMAGE_NAME=%REGISTRY_NAME%/%IMAGE_NAME%:%IMAGE_TAG%
)

echo Step 1: Building Docker image...
docker build -t %IMAGE_NAME%:%IMAGE_TAG% .
if errorlevel 1 (
    echo ERROR: Docker build failed
    exit /b 1
)
echo Build complete
echo.

echo Step 2: Tagging image...
docker tag %IMAGE_NAME%:%IMAGE_TAG% %FULL_IMAGE_NAME%
if errorlevel 1 (
    echo ERROR: Docker tag failed
    exit /b 1
)
echo Tagged as %FULL_IMAGE_NAME%
echo.

echo Step 3: Logging into registry...
if "%REGISTRY_TYPE%"=="acr" (
    az acr login --name %REGISTRY_NAME%
) else (
    docker login
)
if errorlevel 1 (
    echo ERROR: Registry login failed
    exit /b 1
)
echo Logged in
echo.

echo Step 4: Pushing image to registry...
docker push %FULL_IMAGE_NAME%
if errorlevel 1 (
    echo ERROR: Docker push failed
    exit /b 1
)
echo Image pushed
echo.

echo Step 5: Updating deployment configuration...
powershell -Command "(Get-Content deployment.yaml) -replace '<YOUR_REGISTRY>', '%REGISTRY_NAME%' | Set-Content deployment.tmp.yaml"
echo Configuration updated
echo.

echo Step 6: Deploying to Kubernetes...
kubectl apply -f deployment.tmp.yaml
if errorlevel 1 (
    echo ERROR: Kubernetes deployment failed
    del deployment.tmp.yaml
    exit /b 1
)
del deployment.tmp.yaml
echo Deployment applied
echo.

echo Step 7: Waiting for deployment to complete...
kubectl rollout status deployment/hello-flask
if errorlevel 1 (
    echo WARNING: Rollout status check failed
)
echo Deployment ready
echo.

REM Get the node IP
for /f "tokens=*" %%i in ('kubectl get nodes -o jsonpath^={.items[0].status.addresses[?^(@.type^=^=^"InternalIP^"^)].address}') do set NODE_IP=%%i

echo === Deployment Complete ===
echo.
echo Your application is now accessible at:
echo http://%NODE_IP%:30080
echo.
echo To test:
echo   curl http://%NODE_IP%:30080
echo   curl http://%NODE_IP%:30080/health
echo.
echo To view logs:
echo   kubectl logs -l app=hello-flask
echo.
echo To view pods:
echo   kubectl get pods -l app=hello-flask

endlocal
