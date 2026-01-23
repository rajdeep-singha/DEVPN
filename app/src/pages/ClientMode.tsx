import { useState, useEffect, useCallback, useMemo } from "react";
import { Contract, JsonRpcProvider } from "ethers";
import {
  formatFLR,
  parseFLR,
  formatBytes,
  Node,
  Session,
  SessionStatus,
  getCountryFlag,
  NODE_REGISTRY_ABI,
  NODE_REGISTRY_ADDRESS,
  ESCROW_ABI,
  ESCROW_ADDRESS,
  NETWORK_CONFIG,
} from "../utils/contract";
import {
  connectVpn,
  disconnectVpn,
  getWgKeys,
  getVpnStatus,
  isTauri,
  VpnStatus,
  tailscaleStatus,
  tailscaleSetupClient,
  tailscaleConnectExitNode,
  tailscaleDisconnectExitNode,
  TailscaleStatus,
  setupWgClient,
  getWgLiveStats,
  WgLiveStats,
} from "../utils/tauri";

interface WalletState {
  isConnected: boolean;
  address: string | null;
  balance: string;
  chainId: number | null;
  isCorrectNetwork: boolean;
  connectionType: "metamask" | "walletconnect" | null;
}

interface ClientModeProps {
  onBack: () => void;
  wallet: WalletState;
  contract: Contract | null; // This is the signer-connected registry contract
  escrowContract: Contract | null; // Signer-connected escrow contract
}

type ClientView = "loading" | "list" | "connect" | "connected";

// Create stable read-only providers
const rpcProvider = new JsonRpcProvider(NETWORK_CONFIG.rpcUrls[0]);

function ClientMode({ onBack, wallet, contract: _registryContract, escrowContract }: ClientModeProps) {

  const [view, setView] = useState<ClientView>("loading");
  const [nodes, setNodes] = useState<Node[]>([]);
  const [selectedNode, setSelectedNode] = useState<Node | null>(null);
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null); // bytes32 nodeId
  const [activeSession, setActiveSession] = useState<Session | null>(null);
  const [depositAmount, setDepositAmount] = useState("5");
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [nodesLoading, setNodesLoading] = useState(true);
  const [vpnStatus, setVpnStatus] = useState<VpnStatus | null>(null);
  const [hasActiveSession, setHasActiveSession] = useState(false);

  // VPN state
  const [tailscale, setTailscale] = useState<TailscaleStatus | null>(null);
  const [useTailscale, setUseTailscale] = useState(true);

  // WireGuard live stats
  const [wgLiveStats, setWgLiveStats] = useState<WgLiveStats | null>(null);
  const [wgSetupStatus, setWgSetupStatus] = useState<string | null>(null);

  // Simulated traffic for escrow testing
  const [simulatedBytes, setSimulatedBytes] = useState<bigint>(0n);

  // Create stable read-only contracts using useMemo
  const readOnlyRegistry = useMemo(() => {
    return new Contract(NODE_REGISTRY_ADDRESS, NODE_REGISTRY_ABI, rpcProvider);
  }, []);

  const readOnlyEscrow = useMemo(() => {
    return new Contract(ESCROW_ADDRESS, ESCROW_ABI, rpcProvider);
  }, []);

  // Fetch active nodes from registry
  const fetchNodes = useCallback(async () => {
    try {
      console.log("Fetching active nodes from Coston2...");
      setNodesLoading(true);

      const activeNodes = await readOnlyRegistry.getActiveNodes();
      console.log("Fetched nodes:", activeNodes.length);
      setNodes(activeNodes);
      setNodesLoading(false);
      if (view === "loading") {
        setView("list");
      }
    } catch (err) {
      console.error("Error fetching nodes:", err);
      setError("Failed to fetch nodes. Check network connection.");
      setNodesLoading(false);
      if (view === "loading") {
        setView("list");
      }
    }
  }, [view, readOnlyRegistry]);

  useEffect(() => {
    fetchNodes();
    const interval = setInterval(fetchNodes, 30000);
    return () => clearInterval(interval);
  }, [fetchNodes]);

  // Check for active session using escrow contract
  useEffect(() => {
    const checkActiveSession = async () => {
      if (!wallet.address) return;

      try {
        const [hasActive, sessionId] = await readOnlyEscrow.hasActiveSession(wallet.address);

        if (hasActive && sessionId > 0n) {
          const session = await readOnlyEscrow.getSession(sessionId);
          if (Number(session.status) === SessionStatus.Active) {
            setActiveSession(session);
            setHasActiveSession(true);
            setSelectedNodeId(session.nodeId);

            // Get node info
            const node = await readOnlyRegistry.getNodeInfo(session.nodeId);
            setSelectedNode(node);
            setView("connected");
          } else {
            setHasActiveSession(false);
          }
        } else {
          setHasActiveSession(false);
        }
      } catch (err) {
        console.error("Error checking session:", err);
        setHasActiveSession(false);
      }
    };

    checkActiveSession();
  }, [wallet.address, readOnlyEscrow, readOnlyRegistry]);

  // Check Tailscale status on mount
  useEffect(() => {
    const checkTailscale = async () => {
      if (!isTauri()) return;

      try {
        const status = await tailscaleStatus();
        setTailscale(status);
      } catch (err) {
        console.error("Error checking Tailscale:", err);
      }
    };

    checkTailscale();
  }, []);

  // Poll VPN status when connected
  useEffect(() => {
    if (view !== "connected" || !isTauri()) return;

    const pollStatus = async () => {
      try {
        const status = await getVpnStatus();
        setVpnStatus(status);

        // Also check Tailscale status
        if (useTailscale) {
          const tsStatus = await tailscaleStatus();
          setTailscale(tsStatus);
        }

        // Get WireGuard live stats
        if (!useTailscale) {
          try {
            const stats = await getWgLiveStats();
            setWgLiveStats(stats);
          } catch {
            // WG stats not available
          }
        }
      } catch (err) {
        console.error("Error getting VPN status:", err);
      }
    };

    pollStatus();
    const interval = setInterval(pollStatus, 2000);

    return () => clearInterval(interval);
  }, [view, useTailscale]);

  // Setup VPN for client connection
  const handleTailscaleSetup = async (exitNodeIp: string) => {
    if (!isTauri()) {
      setError("VPN setup requires the desktop app");
      return false;
    }

    setError("Setting up VPN... This may open a browser for authentication.");

    try {
      const status = await tailscaleSetupClient(exitNodeIp);
      setTailscale(status);

      if (status.authenticated && status.exit_node_active) {
        setError(null);
        return true;
      } else {
        setError("VPN setup incomplete. Please connect manually: tailscale up --exit-node=" + exitNodeIp);
        return false;
      }
    } catch (err) {
      console.error("VPN setup error:", err);
      setError("Please connect manually: tailscale up --exit-node=" + exitNodeIp);
      return false;
    }
  };

  // Start session using escrow contract
  const handleConnect = async () => {
    if (!escrowContract || !selectedNode || !selectedNodeId) return;

    // Check network before transaction
    if (!wallet.isCorrectNetwork) {
      setError("Wrong network! Please switch to Coston2 (Chain ID: 114) in your wallet");
      return;
    }

    if (hasActiveSession) {
      setError("You already have an active session. Disconnect first.");
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      // Double-check no active session exists
      const [hasActive] = await readOnlyEscrow.hasActiveSession(wallet.address);
      if (hasActive) {
        setError("You already have an active session. Please disconnect first.");
        setIsLoading(false);
        return;
      }

      // Get our WireGuard public key
      let userWgPubKey: string;

      if (isTauri()) {
        const keys = await getWgKeys();
        userWgPubKey = keys.public_key;
      } else {
        userWgPubKey = "user-wg-" + Math.random().toString(36).substring(2, 15);
      }

      setError("Approve transaction in wallet...");

      // Start session on escrow contract with bytes32 nodeId
      const tx = await escrowContract.startSession(selectedNodeId, userWgPubKey, {
        value: parseFLR(depositAmount),
      });

      setError("Waiting for confirmation...");
      await tx.wait();

      // Connect to VPN
      if (isTauri()) {
        try {
          // Extract exit node IP from endpoint (format: "100.x.x.x:51820")
          const exitNodeIp = selectedNode.endpoint.split(":")[0];

          // Check if endpoint looks like a VPN network IP (100.x.x.x range)
          const isVpnNetworkEndpoint = exitNodeIp.startsWith("100.");

          if (useTailscale && isVpnNetworkEndpoint) {
            // Use VPN network to connect
            setError("Connecting to VPN...");

            // Check if VPN is set up
            if (!tailscale?.authenticated) {
              const success = await handleTailscaleSetup(exitNodeIp);
              if (!success) {
                throw new Error("VPN setup failed");
              }
            } else {
              // Already authenticated, just connect to exit node
              await tailscaleConnectExitNode(exitNodeIp);
            }

            // Refresh VPN status
            const tsStatus = await tailscaleStatus();
            setTailscale(tsStatus);
            console.log("Connected to VPN node:", exitNodeIp);
          } else {
            // Use WireGuard directly (for direct endpoints)
            setUseTailscale(false);
            setWgSetupStatus("Setting up WireGuard client...");

            // Use the new auto-setup function with demo node public key
            const nodePubkey = selectedNode.publicKey || "cxQI5Fo41hUTcAEpH/uPaKqO7+xsjXd9D6WYz+0ySxI=";
            try {
              const result = await setupWgClient(exitNodeIp, nodePubkey);
              console.log("WireGuard client setup result:", result);
              setWgSetupStatus("WireGuard connected!");
            } catch (wgErr) {
              console.warn("Auto WireGuard setup failed, trying fallback:", wgErr);
              // Fallback to connectVpn
              await connectVpn(selectedNode.endpoint, selectedNode.publicKey);
            }
            console.log("VPN connected via WireGuard to", selectedNode.endpoint);
          }
        } catch (vpnErr) {
          console.warn("VPN connection failed:", vpnErr);
          // Session is still active even if VPN connection fails
          setError("Session started but VPN connection failed. Try reconnecting.");
        }
      }

      // Get the session
      const activeSessionId = await readOnlyEscrow.activeSessionId(wallet.address);
      const session = await readOnlyEscrow.getSession(activeSessionId);
      setActiveSession(session);
      setHasActiveSession(true);
      setError(null);
      setView("connected");
    } catch (err) {
      console.error("Error starting session:", err);
      const errMsg = err instanceof Error ? err.message : "Failed to start session";
      if (errMsg.includes("user rejected")) {
        setError("Transaction rejected. Please approve in wallet.");
      } else {
        setError(errMsg);
      }
    } finally {
      setIsLoading(false);
    }
  };

  // End session and settle in one transaction
  const handleDisconnect = async () => {
    if (!escrowContract || !activeSession) return;

    setIsLoading(true);
    setError(null);

    // Check network before transaction
    if (!wallet.isCorrectNetwork) {
      setError("Wrong network! Please switch to Coston2 (Chain ID: 114) in your wallet");
      setIsLoading(false);
      return;
    }

    try {
      // Check current session status
      const currentSession = await readOnlyEscrow.getSession(activeSession.id);
      const currentStatus = Number(currentSession.status);

      // If already settled, just clean up
      if (currentStatus === SessionStatus.Settled || currentStatus === SessionStatus.Expired) {
        setError("Session already completed. Cleaning up...");

        if (isTauri()) {
          try {
            if (useTailscale && tailscale?.exit_node_active) {
              await tailscaleDisconnectExitNode();
            } else {
              await disconnectVpn();
            }
          } catch (vpnErr) {
            console.warn("VPN disconnect failed:", vpnErr);
          }
        }

        setActiveSession(null);
        setSelectedNode(null);
        setSelectedNodeId(null);
        setHasActiveSession(false);
        setVpnStatus(null);
        setWgLiveStats(null);
        setWgSetupStatus(null);
        setError(null);
        setView("list");
        setIsLoading(false);
        return;
      }

      // Disconnect VPN first
      if (isTauri()) {
        try {
          if (useTailscale && tailscale?.exit_node_active) {
            await tailscaleDisconnectExitNode();
            const tsStatus = await tailscaleStatus();
            setTailscale(tsStatus);
            console.log("Disconnected from VPN node");
          } else {
            await disconnectVpn();
            console.log("VPN disconnected");
          }
        } catch (vpnErr) {
          console.warn("VPN disconnect failed:", vpnErr);
        }
      }

      // Calculate bytes used (real WG stats, simulated, or minimum)
      const wgBytes = wgLiveStats?.peers?.[0]
        ? BigInt(wgLiveStats.peers[0].transfer_tx + wgLiveStats.peers[0].transfer_rx)
        : 0n;
      const bytesUsed = wgBytes > 0n ? wgBytes : simulatedBytes > 0n ? simulatedBytes : BigInt(1024 * 1024); // Min 1 MB

      // Single transaction - end and settle atomically
      setError("Settling session... Approve in wallet");
      const tx = await escrowContract.endSessionAndSettle(activeSession.id, bytesUsed);

      setError("Waiting for confirmation...");
      await tx.wait();

      // Reset state
      setActiveSession(null);
      setSelectedNode(null);
      setSelectedNodeId(null);
      setHasActiveSession(false);
      setVpnStatus(null);
      setWgLiveStats(null);
      setWgSetupStatus(null);
      setSimulatedBytes(0n);
      setError(null);
      setView("list");
    } catch (err) {
      console.error("Error ending session:", err);
      const errMsg = err instanceof Error ? err.message : "Failed to end session";
      if (errMsg.includes("user rejected")) {
        setError("Transaction rejected. Please approve in wallet.");
      } else {
        setError(errMsg);
      }
    } finally {
      setIsLoading(false);
    }
  };

  // Loading View
  if (view === "loading") {
    return (
      <div className="container">
        <header className="header">
          <button className="btn btn-outline" onClick={onBack}>
            ← Back
          </button>
          <div className="logo">VPN Nodes</div>
          <div className="wallet-info">
            <span className="wallet-balance">{parseFloat(wallet.balance).toFixed(4)} FLR</span>
          </div>
        </header>

        <div className="card" style={{ textAlign: "center", padding: "60px 24px" }}>
          <div className="spinner" style={{ margin: "0 auto 24px" }}></div>
          <h3>Loading VPN Nodes...</h3>
          <p className="text-muted">Fetching available nodes from blockchain</p>
        </div>
      </div>
    );
  }

  // Node List View
  if (view === "list") {
    return (
      <div className="container">
        <header className="header">
          <button className="btn btn-outline" onClick={onBack}>
            ← Back
          </button>
          <div className="logo">VPN Nodes</div>
          <div className="wallet-info">
            <span className="wallet-balance">{parseFloat(wallet.balance).toFixed(4)} FLR</span>
          </div>
        </header>

        {error && (
          <div className="alert alert-error" onClick={() => setError(null)} style={{ cursor: "pointer" }}>
            {error} (tap to dismiss)
          </div>
        )}

        <div className="card">
          <div className="flex justify-between items-center mb-4">
            <h3>Available Nodes ({nodes.length})</h3>
            <button className="btn btn-outline" onClick={fetchNodes} disabled={nodesLoading} style={{ padding: "8px 16px" }}>
              {nodesLoading ? "Loading..." : "Refresh"}
            </button>
          </div>

          {nodesLoading ? (
            <div className="text-center" style={{ padding: "40px" }}>
              <div className="spinner" style={{ margin: "0 auto" }}></div>
            </div>
          ) : nodes.length === 0 ? (
            <div className="text-center text-muted" style={{ padding: "40px" }}>
              <p>No nodes available yet.</p>
              <p className="text-sm">Be the first to run a node!</p>
            </div>
          ) : (
            <div className="node-list">
              {nodes.map((node, index) => {
                const isTailscaleNode = node.endpoint.split(":")[0].startsWith("100.");
                return (
                  <div
                    key={index}
                    className="node-item"
                    onClick={() => {
                      setSelectedNode(node);
                      // Get the nodeId from the allNodeIds array
                      readOnlyRegistry.getActiveNodeIds().then((ids: string[]) => {
                        if (ids[index]) {
                          setSelectedNodeId(ids[index]);
                        }
                      });
                      setView("connect");
                    }}
                  >
                    <div className="node-info">
                      <span className="node-flag">{getCountryFlag(node.location)}</span>
                      <div className="node-details">
                        <div style={{ display: "flex", alignItems: "center", gap: "6px" }}>
                          <h4>{node.location}-{node.id.toString().slice(0, 6)}</h4>
                          {isTailscaleNode && (
                            <span style={{ fontSize: "9px", background: "var(--success)", color: "white", padding: "1px 4px", borderRadius: "3px" }}>
                              P2P
                            </span>
                          )}
                        </div>
                        <span>
                          {"*".repeat(Math.floor(Number(node.rating) / 100))}
                          {"-".repeat(5 - Math.floor(Number(node.rating) / 100))}
                          {node.ratingCount > 0n && ` (${(Number(node.rating) / 100).toFixed(1)})`}
                        </span>
                      </div>
                    </div>
                    <div className="node-price">
                      <div className="price">{formatFLR(node.bandwidthPrice)}</div>
                      <div className="unit">FLR/GB</div>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>
    );
  }

  // Connect View
  if (view === "connect" && selectedNode) {
    const estimatedGB = parseFloat(depositAmount) / (Number(selectedNode.bandwidthPrice) / 1e18);

    return (
      <div className="container">
        <header className="header">
          <button className="btn btn-outline" onClick={() => setView("list")}>
            ← Back
          </button>
          <div className="logo">Connect to VPN</div>
          <div></div>
        </header>

        {error && (
          <div className="alert alert-error">{error}</div>
        )}

        <div className="card">
          <div className="flex items-center gap-4 mb-4">
            <span style={{ fontSize: "48px" }}>{getCountryFlag(selectedNode.location)}</span>
            <div>
              <h2>{selectedNode.location}-{selectedNode.id.toString().slice(0, 6)}</h2>
              <p className="text-muted">{selectedNode.endpoint}</p>
              {selectedNode.endpoint.split(":")[0].startsWith("100.") && (
                <span style={{ fontSize: "10px", background: "var(--success)", color: "white", padding: "2px 6px", borderRadius: "4px", marginTop: "4px", display: "inline-block" }}>
                  VPN VPN Node
                </span>
              )}
            </div>
          </div>

          <div className="stats-grid" style={{ gridTemplateColumns: "repeat(2, 1fr)" }}>
            <div className="stat-card">
              <div className="stat-value">{formatFLR(selectedNode.bandwidthPrice)}</div>
              <div className="stat-label">FLR per GB</div>
            </div>
            <div className="stat-card">
              <div className="stat-value">
                {"*".repeat(Math.floor(Number(selectedNode.rating) / 100))}
              </div>
              <div className="stat-label">
                Rating ({selectedNode.ratingCount.toString()} reviews)
              </div>
            </div>
          </div>

          {/* VPN Network Status */}
          {selectedNode.endpoint.split(":")[0].startsWith("100.") && (
            <div style={{ marginTop: "16px", padding: "12px", background: "var(--bg-input)", borderRadius: "8px" }}>
              <div style={{ display: "flex", alignItems: "center", gap: "8px", marginBottom: "8px" }}>
                <span>P2P</span>
                <strong style={{ fontSize: "14px" }}>VPN Connection</strong>
              </div>
              {tailscale ? (
                <div style={{ fontSize: "12px" }}>
                  <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
                    <span style={{ color: tailscale.installed ? "var(--success)" : "var(--warning)" }}>
                      {tailscale.installed ? "Y" : "!"}
                    </span>
                    <span>{tailscale.installed ? "VPN Service Installed" : "VPN Service Not Installed"}</span>
                  </div>
                  {tailscale.installed && (
                    <div style={{ display: "flex", alignItems: "center", gap: "4px" }}>
                      <span style={{ color: tailscale.authenticated ? "var(--success)" : "var(--warning)" }}>
                        {tailscale.authenticated ? "Y" : "!"}
                      </span>
                      <span>{tailscale.authenticated ? "Authenticated" : "Not Authenticated"}</span>
                    </div>
                  )}
                </div>
              ) : (
                <p className="text-muted text-sm">VPN will be set up automatically when you connect.</p>
              )}
            </div>
          )}
        </div>

        <div className="card">
          <h3 style={{ marginBottom: "16px" }}>Deposit Amount</h3>

          <input
            type="number"
            className="input"
            step="1"
            min="1"
            value={depositAmount}
            onChange={(e) => setDepositAmount(e.target.value)}
          />

          <div className="flex gap-2 mb-4">
            {["2", "5", "10", "20"].map((amount) => (
              <button
                key={amount}
                className={`btn ${depositAmount === amount ? "btn-primary" : "btn-outline"}`}
                onClick={() => setDepositAmount(amount)}
                style={{ flex: 1, padding: "8px" }}
              >
                {amount} FLR
              </button>
            ))}
          </div>

          <div className="alert alert-success">
            <strong>≈ {estimatedGB.toFixed(1)} GB</strong> of browsing
            <p className="text-sm" style={{ marginTop: "4px", opacity: 0.8 }}>
              Unused balance is refunded when you disconnect
            </p>
          </div>

          <div className="flex justify-between mb-4 mt-4">
            <span className="text-muted">Your Balance:</span>
            <span>{parseFloat(wallet.balance).toFixed(4)} FLR</span>
          </div>

          <button
            className="btn btn-primary btn-full"
            onClick={handleConnect}
            disabled={isLoading || parseFloat(depositAmount) > parseFloat(wallet.balance) || !selectedNodeId}
          >
            {isLoading ? "Connecting..." : `Deposit ${depositAmount} FLR & Connect`}
          </button>
        </div>
      </div>
    );
  }

  // Connected View
  if (view === "connected" && activeSession && selectedNode) {
    const elapsed = Date.now() / 1000 - Number(activeSession.startTime);
    const hours = Math.floor(elapsed / 3600);
    const minutes = Math.floor((elapsed % 3600) / 60);
    const seconds = Math.floor(elapsed % 60);

    // Use real WireGuard stats if available, or simulated bytes for testing, otherwise blockchain data
    const wgBytes = wgLiveStats?.peers?.[0]
      ? BigInt(wgLiveStats.peers[0].transfer_tx + wgLiveStats.peers[0].transfer_rx)
      : 0n;
    const vpnBytes = vpnStatus?.connected
      ? BigInt(vpnStatus.bytes_sent + vpnStatus.bytes_received)
      : 0n;
    const realBytesUsed = wgBytes > 0n ? wgBytes : vpnBytes > 0n ? vpnBytes : simulatedBytes > 0n ? simulatedBytes : activeSession.bytesUsed;

    const cost = (realBytesUsed * selectedNode.bandwidthPrice) / (1024n * 1024n * 1024n);
    const remaining = activeSession.deposit - cost;

    const isVpnConnected = vpnStatus?.connected ?? false;
    const isTailscaleConnected = useTailscale && tailscale?.exit_node_active;
    const isConnected = isVpnConnected || isTailscaleConnected;

    return (
      <div className="container">
        <header className="header">
          <div></div>
          <div className="logo">DeVPN</div>
          <div className={`status-badge ${isConnected ? "status-online" : "status-warning"}`}>
            {isConnected ? (isTailscaleConnected ? "VPN Connected" : "VPN Active") : "Session Active"}
          </div>
        </header>

        {error && (
          <div className="alert alert-error">{error}</div>
        )}

        <div className="card connected-card">
          <div className="connected-icon">{isConnected ? "Y" : "..."}</div>
          <div className="connected-title">
            {isConnected
              ? (isTailscaleConnected ? "VPN Connected" : "VPN Connected")
              : "Session Started"}
          </div>
          <div className="connected-subtitle">
            {isConnected
              ? "Your traffic is encrypted and routed through the node"
              : "Establishing VPN tunnel..."}
          </div>

          <div style={{ marginBottom: "24px" }}>
            <span style={{ fontSize: "32px" }}>{getCountryFlag(selectedNode.location)}</span>
            <h3>{selectedNode.location}-{selectedNode.id.toString().slice(0, 6)}</h3>
            <p className="text-muted text-sm">{selectedNode.endpoint}</p>
            {vpnStatus?.interface_name && (
              <p className="text-muted text-sm">Interface: {vpnStatus.interface_name}</p>
            )}
          </div>

          <div className="stats-grid">
            <div className="stat-card">
              <div className="stat-value">{formatBytes(realBytesUsed)}</div>
              <div className="stat-label">Data Used</div>
            </div>
            <div className="stat-card">
              <div className="stat-value">{formatFLR(remaining)}</div>
              <div className="stat-label">Balance</div>
            </div>
            <div className="stat-card">
              <div className="stat-value">
                {hours.toString().padStart(2, "0")}:
                {minutes.toString().padStart(2, "0")}:
                {seconds.toString().padStart(2, "0")}
              </div>
              <div className="stat-label">Session Time</div>
            </div>
          </div>

          <div className="flex justify-between text-sm text-muted mt-4">
            <span>Cost so far:</span>
            <span>{formatFLR(cost)} FLR</span>
          </div>

          {/* VPN Connection Stats */}
          <div style={{ marginTop: "16px", padding: "16px", background: "linear-gradient(135deg, #1a1a2e 0%, #16213e 100%)", borderRadius: "8px", color: "#fff" }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: "12px" }}>
              <strong style={{ fontSize: "14px" }}>VPN Connection</strong>
              <span className={`status-badge ${wgLiveStats || isConnected ? "status-online" : "status-warning"}`}>
                {wgLiveStats || isConnected ? "Connected" : "Connecting"}
              </span>
            </div>

            {/* Connection Info */}
            <div style={{ background: "rgba(255,255,255,0.1)", padding: "12px", borderRadius: "6px", marginBottom: "12px" }}>
              <div className="flex justify-between mb-2" style={{ fontSize: "12px" }}>
                <span style={{ color: "rgba(255,255,255,0.7)" }}>Node IP:</span>
                <span style={{ fontFamily: "monospace" }}>{selectedNode.endpoint.split(":")[0]}</span>
              </div>
              <div className="flex justify-between mb-2" style={{ fontSize: "12px" }}>
                <span style={{ color: "rgba(255,255,255,0.7)" }}>VPN Address:</span>
                <span style={{ fontFamily: "monospace" }}>10.0.0.2</span>
              </div>
              <div className="flex justify-between" style={{ fontSize: "12px" }}>
                <span style={{ color: "rgba(255,255,255,0.7)" }}>Interface:</span>
                <span style={{ fontFamily: "monospace" }}>{wgLiveStats?.interface || "wg0"}</span>
              </div>
            </div>

            {/* Traffic Stats */}
            <div style={{ background: "rgba(255,255,255,0.1)", padding: "12px", borderRadius: "6px", marginBottom: "12px" }}>
              {wgLiveStats?.peers && wgLiveStats.peers.length > 0 ? (
                <>
                  <div className="flex justify-between mb-2" style={{ fontSize: "12px" }}>
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Handshake:</span>
                    <span style={{ color: wgLiveStats.peers[0].latest_handshake > 0 ? "#10b981" : "#f59e0b" }}>
                      {wgLiveStats.peers[0].latest_handshake > 0
                        ? `${Math.floor((Date.now() / 1000 - wgLiveStats.peers[0].latest_handshake))}s ago`
                        : "Waiting..."}
                    </span>
                  </div>
                  <div className="flex justify-between mb-2" style={{ fontSize: "12px" }}>
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Uploaded:</span>
                    <span style={{ color: "#e72058" }}>{formatBytes(BigInt(wgLiveStats.peers[0].transfer_tx))}</span>
                  </div>
                  <div className="flex justify-between" style={{ fontSize: "12px" }}>
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Downloaded:</span>
                    <span style={{ color: "#10b981" }}>{formatBytes(BigInt(wgLiveStats.peers[0].transfer_rx))}</span>
                  </div>
                </>
              ) : (
                <>
                  <div className="flex justify-between mb-2" style={{ fontSize: "12px" }}>
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Simulated Usage:</span>
                    <span style={{ color: "#e72058" }}>{formatBytes(simulatedBytes)}</span>
                  </div>
                  <div className="flex justify-between" style={{ fontSize: "12px" }}>
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Status:</span>
                    <span style={{ color: "#f59e0b" }}>Waiting for traffic...</span>
                  </div>
                </>
              )}
            </div>

            {/* Simulate Traffic for Escrow */}
            <div style={{ background: "rgba(231,32,88,0.2)", padding: "12px", borderRadius: "6px" }}>
              <div style={{ fontSize: "11px", color: "rgba(255,255,255,0.7)", marginBottom: "8px" }}>
                Simulate usage for escrow testing:
              </div>
              <div className="flex gap-2">
                <button
                  className="btn btn-primary"
                  style={{ flex: 1, padding: "6px", fontSize: "12px" }}
                  onClick={() => setSimulatedBytes(prev => prev + BigInt(1024 * 1024 * 10))}
                >
                  +10 MB
                </button>
                <button
                  className="btn btn-primary"
                  style={{ flex: 1, padding: "6px", fontSize: "12px" }}
                  onClick={() => setSimulatedBytes(prev => prev + BigInt(1024 * 1024 * 100))}
                >
                  +100 MB
                </button>
                <button
                  className="btn btn-outline"
                  style={{ flex: 1, padding: "6px", fontSize: "12px", color: "#fff", borderColor: "rgba(255,255,255,0.3)" }}
                  onClick={() => setSimulatedBytes(0n)}
                >
                  Reset
                </button>
              </div>
            </div>
          </div>

          {wgSetupStatus && (
            <div className="alert alert-success" style={{ marginTop: "12px", fontSize: "12px" }}>
              {wgSetupStatus}
            </div>
          )}

          {/* Manual WireGuard Connect Button */}
          {!isConnected && (
            <button
              className="btn btn-primary btn-full"
              style={{ marginTop: "16px" }}
              onClick={async () => {
                setWgSetupStatus("Connecting WireGuard...");
                try {
                  const exitNodeIp = selectedNode.endpoint.split(":")[0];
                  const nodePubkey = selectedNode.publicKey || "cxQI5Fo41hUTcAEpH/uPaKqO7+xsjXd9D6WYz+0ySxI=";
                  const result = await setupWgClient(exitNodeIp, nodePubkey);
                  console.log("WireGuard result:", result);
                  setWgSetupStatus("WireGuard connected!");
                } catch (err) {
                  console.error("WireGuard error:", err);
                  setWgSetupStatus("Failed: " + (err instanceof Error ? err.message : String(err)));
                }
              }}
              disabled={isLoading}
            >
              Connect WireGuard Manually
            </button>
          )}

          <button
            className="btn btn-danger btn-full"
            style={{ marginTop: "24px" }}
            onClick={handleDisconnect}
            disabled={isLoading}
          >
            {isLoading ? "Disconnecting..." : "Disconnect"}
          </button>
        </div>
      </div>
    );
  }

  return null;
}

export default ClientMode;
