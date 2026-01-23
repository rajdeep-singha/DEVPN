#!/bin/bash

# DeVPN Traffic Generator - Generate demo bandwidth
# Run on CLIENT laptop to generate traffic for escrow demo

echo "=========================================="
echo "       DeVPN TRAFFIC GENERATOR"
echo "=========================================="
echo ""

NODE_IP="10.0.0.1"
TOTAL_MB=0

echo "Generating traffic to show in escrow..."
echo ""

# Download test files multiple times
for i in {1..5}; do
    echo "Download $i/5: Fetching 10MB..."
    if curl -s http://${NODE_IP}:8080/demo-10mb.bin -o /dev/null 2>/dev/null; then
        TOTAL_MB=$((TOTAL_MB + 10))
        echo "  ✓ Downloaded (Total: ${TOTAL_MB}MB)"
    else
        echo "  ✗ Failed - is node running?"
    fi
    sleep 1
done

echo ""
echo "=========================================="
echo "Traffic generated: ${TOTAL_MB}MB"
echo ""
echo "Check WireGuard stats:"
sudo wg show | grep transfer
echo "=========================================="
