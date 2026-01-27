<h1 align="center">DeVPN</h1>

<p align="center">
  <strong>Decentralized VPN Protocol on Flare Network</strong>
</p>

<hr>
<img width="1594" height="1196" alt="image" src="https://github.com/user-attachments/assets/39899fee-6928-406b-8a96-40cf5cb47e42" />

<p>
  <strong>DeVPN</strong> is built for users and organizations that need <strong>secure, private, and censorship-resistant internet access</strong> without relying on centralized VPN providers. By leveraging blockchain technology and peer-to-peer networking, DeVPN creates a <strong>trustless, decentralized VPN marketplace</strong> where users pay only for bandwidth consumed and node operators earn rewards for providing reliable service.
</p>

<hr>

<h2> Table of Contents</h2>

<ul>
  <li><a href="#introduction">Introduction</a></li>
  <li><a href="#key-features">Key Features</a></li>
  <li><a href="#architecture">Architecture</a></li>
  <li><a href="#deployed-contracts">Deployed Contracts</a></li>
  <li><a href="#quick-start">Quick Start</a></li>
  <li><a href="#user-guide">User Guide</a></li>
  <li><a href="#node-operator-guide">Node Operator Guide</a></li>
  <li><a href="#network-information">Network Information</a></li>
  <li><a href="#development">Development</a></li>
  <li><a href="#security">Security</a></li>
  <li><a href="#license">License</a></li>
</ul>

<hr>

<h2 id="introduction"> Introduction</h2>

<p>
  DeVPN is a <strong>decentralized VPN protocol</strong> that enables peer-to-peer VPN connections using smart contracts for payments and node discovery. Unlike traditional VPN services that require subscriptions and centralized infrastructure, DeVPN allows users to connect directly to node operators in a <strong>trustless, pay-per-use model</strong>.
</p>

<h3>How It Works</h3>

<ul>
  <li><strong>Users</strong> deposit FLR tokens to start a VPN session, browse nodes by location and price, and only pay for bandwidth actually consumed</li>
  <li><strong>Node Operators</strong> stake FLR tokens to register their VPN nodes, set competitive pricing, and earn rewards based on bandwidth provided</li>
  <li><strong>Smart Contracts</strong> handle all payments atomically, ensuring users receive instant refunds for unused deposits and operators are paid fairly</li>
</ul>

<hr>

<h2 id="key-features"> Key Features</h2>

<ul>
  <li><strong> Decentralized</strong>: No central authority controls the network - users connect directly to node operators</li>
  <li><strong> Pay-per-Use</strong>: Only pay for bandwidth consumed, with automatic refunds for unused deposits</li>
  <li><strong> Instant Settlement</strong>: Single-transaction session settlement eliminates delays and complexity</li>
  <li><strong> Global Network</strong>: Browse and connect to nodes worldwide based on location and pricing</li>
  <li><strong> Reputation System</strong>: Node operators maintain uptime scores and reputation metrics</li>
  <li><strong> Real-time Pricing</strong>: FLR/USD price feeds via Flare FTSO ensure fair, market-based pricing</li>
  <li><strong> WireGuard Integration</strong>: Industry-standard VPN protocol for secure, high-performance connections</li>
  <li><strong> Cross-Platform Desktop App</strong>: Native desktop application built with Tauri (Rust + React)</li>
</ul>

<hr>

<h2 id="architecture"> Architecture</h2>

<h3>Smart Contracts</h3>

<h4>DeVPNNodeRegistry</h4>
<p>Manages the entire lifecycle of VPN nodes:</p>
<ul>
  <li><strong>Node Registration</strong>: Operators register nodes with endpoint, WireGuard public key, location, and pricing</li>
  <li><strong>Staking Mechanism</strong>: Minimum stake requirement (<strong>1000 FLR</strong>) ensures operator commitment</li>
  <li><strong>Status Management</strong>: Nodes transition through states (<code>Pending → Active → Suspended/Unstaking</code>)</li>
  <li><strong>Uptime Tracking</strong>: Heartbeat system monitors node availability and calculates uptime scores</li>
  <li><strong>Price Calculation</strong>: Integrates with Flare FTSO to convert USD pricing to FLR tokens dynamically</li>
  <li><strong>Bandwidth Tracking</strong>: Records total bandwidth served per node for reputation metrics</li>
</ul>

<h4>DeVPNEscrowSimple</h4>
<p>Handles trustless payment settlement between users and node operators:</p>
<ul>
  <li><strong>Session Management</strong>: Creates and tracks VPN sessions with unique session IDs</li>
  <li><strong>Atomic Settlement</strong>: Single-transaction payment settlement when sessions end</li>
  <li><strong>Automatic Refunds</strong>: Unused deposits automatically returned to users</li>
  <li><strong>Protocol Fees</strong>: <strong>5%</strong> protocol fee supports network maintenance and development</li>
  <li><strong>Dispute Resolution</strong>: Built-in dispute mechanism for resolving payment conflicts</li>
  <li><strong>Force Settlement</strong>: Node operators can force-settle abandoned sessions after timeout</li>
  <li><strong>Session Expiration</strong>: Automatic expiration and full refund after <strong>24 hours</strong></li>
</ul>

<h3>Desktop Application</h3>

<p>Built with <strong>Tauri</strong> (Rust + React) for native performance and security:</p>

<ul>
  <li><strong>Client Mode</strong>: Browse nodes, connect to VPN, track bandwidth usage, manage sessions</li>
  <li><strong>Node Mode</strong>: Register nodes, configure WireGuard, monitor connections, withdraw earnings</li>
  <li><strong>Wallet Integration</strong>: MetaMask and WalletConnect support for seamless blockchain interactions</li>
  <li><strong>Real-time Monitoring</strong>: Live bandwidth tracking and connection status updates</li>
  <li><strong>Cross-platform</strong>: macOS, Linux, and Windows support</li>
</ul>

<hr>

<h2 id="deployed-contracts"> Deployed Contracts</h2>

<h3>Coston2 Testnet Deployment</h3>

<table>
  <thead>
    <tr>
      <th>Contract</th>
      <th>Address</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>NodeRegistry</strong></td>
      <td><code>0x4Dda664964b91F9247a2344d3ea2BE8485c8b74b</code></td>
      <td>Manages VPN node registration, staking, and reputation</td>
    </tr>
    <tr>
      <td><strong>EscrowSimple</strong></td>
      <td><code>0xBB2C060D38a148D9bE5a207f6a247268953ACA37</code></td>
      <td>Handles session payments with atomic settlement</td>
    </tr>
  </tbody>
</table>

<h3>Deployment Details</h3>

<ul>
  <li><strong>Network</strong>: <span style="color: #4CAF50;">Coston2 Testnet</span></li>
  <li><strong>Chain ID</strong>: <code>114</code></li>
  <li><strong>Deployer</strong>: <code>0x1C1c93aD480b748DDfbD47B849d5654996DEda60</code></li>
  <li><strong>Deployment Date</strong>: <strong>January 22, 2026</strong></li>
  <li><strong>RPC Endpoint</strong>: <code>https://coston2-api.flare.network/ext/C/rpc</code></li>
  <li><strong>Block Explorer</strong>: <a href="https://coston2-explorer.flare.network" target="_blank">https://coston2-explorer.flare.network</a></li>
</ul>

<h3>Contract Interaction</h3>

<p>You can interact with these contracts using:</p>
<ul>
  <li><strong>Block Explorer</strong>: <a href="https://coston2-explorer.flare.network" target="_blank">Coston2 Explorer</a></li>
  <li><strong>Web3 Wallet</strong>: MetaMask or any EVM-compatible wallet</li>
  <li><strong>DeVPN Desktop App</strong>: Native application with built-in contract integration</li>
</ul>

<hr>

<h2 id="quick-start">⚡ Quick Start</h2>

<h3>Prerequisites</h3>

<ul>
  <li><a href="https://book.getfoundry.sh/getting-started/installation" target="_blank"><strong>Foundry</strong></a> - For smart contract development</li>
  <li><a href="https://nodejs.org/" target="_blank"><strong>Node.js</strong></a> v18+ - For frontend development</li>
  <li><a href="https://rustup.rs/" target="_blank"><strong>Rust</strong></a> - For Tauri backend</li>
  <li><a href="https://metamask.io/" target="_blank"><strong>MetaMask</strong></a> or compatible Web3 wallet</li>
</ul>

<h3>Installation</h3>

<ol>
  <li>
    <p><strong>Clone the repository</strong></p>
    <pre><code>git clone &lt;repository-url&gt;
cd DEVPN</code></pre>
  </li>
  <li>
    <p><strong>Install dependencies</strong></p>
    <pre><code># Install contract dependencies
npm install

# Install app dependencies
cd app
npm install</code></pre>
  </li>
  <li>
    <p><strong>Configure environment</strong></p>
    <pre><code>cp .env.example .env
# Add your PRIVATE_KEY to .env for contract deployment</code></pre>
  </li>
</ol>

<h3>Deploy Contracts</h3>

<p>Deploy to Coston2 Testnet:</p>

<pre><code>forge script script/DeployEscrowSimple.s.sol \
  --rpc-url https://coston2-api.flare.network/ext/C/rpc \
  --broadcast \
  --legacy</code></pre>

<h3>Run Desktop Application</h3>

<p><strong>Start the development server:</strong></p>

<pre><code>cd app
npm run tauri dev</code></pre>

<p><strong>Build for production:</strong></p>

<pre><code>npm run tauri build</code></pre>

<hr>

<h2 id="user-guide">👤 User Guide</h2>

<h3>Getting Started as a User</h3>

<ol>
  <li>
    <p><strong>Connect Wallet</strong></p>
    <ul>
      <li>Launch the DeVPN desktop application</li>
      <li>Connect your MetaMask or WalletConnect wallet</li>
      <li>Ensure you're on <strong>Coston2 Testnet</strong> (Chain ID: <code>114</code>)</li>
    </ul>
  </li>
  <li>
    <p><strong>Browse Available Nodes</strong></p>
    <ul>
      <li>View nodes sorted by location, price, and uptime</li>
      <li>Filter by country/region</li>
      <li>Check node statistics (bandwidth served, uptime score, pricing)</li>
    </ul>
  </li>
  <li>
    <p><strong>Start a VPN Session</strong></p>
    <ul>
      <li>Select a node that meets your needs</li>
      <li>Deposit FLR tokens (minimum <strong>0.1 FLR</strong>)</li>
      <li>Your WireGuard keys are automatically generated</li>
      <li>Session starts immediately upon deposit</li>
    </ul>
  </li>
  <li>
    <p><strong>Use VPN</strong></p>
    <ul>
      <li>Your connection is encrypted via WireGuard</li>
      <li>Monitor bandwidth usage in real-time</li>
      <li>Track remaining deposit balance</li>
    </ul>
  </li>
  <li>
    <p><strong>End Session</strong></p>
    <ul>
      <li>Disconnect when finished</li>
      <li>Payment is settled automatically based on actual bandwidth used</li>
      <li>Unused deposit is refunded instantly</li>
      <li>Session details are recorded on-chain</li>
    </ul>
  </li>
</ol>

<h3>Session Management</h3>

<ul>
  <li><strong>Active Sessions</strong>: One active session per wallet address</li>
  <li><strong>Session Duration</strong>: Maximum <strong>24 hours</strong> per session</li>
  <li><strong>Automatic Expiration</strong>: Sessions expire after 24 hours with full refund</li>
  <li><strong>Dispute Window</strong>: <strong>1 hour</strong> after settlement to dispute charges</li>
</ul>

<hr>

<h2 id="node-operator-guide">🖥️ Node Operator Guide</h2>

<h3>Becoming a Node Operator</h3>

<ol>
  <li>
    <p><strong>Register Your Node</strong></p>
    <ul>
      <li>Minimum stake: <strong>1000 FLR</strong> tokens</li>
      <li>Provide endpoint (IP:Port or domain)</li>
      <li>Generate WireGuard public key</li>
      <li>Set bandwidth price (USD cents per GB)</li>
      <li>Specify location (ISO country code)</li>
      <li>Set maximum bandwidth capacity</li>
    </ul>
  </li>
  <li>
    <p><strong>Activate Your Node</strong></p>
    <ul>
      <li>Node starts in <code>"Pending"</code> status</li>
      <li>After verification, node becomes <code>"Active"</code></li>
      <li>Active nodes appear in user browsing interface</li>
    </ul>
  </li>
  <li>
    <p><strong>Maintain Your Node</strong></p>
    <ul>
      <li>Submit periodic heartbeats to prove uptime</li>
      <li>Maintain uptime score above <strong>80%</strong> threshold</li>
      <li>Update endpoint, pricing, or capacity as needed</li>
      <li>Monitor active connections and earnings</li>
    </ul>
  </li>
  <li>
    <p><strong>Earn Rewards</strong></p>
    <ul>
      <li>Receive payments automatically when sessions settle</li>
      <li>Earnings accumulate in your node balance</li>
      <li>Withdraw earnings anytime</li>
      <li>Track total bandwidth served and reputation</li>
    </ul>
  </li>
</ol>

<h3>Node Requirements</h3>

<ul>
  <li><strong>Stake</strong>: Minimum <strong>1000 FLR</strong> (can increase stake anytime)</li>
  <li><strong>Uptime</strong>: Maintain <strong>80%+</strong> uptime score</li>
  <li><strong>Infrastructure</strong>: Reliable server with WireGuard support</li>
  <li><strong>Bandwidth</strong>: Sufficient capacity for expected load</li>
</ul>

<h3>Unstaking Process</h3>

<ol>
  <li>Initiate unstaking (node becomes inactive)</li>
  <li>Wait <strong>30-day</strong> lock period</li>
  <li>Withdraw staked tokens</li>
  <li>Node is removed from active registry</li>
</ol>

<hr>

<h2 id="network-information"> Network Information</h2>

<h3>Coston2 Testnet</h3>

<ul>
  <li><strong>Network Name</strong>: <span style="color: #2196F3;">Coston2 Testnet</span></li>
  <li><strong>Chain ID</strong>: <code>114</code></li>
  <li><strong>RPC URL</strong>: <code>https://coston2-api.flare.network/ext/C/rpc</code></li>
  <li><strong>Block Explorer</strong>: <a href="https://coston2-explorer.flare.network" target="_blank">https://coston2-explorer.flare.network</a></li>
  <li><strong>Faucet</strong>: <a href="https://faucet.flare.network/coston2" target="_blank">https://faucet.flare.network/coston2</a></li>
  <li><strong>Native Token</strong>: <strong>C2FLR</strong> (Coston2 Flare)</li>
</ul>

<h3>Flare Network Features</h3>

<ul>
  <li><strong>FTSO Integration</strong>: Real-time price feeds for FLR/USD conversion</li>
  <li><strong>EVM Compatible</strong>: Full Ethereum Virtual Machine compatibility</li>
  <li><strong>Low Fees</strong>: Cost-effective transactions for micro-payments</li>
  <li><strong>Fast Finality</strong>: Quick block confirmation times</li>
</ul>

<hr>

<h2 id="development">💻 Development</h2>

<h3>Project Structure</h3>

<pre><code>DEVPN/
├── src/                          # Solidity smart contracts
│   ├── DeVPNEscrowSimple.sol    # Simplified escrow contract
│   ├── DeVPNnoderegistery.sol    # Node registry contract
│   └── interfaces/               # Contract interfaces
├── script/                       # Foundry deployment scripts
│   ├── DeployEscrowSimple.s.sol # Escrow deployment script
│   └── Deploy.s.sol              # Legacy deployment script
├── test/                         # Foundry test suite
│   └── DeVPNEscrowSimple.t.sol  # Comprehensive contract tests
├── app/                          # Desktop application
│   ├── src/                      # React frontend
│   │   ├── pages/               # Client and Node mode pages
│   │   ├── components/          # UI components
│   │   ├── hooks/               # React hooks
│   │   └── utils/               # Utilities and ABIs
│   └── src-tauri/               # Rust backend
│       ├── src/                 # Rust source files
│       │   ├── wireguard.rs     # WireGuard integration
│       │   ├── tailscale.rs     # Tailscale integration
│       │   └── network.rs       # Network utilities
│       └── tauri.conf.json      # Tauri configuration
├── contracts/                    # Legacy contract files
├── deployed-addresses.json       # Deployment addresses
├── foundry.toml                  # Foundry configuration
└── package.json                  # Node.js dependencies</code></pre>

<h3>Testing</h3>

<p><strong>Run smart contract tests:</strong></p>

<pre><code>forge test</code></pre>

<p><strong>Run with verbose output:</strong></p>

<pre><code>forge test -vvv</code></pre>

<h3>Building</h3>

<p><strong>Build the desktop application:</strong></p>

<pre><code>cd app
npm run build
npm run tauri build</code></pre>

<h3>Development Workflow</h3>

<ol>
  <li><strong>Smart Contracts</strong>: Develop and test in <code>src/</code>, deploy with <code>script/</code></li>
  <li><strong>Frontend</strong>: React app in <code>app/src/</code> with TypeScript</li>
  <li><strong>Backend</strong>: Rust code in <code>app/src-tauri/src/</code> for system integration</li>
  <li><strong>Testing</strong>: Comprehensive Foundry tests in <code>test/</code></li>
</ol>

<hr>

<h2 id="security"> Security</h2>

<h3>Current Status</h3>

<p>
  <strong style="color: #FF9800;"> This is experimental software deployed on testnet only. Use at your own risk.</strong>
</p>

<h3>Security Considerations</h3>

<ul>
  <li><strong>Testnet Deployment</strong>: Currently deployed on Coston2 testnet for testing purposes</li>
  <li><strong>Smart Contract Audits</strong>: Contracts have not undergone formal security audits</li>
  <li><strong>Experimental Features</strong>: Some features may be experimental or subject to change</li>
  <li><strong>User Responsibility</strong>: Users should verify all transactions and understand risks</li>
</ul>

<h3>Best Practices</h3>

<ul>
  <li>Always verify contract addresses before interacting</li>
  <li>Start with small deposits to test functionality</li>
  <li>Monitor your sessions and bandwidth usage</li>
  <li>Report any security issues responsibly</li>
</ul>

<h3>Known Limitations</h3>

<ul>
  <li>Dispute resolution currently requires manual intervention</li>
  <li>Node activation requires admin/oracle verification (to be decentralized)</li>
  <li>Some features may be restricted in testnet environment</li>
</ul>

<hr>

<h2 id="license">📄 License</h2>

<p>This project is licensed under the <strong>MIT License</strong> - see the LICENSE file for details.</p>

<hr>

<h2>🤝 Contributing</h2>

<p>Contributions are welcome! Please feel free to submit a Pull Request.</p>

<hr>

<h2>💬 Support</h2>

<p>For issues, questions, or contributions:</p>
<ul>
  <li>Open an issue on GitHub</li>
  <li>Check the documentation</li>
  <li>Review the smart contract code and tests</li>
</ul>

<hr>

<p align="center">
  <strong>Built with ❤️ on Flare Network</strong>
</p>
