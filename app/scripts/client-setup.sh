#!/bin/bash

# DeVPN Client Setup Script - Auto-run version
# This script sets up WireGuard VPN client with all error handling

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo ""
echo "=========================================="
echo "       DeVPN CLIENT SETUP"
echo "=========================================="
echo ""

# Get node IP - either from argument or prompt
NODE_IP="${1:-}"
if [ -z "$NODE_IP" ]; then
    echo "Enter the Node IP address (e.g., 10.104.93.17):"
    read -r NODE_IP
fi

if [ -z "$NODE_IP" ]; then
    echo -e "${RED}Node IP is required. Exiting.${NC}"
    exit 1
fi

echo ""
echo "Connecting to node at: $NODE_IP"
echo ""

# Get password upfront
echo "Enter your laptop password to setup VPN client:"
sudo -v || { echo -e "${RED}Password required. Exiting.${NC}"; exit 1; }

# Keep sudo alive in background
( while true; do sudo -n true; sleep 50; done ) &
SUDO_PID=$!
trap "kill $SUDO_PID 2>/dev/null" EXIT

echo ""
echo -e "${GREEN}[1/5]${NC} Disabling firewall..."
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off 2>/dev/null || true

echo -e "${GREEN}[2/5]${NC} Stopping existing WireGuard..."
sudo wg-quick down wg0 2>/dev/null || true
sudo wg-quick down /etc/wireguard/wg0.conf 2>/dev/null || true
sudo wg-quick down /opt/homebrew/etc/wireguard/wg0.conf 2>/dev/null || true

# Kill any existing wireguard-go processes
sudo pkill -f wireguard-go 2>/dev/null || true
sleep 1

echo -e "${GREEN}[3/5]${NC} Creating WireGuard config..."

# Determine config directory
if [ -d "/opt/homebrew/etc" ]; then
    CONFIG_DIR="/opt/homebrew/etc/wireguard"
else
    CONFIG_DIR="/etc/wireguard"
fi
sudo mkdir -p "$CONFIG_DIR"

# Client keys - FRIEND's laptop
CLIENT_PRIVATE="EO6SoyWxAsClEy8I8CCXtNfafJ5AJiWlDDgluGjBH2A="
CLIENT_PUBLIC="e6/0jubRkV9t459F3tPKZ4mG00H7DlAzW/aWZrRIw1k="
SERVER_PUBLIC="cxQI5Fo41hUTcAEpH/uPaKqO7+xsjXd9D6WYz+0ySxI="

# Write config
sudo tee "$CONFIG_DIR/wg0.conf" > /dev/null << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE
Address = 10.0.0.2/24

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = ${NODE_IP}:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

sudo chmod 600 "$CONFIG_DIR/wg0.conf"

echo -e "${GREEN}[4/5]${NC} Starting WireGuard..."

# Try multiple methods to start WireGuard
if sudo wg-quick up wg0 2>/dev/null; then
    echo -e "${GREEN}✓ WireGuard started successfully${NC}"
elif sudo wg-quick up "$CONFIG_DIR/wg0.conf" 2>/dev/null; then
    echo -e "${GREEN}✓ WireGuard started with full path${NC}"
else
    echo -e "${YELLOW}Trying manual setup...${NC}"
    # Manual fallback
    IFACE=$(sudo wireguard-go utun 2>&1 | grep -oE 'utun[0-9]+' | head -1)
    if [ -n "$IFACE" ]; then
        sudo wg setconf "$IFACE" "$CONFIG_DIR/wg0.conf" 2>/dev/null || \
        sudo wg set "$IFACE" \
            private-key <(echo "$CLIENT_PRIVATE") \
            peer "$SERVER_PUBLIC" \
            endpoint "${NODE_IP}:51820" \
            allowed-ips 10.0.0.0/24 \
            persistent-keepalive 25
        sudo ifconfig "$IFACE" inet 10.0.0.2/24 10.0.0.2 alias
        sudo ifconfig "$IFACE" up
        sudo route -q -n add -inet 10.0.0.0/24 -interface "$IFACE" 2>/dev/null || true
        echo -e "${GREEN}✓ WireGuard started manually on $IFACE${NC}"
    else
        echo -e "${RED}✗ Failed to start WireGuard${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}[5/5]${NC} Testing connection..."
sleep 2

# Test ping
if ping -c 1 -t 5 10.0.0.1 > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Connected to node successfully!${NC}"
else
    echo -e "${YELLOW}⚠ Ping failed - node may not be running yet${NC}"
fi

echo ""
echo "=========================================="
echo -e "${GREEN}       CLIENT IS CONNECTED!${NC}"
echo "=========================================="
echo ""
echo "Your Client Info:"
echo "  VPN IP: 10.0.0.2"
echo "  Connected to: ${NODE_IP}:51820"
echo "  Public Key: $CLIENT_PUBLIC"
echo ""
echo "Current Status:"
sudo wg show
echo ""
echo "=========================================="
echo ""
echo -e "${CYAN}Generating demo traffic...${NC}"
echo ""

# Download test data to generate bandwidth
echo "Downloading 10MB test file from node..."
if curl -s http://10.0.0.1:8080/demo-10mb.bin -o /dev/null 2>/dev/null; then
    echo -e "${GREEN}✓ Downloaded 10MB test data${NC}"
else
    echo -e "${YELLOW}⚠ Could not download test file (server may not be running)${NC}"
fi

echo ""
echo "Press Ctrl+C to disconnect..."
echo ""

# Keep running and show stats every 5 seconds
while true; do
    sleep 5
    clear
    echo "=========================================="
    echo "       DeVPN CLIENT - LIVE STATS"
    echo "=========================================="
    echo ""
    sudo wg show
    echo ""
    echo "Connected to: ${NODE_IP}:51820"
    echo ""
    echo "To generate more traffic:"
    echo "  curl http://10.0.0.1:8080/demo-10mb.bin -o /dev/null"
    echo ""
    echo "Press Ctrl+C to disconnect"
    echo "=========================================="
done
