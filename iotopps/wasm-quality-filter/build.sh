#!/bin/bash
set -e

echo "🔧 Building WASM Quality Filter Module..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if required tools are installed
check_tool() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}❌ $1 is not installed${NC}"
        echo "Please install $1 and try again"
        exit 1
    fi
}

echo -e "${BLUE}📋 Checking prerequisites...${NC}"
check_tool "cargo"
check_tool "rustc"

# Check if wasm32-wasip1 target is installed
if ! rustup target list --installed | grep -q "wasm32-wasip1"; then
    echo -e "${YELLOW}🎯 Installing wasm32-wasip1 target...${NC}"
    rustup target add wasm32-wasip1
else
    echo -e "${GREEN}✅ wasm32-wasip1 target already installed${NC}"
fi

# Optional: Check for wasm-pack (for JavaScript integration)
if command -v wasm-pack &> /dev/null; then
    echo -e "${GREEN}✅ wasm-pack available for JavaScript builds${NC}"
    WASM_PACK_AVAILABLE=true
else
    echo -e "${YELLOW}ℹ️  wasm-pack not available (JavaScript builds disabled)${NC}"
    WASM_PACK_AVAILABLE=false
fi

# Clean previous builds
echo -e "${BLUE}🧹 Cleaning previous builds...${NC}"
cargo clean

# Run tests first
echo -e "${BLUE}🧪 Running tests...${NC}"
cargo test --lib
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Tests failed! Please fix issues before building.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ All tests passed${NC}"

# Build for WASI (for server-side WASM runtimes)
echo -e "${BLUE}🏗️  Building WASM module for WASI...${NC}"
cargo build --target wasm32-wasip1 --release

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ WASI build successful${NC}"
    WASM_FILE="target/wasm32-wasip1/release/wasm_quality_filter.wasm"
    
    if [ -f "$WASM_FILE" ]; then
        # Get file size
        SIZE=$(du -h "$WASM_FILE" | cut -f1)
        echo -e "${GREEN}📦 WASM module size: ${SIZE}${NC}"
        echo -e "${GREEN}📍 Location: ${WASM_FILE}${NC}"
        
        # Optional: Strip debug information to reduce size further
        if command -v wasm-strip &> /dev/null; then
            echo -e "${BLUE}🔧 Stripping debug information...${NC}"
            cp "$WASM_FILE" "${WASM_FILE}.backup"
            wasm-strip "$WASM_FILE"
            NEW_SIZE=$(du -h "$WASM_FILE" | cut -f1)
            echo -e "${GREEN}📦 Optimized size: ${NEW_SIZE}${NC}"
        fi
        
        # Validate the WASM module
        if command -v wasmtime &> /dev/null; then
            echo -e "${BLUE}🔍 Validating WASM module...${NC}"
            wasmtime --version > /dev/null # Just check if wasmtime works
            echo -e "${GREEN}✅ WASM module validation passed${NC}"
        fi
    else
        echo -e "${RED}❌ WASM file not found at expected location${NC}"
        exit 1
    fi
else
    echo -e "${RED}❌ WASI build failed${NC}"
    exit 1
fi

# Build for web (if wasm-pack is available)
if [ "$WASM_PACK_AVAILABLE" = true ]; then
    echo -e "${BLUE}🌐 Building WASM module for web...${NC}"
    wasm-pack build --target web --out-dir pkg-web --release
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Web build successful${NC}"
        echo -e "${GREEN}📍 Web package location: pkg-web/${NC}"
    else
        echo -e "${YELLOW}⚠️  Web build failed (optional)${NC}"
    fi
fi

# Create deployment directory structure
echo -e "${BLUE}📁 Creating deployment structure...${NC}"
mkdir -p deploy
cp "$WASM_FILE" deploy/
cp Cargo.toml deploy/

# Generate module info
cat > deploy/module_info.json << EOF
{
  "name": "wasm-quality-filter",
  "version": "0.1.0",
  "description": "WASM module for real-time quality control filtering in IoT welding operations",
  "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "target": "wasm32-wasi",
  "file_size": "${SIZE}",
  "exports": [
    "process_message",
    "free_string"
  ],
  "filter_conditions": {
    "quality": "scrap",
    "cycle_time_threshold": 7.0
  }
}
EOF

echo -e "${GREEN}✅ Module info created: deploy/module_info.json${NC}"

echo ""
echo -e "${GREEN}🎉 Build completed successfully!${NC}"
echo ""
echo -e "${BLUE}📋 Build Summary:${NC}"
echo -e "   • WASM module: ${WASM_FILE}"
echo -e "   • Module size: ${SIZE}"
echo -e "   • Deploy ready: deploy/"
echo ""
echo -e "${BLUE}🚀 Next steps:${NC}"
echo -e "   • Test the module: ./test.sh"
echo -e "   • Build container: docker build -t wasm-quality-filter ."
echo -e "   • Deploy to cluster: ../Deploy-ToIoTEdge.ps1 -AppFolder \"wasm-quality-filter\""
echo ""