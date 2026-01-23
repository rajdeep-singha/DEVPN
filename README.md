# DeVPN

A decentralized VPN protocol built on Flare Network with WireGuard integration.

## Overview

DeVPN enables peer-to-peer VPN connections using smart contracts for payments and node discovery. Node operators stake FLR tokens and earn rewards for providing bandwidth, while users pay per GB consumed.

## Architecture

### Smart Contracts

- **NodeRegistry**: Manages VPN node registration, staking, and reputation
- **Escrow**: Handles session payments with atomic settlement
- **StateConnector** (optional): Cross-chain verification support

### Desktop Application

Built with Tauri (Rust + React):
- WireGuard tunnel management
- MetaMask/WalletConnect integration
- Real-time bandwidth tracking
- Cross-platform (macOS, Linux, Windows)

## Features

- **Decentralized**: No central authority controls the network
- **Pay-per-use**: Only pay for bandwidth consumed
- **Instant refunds**: Unused deposits returned automatically
- **Reputation system**: Rate nodes for quality of service
- **Real-time pricing**: FLR/USD price feeds via Flare FTSO

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/) v18+
- [Rust](https://rustup.rs/)

### Deploy Contracts

```bash
cp .env.example .env
# Add PRIVATE_KEY to .env

forge script script/DeployEscrowSimple.s.sol \
  --rpc-url https://coston2-api.flare.network/ext/C/rpc \
  --broadcast \
  --legacy
```

### Run Client App

```bash
cd app
npm install
npm run tauri dev
```

## Node Operator Guide

1. Register node with minimum stake (10 FLR)
2. Set bandwidth pricing (FLR per GB)
3. Configure WireGuard endpoint
4. Activate node to accept connections
5. Withdraw earnings anytime

## User Guide

1. Connect wallet
2. Browse nodes by location and price
3. Deposit FLR to start session
4. Connect VPN and browse securely
5. Disconnect to settle payment and receive refund

## Network

**Testnet**: Coston2 (Chain ID: 114)
**RPC**: https://coston2-api.flare.network/ext/C/rpc
**Explorer**: https://coston2-explorer.flare.network
**Faucet**: https://faucet.flare.network/coston2

## Development

### Project Structure

```
├── src/                    # Solidity contracts
├── script/                 # Deployment scripts
├── test/                   # Contract tests
├── app/
│   ├── src/                # React frontend
│   └── src-tauri/          # Rust backend
└── deployed-addresses.json
```

### Testing

```bash
forge test
cd app && npm run build
```

## Security

This is experimental software. Testnet only. Use at your own risk.

## License

MIT
