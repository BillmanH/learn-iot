#!/bin/bash

# Network Connectivity Test Script for K3s Installation
# This script tests various network endpoints that K3s installation requires

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Network Connectivity Test for K3s Installation ===${NC}"
echo "Testing internet connectivity and K3s-related endpoints..."
echo

# Test basic internet connectivity
echo -e "${BLUE}1. Testing basic internet connectivity...${NC}"
if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Basic internet connectivity: OK${NC}"
else
    echo -e "${RED}✗ Basic internet connectivity: FAILED${NC}"
    echo "  Cannot reach 8.8.8.8 - check your network connection"
fi

# Test DNS resolution
echo -e "${BLUE}2. Testing DNS resolution...${NC}"
if nslookup google.com >/dev/null 2>&1; then
    echo -e "${GREEN}✓ DNS resolution: OK${NC}"
else
    echo -e "${RED}✗ DNS resolution: FAILED${NC}"
    echo "  Cannot resolve domain names - check your DNS settings"
fi

# Test K3s installation endpoint
echo -e "${BLUE}3. Testing K3s installation endpoint...${NC}"
if curl -s --connect-timeout 10 --max-time 30 https://get.k3s.io >/dev/null; then
    echo -e "${GREEN}✓ K3s installation endpoint: OK${NC}"
    
    # Test download speed/time
    echo "  Testing K3s installer download speed..."
    start_time=$(date +%s)
    if timeout 60 curl -s -o /tmp/k3s_test_download https://get.k3s.io; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        file_size=$(wc -c < /tmp/k3s_test_download 2>/dev/null || echo "0")
        echo -e "${GREEN}  ✓ K3s installer downloaded in ${duration}s (${file_size} bytes)${NC}"
        rm -f /tmp/k3s_test_download
    else
        echo -e "${YELLOW}  ⚠ K3s installer download is slow (>60s) or failed${NC}"
    fi
else
    echo -e "${RED}✗ K3s installation endpoint: FAILED${NC}"
    echo "  Cannot connect to https://get.k3s.io"
    echo "  This is likely why your K3s installation is hanging!"
fi

# Test GitHub (K3s binary downloads)
echo -e "${BLUE}4. Testing GitHub connectivity (K3s binaries)...${NC}"
if curl -s --connect-timeout 10 --max-time 20 https://github.com/k3s-io/k3s/releases >/dev/null; then
    echo -e "${GREEN}✓ GitHub connectivity: OK${NC}"
else
    echo -e "${RED}✗ GitHub connectivity: FAILED${NC}"
    echo "  Cannot reach GitHub - K3s binary downloads may fail"
fi

# Test Docker Hub (container images)
echo -e "${BLUE}5. Testing Docker Hub connectivity...${NC}"
if curl -s --connect-timeout 10 --max-time 20 https://registry-1.docker.io >/dev/null; then
    echo -e "${GREEN}✓ Docker Hub connectivity: OK${NC}"
else
    echo -e "${RED}✗ Docker Hub connectivity: FAILED${NC}"
    echo "  Cannot reach Docker Hub - container image pulls may fail"
fi

# Test Azure endpoints
echo -e "${BLUE}6. Testing Azure endpoints...${NC}"
if curl -s --connect-timeout 10 --max-time 20 https://management.azure.com >/dev/null; then
    echo -e "${GREEN}✓ Azure management endpoint: OK${NC}"
else
    echo -e "${YELLOW}⚠ Azure management endpoint: FAILED${NC}"
    echo "  Cannot reach Azure - this may affect Azure IoT Operations deployment"
fi

# Check for proxy settings
echo -e "${BLUE}7. Checking proxy configuration...${NC}"
if [ -n "$HTTP_PROXY" ] || [ -n "$HTTPS_PROXY" ] || [ -n "$http_proxy" ] || [ -n "$https_proxy" ]; then
    echo -e "${YELLOW}⚠ Proxy detected:${NC}"
    [ -n "$HTTP_PROXY" ] && echo "  HTTP_PROXY=$HTTP_PROXY"
    [ -n "$HTTPS_PROXY" ] && echo "  HTTPS_PROXY=$HTTPS_PROXY"
    [ -n "$http_proxy" ] && echo "  http_proxy=$http_proxy"
    [ -n "$https_proxy" ] && echo "  https_proxy=$https_proxy"
    echo "  Make sure your proxy allows HTTPS traffic to K3s endpoints"
else
    echo -e "${GREEN}✓ No proxy detected${NC}"
fi

# Check firewall status
echo -e "${BLUE}8. Checking firewall status...${NC}"
if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}⚠ UFW firewall is active${NC}"
        echo "  Make sure ports 6443, 10250 are allowed for K3s"
        echo "  Run: sudo ufw allow 6443/tcp && sudo ufw allow 10250/tcp"
    else
        echo -e "${GREEN}✓ UFW firewall is inactive${NC}"
    fi
elif command -v iptables >/dev/null 2>&1; then
    if iptables -L | grep -q "DROP\|REJECT"; then
        echo -e "${YELLOW}⚠ iptables rules detected${NC}"
        echo "  Check if any rules are blocking K3s traffic"
    else
        echo -e "${GREEN}✓ No restrictive iptables rules found${NC}"
    fi
else
    echo -e "${GREEN}✓ No common firewall tools detected${NC}"
fi

# Test bandwidth with a small download
echo -e "${BLUE}9. Testing download speed...${NC}"
echo "  Downloading a small test file to measure bandwidth..."
start_time=$(date +%s.%N)
if curl -s --connect-timeout 10 --max-time 30 -o /tmp/speed_test http://speedtest.ftp.otenet.gr/files/test1Mb.db; then
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "1")
    file_size=1048576  # 1MB
    speed=$(echo "scale=2; $file_size / $duration / 1024" | bc 2>/dev/null || echo "unknown")
    echo -e "${GREEN}  ✓ Download speed: ~${speed} KB/s${NC}"
    rm -f /tmp/speed_test
else
    echo -e "${YELLOW}  ⚠ Speed test failed or too slow${NC}"
fi

# Summary
echo
echo -e "${BLUE}=== Summary ===${NC}"
echo "If any tests failed, particularly the K3s installation endpoint,"
echo "this is likely why your K3s installation is hanging."
echo
echo -e "${BLUE}Common solutions:${NC}"
echo "• Check your internet connection"
echo "• Verify proxy settings if you're behind a corporate firewall"
echo "• Ensure firewalls allow HTTPS traffic to external sites"
echo "• Try running the script from a different network location"
echo "• Contact your network administrator if in a corporate environment"
echo
echo -e "${BLUE}If all tests pass but K3s still hangs:${NC}"
echo "• The issue is likely resource-related (memory, disk, CPU)"
echo "• Check system logs: sudo journalctl -u k3s --no-pager"
echo "• Monitor system resources: top, free -h, df -h"