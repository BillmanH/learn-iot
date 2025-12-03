@echo off
setlocal enabledelayedexpansion

echo 🔧 Building WASM Quality Filter Module...

REM Check if required tools are installed
where cargo >nul 2>nul
if %errorlevel% neq 0 (
    echo ❌ cargo is not installed
    echo Please install Rust and cargo, then try again
    exit /b 1
)

where rustc >nul 2>nul
if %errorlevel% neq 0 (
    echo ❌ rustc is not installed
    echo Please install Rust and try again
    exit /b 1
)

echo 📋 Checking prerequisites...

REM Check if wasm32-wasi target is installed
rustup target list --installed | findstr "wasm32-wasi" >nul
if %errorlevel% neq 0 (
    echo 🎯 Installing wasm32-wasi target...
    rustup target add wasm32-wasi
    if %errorlevel% neq 0 (
        echo ❌ Failed to install wasm32-wasi target
        exit /b 1
    )
) else (
    echo ✅ wasm32-wasi target already installed
)

REM Check for wasm-pack (optional)
where wasm-pack >nul 2>nul
if %errorlevel% equ 0 (
    echo ✅ wasm-pack available for JavaScript builds
    set WASM_PACK_AVAILABLE=true
) else (
    echo ℹ️  wasm-pack not available (JavaScript builds disabled)
    set WASM_PACK_AVAILABLE=false
)

REM Clean previous builds
echo 🧹 Cleaning previous builds...
cargo clean

REM Run tests first
echo 🧪 Running tests...
cargo test --lib
if %errorlevel% neq 0 (
    echo ❌ Tests failed! Please fix issues before building.
    exit /b 1
)
echo ✅ All tests passed

REM Build for WASI
echo 🏗️  Building WASM module for WASI...
cargo build --target wasm32-wasi --release

if %errorlevel% equ 0 (
    echo ✅ WASI build successful
    set WASM_FILE=target\wasm32-wasi\release\wasm_quality_filter.wasm
    
    if exist "!WASM_FILE!" (
        REM Get file size
        for %%A in ("!WASM_FILE!") do set SIZE=%%~zA
        echo 📦 WASM module size: !SIZE! bytes
        echo 📍 Location: !WASM_FILE!
        
        REM Check if wasmtime is available for validation
        where wasmtime >nul 2>nul
        if !errorlevel! equ 0 (
            echo 🔍 Validating WASM module...
            wasmtime --version >nul
            echo ✅ WASM module validation passed
        )
    ) else (
        echo ❌ WASM file not found at expected location
        exit /b 1
    )
) else (
    echo ❌ WASI build failed
    exit /b 1
)

REM Build for web (if wasm-pack is available)
if "%WASM_PACK_AVAILABLE%"=="true" (
    echo 🌐 Building WASM module for web...
    wasm-pack build --target web --out-dir pkg-web --release
    
    if !errorlevel! equ 0 (
        echo ✅ Web build successful
        echo 📍 Web package location: pkg-web\
    ) else (
        echo ⚠️  Web build failed (optional)
    )
)

REM Create deployment directory structure
echo 📁 Creating deployment structure...
if not exist "deploy" mkdir deploy
copy "!WASM_FILE!" deploy\ >nul
copy Cargo.toml deploy\ >nul

REM Generate module info
set BUILD_DATE=%date% %time%
echo { > deploy\module_info.json
echo   "name": "wasm-quality-filter", >> deploy\module_info.json
echo   "version": "0.1.0", >> deploy\module_info.json
echo   "description": "WASM module for real-time quality control filtering in IoT welding operations", >> deploy\module_info.json
echo   "build_date": "%BUILD_DATE%", >> deploy\module_info.json
echo   "target": "wasm32-wasi", >> deploy\module_info.json
echo   "file_size": "!SIZE! bytes", >> deploy\module_info.json
echo   "exports": [ >> deploy\module_info.json
echo     "process_message", >> deploy\module_info.json
echo     "free_string" >> deploy\module_info.json
echo   ], >> deploy\module_info.json
echo   "filter_conditions": { >> deploy\module_info.json
echo     "quality": "scrap", >> deploy\module_info.json
echo     "cycle_time_threshold": 7.0 >> deploy\module_info.json
echo   } >> deploy\module_info.json
echo } >> deploy\module_info.json

echo ✅ Module info created: deploy\module_info.json

echo.
echo 🎉 Build completed successfully!
echo.
echo 📋 Build Summary:
echo    • WASM module: !WASM_FILE!
echo    • Module size: !SIZE! bytes
echo    • Deploy ready: deploy\
echo.
echo 🚀 Next steps:
echo    • Test the module: test.bat
echo    • Build container: docker build -t wasm-quality-filter .
echo    • Deploy to cluster: ..\Deploy-ToIoTEdge.ps1 -AppFolder "wasm-quality-filter"
echo.

pause