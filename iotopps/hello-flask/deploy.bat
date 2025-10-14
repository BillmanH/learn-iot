@echo off
REM deploy.bat - Build and deploy Flask app to IoT Edge K3s cluster (Windows)

setlocal EnableDelayedExpansion

REM Configuration - Update these values
set REGISTRY_TYPE=dockerhub
set REGISTRY_NAME=your-registry-name
set IMAGE_NAME=hello-flask
set IMAGE_TAG=latest

echo === Flask IoT Edge Deployment Script ===
echo.

REM Validate configuration
if "%REGISTRY_NAME%"=="your-registry-name" (
    echo ERROR: Please update REGISTRY_NAME in this script
    echo Edit deploy.bat and set your Docker Hub username or ACR name
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
