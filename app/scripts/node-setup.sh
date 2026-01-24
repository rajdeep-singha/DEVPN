#!/bin/bash

# DeVPN Node Setup Script - Auto-run version
# This script sets up WireGuard VPN node with all error handling

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo ""
echo "=========================================="
echo "       DeVPN NODE SETUP"
echo "=========================================="
echo ""

# Get password upfront
echo "Enter your laptop password to setup VPN node:"
sudo -v || { echo -e "${RED}Password required. Exiting.${NC}"; exit 1; }

# Keep sudo alive in background
( while true; do sudo -n true; sleep 50; done ) &
SUDO_PID=$!
trap "kill $SUDO_PID 2>/dev/null" EXIT

echo ""
echo -e "${GREEN}[1/6]${NC} Disabling firewall..."
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off 2>/dev/null || true

echo -e "${GREEN}[2/6]${NC} Stopping existing WireGuard..."
sudo wg-quick down wg0 2>/dev/null || true
sudo wg-quick down /etc/wireguard/wg0.conf 2>/dev/null || true
sudo wg-quick down /opt/homebrew/etc/wireguard/wg0.conf 2>/dev/null || true

# Kill any existing wireguard-go processes
sudo pkill -f wireguard-go 2>/dev/null || true
sleep 1

echo -e "${GREEN}[3/6]${NC} Creating WireGuard config..."

# Determine config directory
if [ -d "/opt/homebrew/etc" ]; then
    CONFIG_DIR="/opt/homebrew/etc/wireguard"
else
    CONFIG_DIR="/etc/wireguard"
fi
sudo mkdir -p "$CONFIG_DIR"

# Get local IP for endpoint
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr bridge100 2>/dev/null || echo "10.0.0.1")

# Server keys - YOUR laptop
SERVER_PRIVATE="KC2zNfRGP0hM9A7GDSMfKqlMrqR+E4EVDQf1Usd7RFo="
SERVER_PUBLIC="cxQI5Fo41hUTcAEpH/uPaKqO7+xsjXd9D6WYz+0ySxI="
CLIENT_PUBLIC="e6/0jubRkV9t459F3tPKZ4mG00H7DlAzW/aWZrRIw1k="

# Write config
sudo tee "$CONFIG_DIR/wg0.conf" > /dev/null << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE
Address = 10.0.0.1/24
ListenPort = 51820

[Peer]
PublicKey = $CLIENT_PUBLIC
AllowedIPs = 10.0.0.2/32
EOF

sudo chmod 600 "$CONFIG_DIR/wg0.conf"

echo -e "${GREEN}[4/6]${NC} Enabling IP forwarding..."
sudo sysctl -w net.inet.ip.forwarding=1 > /dev/null 2>&1 || true

echo -e "${GREEN}[5/6]${NC} Setting up NAT..."
sudo pfctl -e 2>/dev/null || true
echo "nat on en0 from 10.0.0.0/24 to any -> (en0)" | sudo pfctl -f - 2>/dev/null || true

echo -e "${GREEN}[6/6]${NC} Starting WireGuard..."

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
            private-key <(echo "$SERVER_PRIVATE") \
            listen-port 51820 \
            peer "$CLIENT_PUBLIC" \
            allowed-ips 10.0.0.2/32
        sudo ifconfig "$IFACE" inet 10.0.0.1/24 10.0.0.1 alias
        sudo ifconfig "$IFACE" up
        sudo route -q -n add -inet 10.0.0.2/32 -interface "$IFACE" 2>/dev/null || true
        echo -e "${GREEN}✓ WireGuard started manually on $IFACE${NC}"
    else
        echo -e "${RED}✗ Failed to start WireGuard${NC}"
        exit 1
    fi
fi

echo ""
echo "=========================================="
echo -e "${GREEN}       NODE IS RUNNING!${NC}"
echo "=========================================="
echo ""
echo "Your Node Info:"
echo "  VPN IP: 10.0.0.1"
echo "  Local IP: $LOCAL_IP"
echo "  Listen Port: 51820"
echo "  Public Key: $SERVER_PUBLIC"
echo ""
echo "Current Status:"
sudo wg show
echo ""
echo "=========================================="

# Start demo data server in background
echo ""
echo "Starting demo data server on 10.0.0.1:8080..."
cd /tmp
echo "DeVPN Demo Server - Data transfer test file" > demo.txt
dd if=/dev/urandom of=demo-10mb.bin bs=1M count=10 2>/dev/null
python3 -m http.server 8080 --bind 10.0.0.1 &
HTTP_PID=$!
echo -e "${GREEN}✓ Demo server running (PID: $HTTP_PID)${NC}"
echo ""
echo "Client can download test data with:"
echo "  curl http://10.0.0.1:8080/demo-10mb.bin -o /dev/null"
echo ""
echo "Press Ctrl+C to stop node..."

# Keep running and show stats every 5 seconds
while true; do
    sleep 5
    clear
    echo "=========================================="
    echo "       DeVPN NODE - LIVE STATS"
    echo "=========================================="
    echo ""
    sudo wg show
    echo ""
    echo "Demo server: http://10.0.0.1:8080"
    echo "Press Ctrl+C to stop"
    echo "=========================================="
done
