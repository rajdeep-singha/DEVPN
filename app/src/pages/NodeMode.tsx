import { useState, useEffect, useCallback, useMemo } from "react";
import { Contract, JsonRpcProvider } from "ethers";
import {
  formatFLR,
  parseFLR,
  shortenAddress,
  formatBytes,
  Node,
  Session,
  SessionStatus,
  COUNTRY_FLAGS,
  NODE_REGISTRY_ABI,
  NODE_REGISTRY_ADDRESS,
  ESCROW_ABI,
  ESCROW_ADDRESS,
  NETWORK_CONFIG,
} from "../utils/contract";
import {
  checkNetwork as tauriCheckNetwork,
  getWgKeys,
  initNode,
  startNode,
  stopNode,
  isTauri,
  WireGuardKeys,
  tailscaleStatus,
  TailscaleStatus,
  setupWgNode,
  getWgLiveStats,
  getLocalIp,
  WgLiveStats,
} from "../utils/tauri";

// Create a stable read-only provider
const rpcProvider = new JsonRpcProvider(NETWORK_CONFIG.rpcUrls[0]);

// Helper function to parse node data from contract result
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseNodeData(nodeData: any): Node {
  return {
    id: nodeData[0] ?? nodeData.id,
    owner: nodeData[1] ?? nodeData.owner,
    endpoint: nodeData[2] ?? nodeData.endpoint,
    publicKey: nodeData[3] ?? nodeData.publicKey,
    stakedAmount: nodeData[4] ?? nodeData.stakedAmount,
    stakeTimestamp: nodeData[5] ?? nodeData.stakeTimestamp,
    bandwidthPrice: nodeData[6] ?? nodeData.bandwidthPrice,
    location: nodeData[7] ?? nodeData.location,
    maxBandwidth: nodeData[8] ?? nodeData.maxBandwidth,
    status: Number(nodeData[9] ?? nodeData.status),
    totalBandwidthServed: nodeData[10] ?? nodeData.totalBandwidthServed,
    totalEarnings: nodeData[11] ?? nodeData.totalEarnings,
    lastHeartbeat: nodeData[12] ?? nodeData.lastHeartbeat,
    uptimeScore: nodeData[13] ?? nodeData.uptimeScore,
    sessionCount: nodeData[14] ?? nodeData.sessionCount,
    rating: nodeData[15] ?? nodeData.rating,
    ratingCount: nodeData[16] ?? nodeData.ratingCount,
    isActive: Boolean(nodeData[17] ?? nodeData.isActive),
  };
}

interface WalletState {
  isConnected: boolean;
  address: string | null;
  balance: string;
  chainId: number | null;
  isCorrectNetwork: boolean;
  connectionType: "metamask" | "walletconnect" | null;
}

interface NodeModeProps {
  onBack: () => void;
  wallet: WalletState;
  registryContract: Contract | null; // Signer-connected registry
  escrowContract: Contract | null; // Signer-connected escrow
}

type NodeStep = "loading" | "check" | "setup" | "register" | "dashboard";

interface NetworkCheck {
  internetSpeed: string;
  publicIP: string;
  localIP: string;
  countryCode: string;
  portOpen: boolean;
  wireguardInstalled: boolean;
  internetConnected: boolean;
  isHotspot: boolean;
  activeInterface: string;
  checking: boolean;
}

function NodeMode({ onBack, wallet, registryContract, escrowContract: _escrowContract }: NodeModeProps) {

  // Create stable read-only contracts
  const readOnlyRegistry = useMemo(() => {
    return new Contract(NODE_REGISTRY_ADDRESS, NODE_REGISTRY_ABI, rpcProvider);
  }, []);

  const readOnlyEscrow = useMemo(() => {
    return new Contract(ESCROW_ADDRESS, ESCROW_ABI, rpcProvider);
  }, []);

  const [step, setStep] = useState<NodeStep>("loading");
  const [networkCheck, setNetworkCheck] = useState<NetworkCheck>({
    internetSpeed: "",
    publicIP: "",
    localIP: "",
    countryCode: "",
    portOpen: false,
    wireguardInstalled: false,
    internetConnected: false,
    isHotspot: false,
    activeInterface: "",
    checking: true,
  });

  // Node configuration
  const [endpoint, setEndpoint] = useState("");
  const [location, setLocation] = useState("US");
  const [pricePerGB, setPricePerGB] = useState("0.5");
  const [stakeAmount, setStakeAmount] = useState("15"); // Minimum 15 FLR
  const [maxBandwidth] = useState("1000"); // 1000 GB max

  // Node data
  const [myNode, setMyNode] = useState<Node | null>(null);
  const [myNodeId, setMyNodeId] = useState<string | null>(null); // bytes32
  const [sessions, setSessions] = useState<Session[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [connectionMethod, setConnectionMethod] = useState<"port" | "hotspot">("port");

  // WireGuard keys
  const [wgKeys, setWgKeys] = useState<WireGuardKeys | null>(null);

  // Tailscale state
  const [tailscale, setTailscale] = useState<TailscaleStatus | null>(null);
  const [useTailscale, setUseTailscale] = useState(true); // Default to VPN network

  // WireGuard live stats
  const [wgLiveStats, setWgLiveStats] = useState<WgLiveStats | null>(null);
  const [localIp, setLocalIp] = useState<string | null>(null);
  const [wgSetupStatus, setWgSetupStatus] = useState<string | null>(null);

  // Simulated traffic for escrow testing
  const [simulatedBytes, setSimulatedBytes] = useState<bigint>(0n);

  // Track session updates for refresh
  const [sessionUpdateTrigger] = useState(0);

  // Check if user already has a node
  useEffect(() => {
    const checkExistingNode = async () => {
      if (!wallet.address) {
        return;
      }

      try {
        console.log("Checking for existing node for address:", wallet.address);
        // Get primary node for this owner
        const nodeId = await readOnlyRegistry.primaryNode(wallet.address);
        console.log("Node ID found:", nodeId);

        // Check if nodeId is valid (not zero bytes32)
        const zeroBytes32 = "0x0000000000000000000000000000000000000000000000000000000000000000";
        if (nodeId && nodeId !== zeroBytes32) {
          // User has a node - get details
          const nodeData = await readOnlyRegistry.getNodeInfo(nodeId);
          console.log("Raw node data:", nodeData);

          const node = parseNodeData(nodeData);
          console.log("Parsed node - status:", node.status, "isActive:", node.isActive);

          setMyNode(node);
          setMyNodeId(nodeId);
          setStep("dashboard");
        } else {
          // No node - proceed to check step for new registration
          setStep("check");
        }
      } catch (err) {
        console.error("Error checking node:", err);
        setStep("check");
      }
    };

    checkExistingNode();
  }, [wallet.address, readOnlyRegistry]);

  // Network check using Tauri backend
  useEffect(() => {
    if (step !== "check") return;

    const checkNetwork = async () => {
      setNetworkCheck((prev) => ({ ...prev, checking: true }));

      try {
        if (isTauri()) {
          const result = await tauriCheckNetwork();
          const keys = await getWgKeys();
          setWgKeys(keys);

          // Check Tailscale status
          const tsStatus = await tailscaleStatus();
          setTailscale(tsStatus);

          setNetworkCheck({
            internetSpeed: result.upload_speed,
            publicIP: result.public_ip,
            localIP: result.local_ip,
            countryCode: result.country_code,
            portOpen: result.port_open,
            wireguardInstalled: result.wireguard_installed,
            internetConnected: result.internet_connected,
            isHotspot: result.is_hotspot,
            activeInterface: result.active_interface,
            checking: false,
          });

          // Use Tailscale IP if available, otherwise fallback to public IP
          if (tsStatus.authenticated && tsStatus.ip) {
            setEndpoint(`${tsStatus.ip}:51820`);
            setUseTailscale(true);
          } else {
            setEndpoint(`${result.public_ip}:51820`);
            setUseTailscale(false);
          }

          if (result.country_code) {
            setLocation(result.country_code);
          }

          if (result.is_hotspot) {
            setConnectionMethod("hotspot");
          }
        } else {
          // Fallback for browser testing
          await new Promise((resolve) => setTimeout(resolve, 1500));
          const publicIP = "103." + Math.floor(Math.random() * 255) + "." + Math.floor(Math.random() * 255) + "." + Math.floor(Math.random() * 255);

          setNetworkCheck({
            internetSpeed: Math.floor(Math.random() * 50 + 20) + " Mbps",
            publicIP,
            localIP: "192.168.1." + Math.floor(Math.random() * 254 + 1),
            countryCode: "US",
            portOpen: false,
            wireguardInstalled: false,
            internetConnected: true,
            isHotspot: false,
            activeInterface: "en0",
            checking: false,
          });
          setEndpoint(`${publicIP}:51820`);
          setUseTailscale(false);
        }
      } catch (err) {
        console.error("Network check error:", err);
        setError(err instanceof Error ? err.message : "Network check failed");
        setNetworkCheck((prev) => ({ ...prev, checking: false }));
      }
    };

    checkNetwork();
  }, [step]);

  // Fetch sessions for dashboard using escrow contract
  const fetchSessions = useCallback(async () => {
    if (!myNodeId) return;

    try {
      const nodeSessions = await readOnlyEscrow.getNodeSessionDetails(myNodeId);
      setSessions(nodeSessions);
    } catch (err) {
      console.error("Error fetching sessions:", err);
    }
  }, [myNodeId, readOnlyEscrow]);

  useEffect(() => {
    if (step === "dashboard" && myNodeId) {
      fetchSessions();
      const interval = setInterval(fetchSessions, 10000);
      return () => clearInterval(interval);
    }
  }, [step, myNodeId, fetchSessions, sessionUpdateTrigger]);

  // Poll WireGuard live stats when node is active
  useEffect(() => {
    if (step !== "dashboard" || !myNode?.isActive || !isTauri()) return;

    const pollWgStats = async () => {
      try {
        const stats = await getWgLiveStats();
        setWgLiveStats(stats);
      } catch (err) {
        // WireGuard not running, stats unavailable
        console.debug("WG stats not available:", err);
      }
    };

    pollWgStats();
    const interval = setInterval(pollWgStats, 3000);
    return () => clearInterval(interval);
  }, [step, myNode?.isActive]);

  // Register node
  const handleRegister = async () => {
    if (!registryContract) {
      setError("Wallet not connected. Please go back and connect your wallet.");
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      setError("Preparing transaction... Check your wallet app to approve!");

      let wgPubKey = wgKeys?.public_key;

      if (!wgPubKey && isTauri()) {
        const keys = await getWgKeys();
        setWgKeys(keys);
        wgPubKey = keys.public_key;
      }

      if (!wgPubKey) {
        wgPubKey = "wg-" + Math.random().toString(36).substring(2, 15);
      }

      const nodeEndpoint = endpoint || `${networkCheck.publicIP}:51820`;

      if (isTauri()) {
        await initNode(nodeEndpoint, location, pricePerGB, stakeAmount);
      }

      console.log("Registering node with:", {
        endpoint: nodeEndpoint,
        wgPubKey,
        pricePerGB: parseFLR(pricePerGB).toString(),
        location,
        maxBandwidth: parseFLR(maxBandwidth).toString(),
        stakeValue: parseFLR(stakeAmount).toString(),
      });

      setError("APPROVE THE TRANSACTION IN YOUR WALLET APP!");

      // New registerNode signature: endpoint, publicKey, bandwidthPrice, location, maxBandwidth
      const tx = await registryContract.registerNode(
        nodeEndpoint,
        wgPubKey,
        parseFLR(pricePerGB),
        location,
        BigInt(maxBandwidth) * BigInt(1024 * 1024 * 1024), // Convert GB to bytes
        { value: parseFLR(stakeAmount) }
      );

      setError("Transaction sent! Waiting for confirmation...");
      console.log("Transaction sent:", tx.hash);
      await tx.wait();
      console.log("Transaction confirmed!");
      setError(null);

      // Get the nodeId from the event or by querying
      const nodeId = await readOnlyRegistry.primaryNode(wallet.address);
      setMyNodeId(nodeId);

      // Fetch the new node info
      const nodeData = await readOnlyRegistry.getNodeInfo(nodeId);
      const node = parseNodeData(nodeData);
      setMyNode(node);

      // Start node in Tauri backend
      if (isTauri() && nodeId) {
        await startNode(Number(node.id));
      }

      setStep("dashboard");
    } catch (err: unknown) {
      console.error("Error registering node:", err);
      let errorMsg = "Failed to register node";
      if (err instanceof Error) {
        errorMsg = err.message;
        if (err.message.includes("user rejected")) {
          errorMsg = "Transaction was rejected. Please approve in your wallet.";
        } else if (err.message.includes("insufficient funds")) {
          errorMsg = "Insufficient funds for gas + stake amount.";
        } else if (err.message.includes("network")) {
          errorMsg = "Network error. Make sure you're on Coston2 testnet.";
        }
      } else if (typeof err === "object" && err !== null) {
        const errObj = err as { reason?: string; message?: string };
        errorMsg = errObj.reason || errObj.message || errorMsg;
      }
      setError(errorMsg);
    } finally {
      setIsLoading(false);
    }
  };

  // Withdraw earnings
  const handleWithdraw = async () => {
    if (!registryContract || !myNodeId) return;

    setIsLoading(true);
    setError(null);

    try {
      const tx = await registryContract.withdrawEarnings(myNodeId);
      await tx.wait();

      // Refresh node data
      const nodeData = await readOnlyRegistry.getNodeInfo(myNodeId);
      setMyNode(parseNodeData(nodeData));
    } catch (err) {
      console.error("Error withdrawing:", err);
      setError(err instanceof Error ? err.message : "Failed to withdraw");
    } finally {
      setIsLoading(false);
    }
  };

  // Toggle node active status
  const handleToggleActive = async () => {
    if (!registryContract || !myNode || !myNodeId) return;

    setIsLoading(true);
    setError(null);

    try {
      if (myNode.isActive) {
        if (isTauri()) {
          await stopNode();
        }

        const tx = await registryContract.deactivateNode(myNodeId);
        await tx.wait();
        setWgLiveStats(null);
      } else {
        const tx = await registryContract.activateNode(myNodeId);
        await tx.wait();

        if (isTauri()) {
          await startNode(Number(myNode.id));

          // Auto-setup WireGuard node with the demo client public key
          setWgSetupStatus("Setting up WireGuard...");
          try {
            const clientPubkey = "e6/0jubRkV9t459F3tPKZ4mG00H7DlAzW/aWZrRIw1k=";
            const result = await setupWgNode(clientPubkey);
            console.log("WireGuard setup result:", result);
            setWgSetupStatus("WireGuard active!");

            // Get local IP for display
            const ip = await getLocalIp();
            setLocalIp(ip);
          } catch (wgErr) {
            console.error("WireGuard setup error:", wgErr);
            setWgSetupStatus("WireGuard setup failed - run manually");
          }
        }
      }

      // Refresh node data
      const nodeData = await readOnlyRegistry.getNodeInfo(myNodeId);
      setMyNode(parseNodeData(nodeData));
    } catch (err) {
      console.error("Error toggling node:", err);
      setError(err instanceof Error ? err.message : "Failed to update node status");
    } finally {
      setIsLoading(false);
    }
  };

  // Update node endpoint and WG keys
  const handleUpdateKeys = async () => {
    if (!registryContract || !myNode || !myNodeId) return;

    setIsLoading(true);
    setError(null);

    try {
      if (!isTauri()) {
        setError("This feature requires the desktop app");
        return;
      }

      setError("Checking current IP address...");

      const networkInfo = await tauriCheckNetwork();
      const currentEndpoint = `${networkInfo.public_ip}:51820`;

      const keys = await getWgKeys();
      setWgKeys(keys);

      console.log("Updating node with:", {
        oldEndpoint: myNode.endpoint,
        newEndpoint: currentEndpoint,
        oldKey: myNode.publicKey,
        newKey: keys.public_key,
      });

      setError(`Updating to ${currentEndpoint}... Approve in wallet!`);

      // updateNode: nodeId, endpoint, publicKey, bandwidthPrice, maxBandwidth
      const tx = await registryContract.updateNode(
        myNodeId,
        currentEndpoint,
        keys.public_key,
        myNode.bandwidthPrice,
        myNode.maxBandwidth
      );
      await tx.wait();

      // Refresh node data
      const nodeData = await readOnlyRegistry.getNodeInfo(myNodeId);
      setMyNode(parseNodeData(nodeData));
      setError(null);
    } catch (err) {
      console.error("Error updating keys:", err);
      setError(err instanceof Error ? err.message : "Failed to update keys");
    } finally {
      setIsLoading(false);
    }
  };

  // Submit heartbeat
  const handleHeartbeat = async () => {
    if (!registryContract || !myNodeId) return;

    setIsLoading(true);
    setError(null);

    try {
      const tx = await registryContract.submitHeartbeat(myNodeId);
      await tx.wait();

      // Refresh node data
      const nodeData = await readOnlyRegistry.getNodeInfo(myNodeId);
      setMyNode(parseNodeData(nodeData));
      setError("Heartbeat submitted successfully!");
    } catch (err) {
      console.error("Error submitting heartbeat:", err);
      setError(err instanceof Error ? err.message : "Failed to submit heartbeat");
    } finally {
      setIsLoading(false);
    }
  };

  // Deregister confirmation state
  const [showDeregisterConfirm, setShowDeregisterConfirm] = useState(false);

  // Deregister node and withdraw stake
  const handleDeregister = async () => {
    console.log("Deregister clicked!");

    if (!registryContract) {
      setError("Wallet not connected. Please go back and reconnect your wallet.");
      return;
    }
    if (!myNodeId) {
      setError("No node ID found.");
      return;
    }

    // Show confirmation UI
    setShowDeregisterConfirm(true);
  };

  // Actually perform the deregistration
  const confirmDeregister = async () => {
    if (!registryContract || !myNodeId) return;

    setShowDeregisterConfirm(false);
    setIsLoading(true);
    setError(null);

    try {
      // First deactivate if active
      if (myNode?.isActive) {
        setError("Step 1/2: Deactivating node... Approve in wallet!");
        const deactivateTx = await registryContract.deactivateNode(myNodeId);
        await deactivateTx.wait();
      }

      // Initiate unstaking process
      setError("Step 2/2: Initiating unstake... Approve in wallet!");
      const tx = await registryContract.initiateUnstake(myNodeId);
      await tx.wait();

      // Stop local node
      if (isTauri()) {
        try {
          await stopNode();
        } catch (e) {
          console.warn("Failed to stop local node:", e);
        }
      }

      // Refresh node data to show unstaking status
      const nodeData = await readOnlyRegistry.getNodeInfo(myNodeId);
      setMyNode(parseNodeData(nodeData));

      setError("Unstaking initiated! Your stake will be available after the lock period (check contract for exact time). Refresh to see updated status.");
    } catch (err) {
      console.error("Error deregistering node:", err);
      const errMsg = err instanceof Error ? err.message : "Failed to deregister node";
      if (errMsg.includes("user rejected")) {
        setError("Transaction rejected. Please approve in wallet.");
      } else if (errMsg.includes("active sessions")) {
        setError("Cannot deregister: You have active sessions. Wait for them to end.");
      } else if (errMsg.includes("Already unstaking")) {
        setError("Already unstaking! Wait for lock period to complete, then withdraw.");
      } else {
        setError(errMsg);
      }
    } finally {
      setIsLoading(false);
    }
  };

  // Withdraw stake after lock period
  const handleWithdrawStake = async () => {
    if (!registryContract || !myNodeId) return;

    setIsLoading(true);
    setError(null);

    try {
      setError("Withdrawing stake... Approve in wallet!");
      const tx = await registryContract.withdrawStake(myNodeId);
      await tx.wait();

      // Reset state
      setMyNode(null);
      setMyNodeId(null);
      setError(null);
      setStep("check");
    } catch (err) {
      console.error("Error withdrawing stake:", err);
      const errMsg = err instanceof Error ? err.message : "Failed to withdraw";
      if (errMsg.includes("Lock period")) {
        setError("Lock period not over yet. Please wait.");
      } else if (errMsg.includes("user rejected")) {
        setError("Transaction rejected.");
      } else {
        setError(errMsg);
      }
    } finally {
      setIsLoading(false);
    }
  };

  // Refresh VPN status
  const handleRefreshTailscale = async () => {
    if (!isTauri()) return;

    try {
      const status = await tailscaleStatus();
      setTailscale(status);

      if (status.authenticated && status.ip) {
        setEndpoint(`${status.ip}:51820`);
        setUseTailscale(true);
      }
    } catch (err) {
      console.error("Error refreshing Tailscale:", err);
    }
  };

  // Loading state
  if (step === "loading") {
    return (
      <div className="container">
        <header className="header">
          <button className="btn btn-outline" onClick={onBack}>
            ← Back
          </button>
          <div className="logo">Node Mode</div>
          <div></div>
        </header>

        <div className="card" style={{ textAlign: "center", padding: "60px 24px" }}>
          <div className="spinner" style={{ margin: "0 auto 24px" }}></div>
          <h3>Checking your node status...</h3>
          <p className="text-muted">Looking for existing node registration</p>
        </div>
      </div>
    );
  }

  // Step 1: Network Check
  if (step === "check") {
    return (
      <div className="container">
        <header className="header">
          <button className="btn btn-outline" onClick={onBack}>
            ← Back
          </button>
          <div className="logo">Node Setup</div>
          <div></div>
        </header>

        <div className="card">
          <h2 style={{ marginBottom: "24px" }}>Network Check</h2>

          {networkCheck.checking ? (
            <div className="loading">
              <div className="spinner"></div>
              <span style={{ marginLeft: "16px" }}>Checking your network...</span>
            </div>
          ) : (
            <>
              <div className="check-item">
                <span className={`check-icon ${networkCheck.internetConnected ? "success" : "error"}`}>
                  {networkCheck.internetConnected ? "Y" : "N"}
                </span>
                <div>
                  <strong>Internet Connection</strong>
                  <p className="text-muted text-sm">
                    {networkCheck.internetConnected ? "Connected" : "No internet connection"}
                  </p>
                </div>
              </div>

              <div className="check-item">
                <span className="check-icon success">Y</span>
                <div>
                  <strong>Upload Speed</strong>
                  <p className="text-muted text-sm">{networkCheck.internetSpeed}</p>
                </div>
              </div>

              <div className="check-item">
                <span className="check-icon success">Y</span>
                <div>
                  <strong>Public IP Detected</strong>
                  <p className="text-muted text-sm">
                    {networkCheck.publicIP} {networkCheck.countryCode && `(${COUNTRY_FLAGS[networkCheck.countryCode] || "--"} ${networkCheck.countryCode})`}
                  </p>
                </div>
              </div>

              <div className="check-item">
                <span className="check-icon info">i</span>
                <div>
                  <strong>Local IP</strong>
                  <p className="text-muted text-sm">{networkCheck.localIP} (for port forwarding)</p>
                </div>
              </div>

              <div className="check-item">
                <span className={`check-icon ${networkCheck.wireguardInstalled ? "success" : "warning"}`}>
                  {networkCheck.wireguardInstalled ? "Y" : "!"}
                </span>
                <div>
                  <strong>WireGuard</strong>
                  <p className="text-muted text-sm">
                    {networkCheck.wireguardInstalled ? "Installed and ready" : "Not installed (optional)"}
                  </p>
                </div>
              </div>

              <div className="check-item">
                <span className={`check-icon ${networkCheck.portOpen ? "success" : "warning"}`}>
                  {networkCheck.portOpen ? "Y" : "!"}
                </span>
                <div>
                  <strong>Port 51820 (UDP)</strong>
                  <p className="text-muted text-sm">
                    {networkCheck.portOpen ? "Open and reachable" : "Not reachable - setup required"}
                  </p>
                </div>
              </div>

              {wgKeys && (
                <div className="check-item">
                  <span className="check-icon success">Y</span>
                  <div>
                    <strong>WireGuard Keys Generated</strong>
                    <p className="text-muted text-sm" style={{ fontFamily: "monospace", fontSize: "10px", wordBreak: "break-all" }}>
                      Public Key: {wgKeys.public_key.substring(0, 20)}...
                    </p>
                  </div>
                </div>
              )}

              {/* VPN Network Setup - Recommended for NAT traversal */}
              <div style={{ marginTop: "24px", padding: "16px", background: "var(--bg-input)", borderRadius: "12px", border: useTailscale ? "2px solid var(--success)" : "2px solid transparent" }}>
                <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: "12px" }}>
                  <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                    <span style={{ fontSize: "20px" }}>VPN</span>
                    <strong>VPN Network Setup</strong>
                    <span style={{ fontSize: "10px", background: "var(--success)", color: "white", padding: "2px 6px", borderRadius: "4px" }}>RECOMMENDED</span>
                  </div>
                  <button
                    className="btn btn-outline"
                    onClick={handleRefreshTailscale}
                    style={{ padding: "4px 8px", fontSize: "12px" }}
                  >
                    Refresh
                  </button>
                </div>

                {tailscale?.authenticated && tailscale?.ip ? (
                  <>
                    <div className="check-item" style={{ marginBottom: "8px" }}>
                      <span className="check-icon success">Y</span>
                      <div>
                        <strong>VPN Network Connected</strong>
                        <p className="text-muted text-sm">IP: {tailscale.ip}</p>
                      </div>
                    </div>

                    <div className="check-item" style={{ marginBottom: "8px" }}>
                      <span className={`check-icon ${tailscale.is_exit_node ? "success" : "warning"}`}>
                        {tailscale.is_exit_node ? "Y" : "!"}
                      </span>
                      <div>
                        <strong>Node Mode {tailscale.is_exit_node ? "Enabled" : "Disabled"}</strong>
                        <p className="text-muted text-sm">
                          {tailscale.is_exit_node
                            ? "Ready to serve VPN clients"
                            : "Run: tailscale up --advertise-exit-node"}
                        </p>
                      </div>
                    </div>

                    {tailscale.is_exit_node ? (
                      <div className="alert alert-success" style={{ marginTop: "12px" }}>
                        Ready! Your VPN endpoint: <code>{tailscale.ip}:51820</code>
                      </div>
                    ) : (
                      <div className="alert alert-warning" style={{ marginTop: "12px" }}>
                        Enable exit node in terminal: <code>tailscale up --advertise-exit-node</code>
                      </div>
                    )}
                  </>
                ) : (
                  <>
                    <div className="check-item" style={{ marginBottom: "8px" }}>
                      <span className="check-icon warning">!</span>
                      <div>
                        <strong>VPN Network Not Connected</strong>
                        <p className="text-muted text-sm">Please setup manually</p>
                      </div>
                    </div>
                    <div className="alert alert-warning" style={{ marginTop: "12px" }}>
                      <p style={{ marginBottom: "8px" }}><strong>Setup commands:</strong></p>
                      <code style={{ display: "block", marginBottom: "4px" }}>tailscale up</code>
                      <code style={{ display: "block" }}>tailscale up --advertise-exit-node</code>
                    </div>
                  </>
                )}

                <p className="text-muted text-sm" style={{ marginTop: "12px" }}>
                  Handles NAT traversal automatically - works even behind CGNAT and firewalls.
                </p>
              </div>

              {error && (
                <div className="alert alert-error" style={{ marginTop: "16px" }}>
                  {error}
                </div>
              )}

              <div style={{ marginTop: "20px" }}>
                <label className="label">Alternative Connection Methods</label>
                <p className="text-muted text-sm" style={{ marginBottom: "12px" }}>
                  Only use these if you need direct connections.
                </p>
                <div style={{ display: "flex", gap: "12px" }}>
                  <div
                    className={`mode-card ${!useTailscale && connectionMethod === "port" ? "selected" : ""}`}
                    onClick={() => {
                      setConnectionMethod("port");
                      setUseTailscale(false);
                      setEndpoint(`${networkCheck.publicIP}:51820`);
                    }}
                    style={{ padding: "20px", flex: 1, opacity: useTailscale ? 0.6 : 1 }}
                  >
                    <div className="mode-icon">PORT</div>
                    <strong>Port Forwarding</strong>
                    <p className="text-sm text-muted">Configure your router</p>
                  </div>
                  <div
                    className={`mode-card ${!useTailscale && connectionMethod === "hotspot" ? "selected" : ""}`}
                    onClick={() => {
                      setConnectionMethod("hotspot");
                      setUseTailscale(false);
                      setEndpoint(`${networkCheck.publicIP}:51820`);
                    }}
                    style={{ padding: "20px", flex: 1, opacity: useTailscale ? 0.6 : 1 }}
                  >
                    <div className="mode-icon">4G</div>
                    <strong>Mobile Hotspot</strong>
                    <p className="text-sm text-muted">Use phone's data</p>
                  </div>
                </div>
              </div>

              <button
                className="btn btn-primary btn-full"
                style={{ marginTop: "24px" }}
                onClick={() => {
                  if (useTailscale && tailscale?.authenticated && tailscale?.ip) {
                    // VPN connected - proceed to register
                    setEndpoint(`${tailscale.ip}:51820`);
                    setStep("register");
                  } else if (useTailscale) {
                    setError("Please connect to VPN network first (run: tailscale up)");
                  } else {
                    setStep("setup");
                  }
                }}
              >
                {useTailscale
                  ? "Continue to Registration"
                  : `Continue with ${connectionMethod === "port" ? "Port Forwarding" : "Mobile Hotspot"}`}
              </button>
            </>
          )}
        </div>
      </div>
    );
  }

  // Step 2: Setup Guide
  if (step === "setup") {
    return (
      <div className="container">
        <header className="header">
          <button className="btn btn-outline" onClick={() => setStep("check")}>
            ← Back
          </button>
          <div className="logo">Node Setup</div>
          <div></div>
        </header>

        <div className="card">
          <h2 style={{ marginBottom: "24px" }}>
            {connectionMethod === "port" ? "Port Forwarding Guide" : "Mobile Hotspot Guide"}
          </h2>

          {connectionMethod === "port" ? (
            <>
              <div className="setup-step">
                <div className="step-number">1</div>
                <div className="step-content">
                  <h4>Open Router Settings</h4>
                  <p>Open your browser and go to <code>192.168.1.1</code> or <code>192.168.0.1</code></p>
                </div>
              </div>

              <div className="setup-step">
                <div className="step-number">2</div>
                <div className="step-content">
                  <h4>Login to Router</h4>
                  <p>Check your router for default credentials</p>
                </div>
              </div>

              <div className="setup-step">
                <div className="step-number">3</div>
                <div className="step-content">
                  <h4>Find Port Forwarding</h4>
                  <p>Look for "Port Forwarding", "NAT", or "Virtual Server"</p>
                </div>
              </div>

              <div className="setup-step">
                <div className="step-number">4</div>
                <div className="step-content">
                  <h4>Add Port Forward Rule</h4>
                  <p>
                    <strong>External Port:</strong> 51820<br />
                    <strong>Internal IP:</strong> <code>{networkCheck.localIP}</code><br />
                    <strong>Internal Port:</strong> 51820<br />
                    <strong>Protocol:</strong> UDP
                  </p>
                </div>
              </div>

              <div className="alert alert-success">
                <strong>Your Local IP:</strong> <code>{networkCheck.localIP}</code>
              </div>
            </>
          ) : (
            <>
              <div className="setup-step">
                <div className="step-number">1</div>
                <div className="step-content">
                  <h4>Enable Mobile Hotspot</h4>
                  <p>On your phone, enable Mobile Hotspot</p>
                </div>
              </div>

              <div className="setup-step">
                <div className="step-number">2</div>
                <div className="step-content">
                  <h4>Connect Your Computer</h4>
                  <p>Connect to your phone's WiFi hotspot</p>
                </div>
              </div>

              <div className="setup-step">
                <div className="step-number">3</div>
                <div className="step-content">
                  <h4>Ready!</h4>
                  <p>No port forwarding needed with mobile data!</p>
                </div>
              </div>
            </>
          )}

          <button
            className="btn btn-primary btn-full"
            style={{ marginTop: "24px" }}
            onClick={() => setStep("register")}
          >
            I've completed the setup
          </button>
        </div>
      </div>
    );
  }

  // Step 3: Register Node
  if (step === "register") {
    return (
      <div className="container">
        <header className="header">
          <button className="btn btn-outline" onClick={() => setStep("setup")}>
            ← Back
          </button>
          <div className="logo">Node Setup</div>
          <div></div>
        </header>

        <div className="card">
          <h2 style={{ marginBottom: "24px" }}>Configure Your Node</h2>

          {error && (
            <div className="alert alert-error" style={{ marginBottom: "16px" }}>
              {error}
            </div>
          )}

          <div style={{ marginBottom: "16px" }}>
            <label className="label">Endpoint {useTailscale ? "(VPN Network)" : "(Auto-detected)"}</label>
            <div className="input" style={{ background: "var(--bg-secondary)", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <span>{endpoint}</span>
              <span style={{ color: "var(--success)", fontSize: "12px" }}>
                {useTailscale ? "VPN VPN" : "Y Auto"}
              </span>
            </div>
            {useTailscale && (
              <p className="text-sm text-muted" style={{ marginTop: "4px" }}>
                Using VPN network for NAT traversal - clients will connect through the mesh network
              </p>
            )}
          </div>

          <div style={{ marginBottom: "16px" }}>
            <label className="label">Location (Auto-detected)</label>
            <div className="input" style={{ background: "var(--bg-secondary)", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <span>{COUNTRY_FLAGS[location] || "--"} {location}</span>
              <span style={{ color: "var(--success)", fontSize: "12px" }}>Y Auto</span>
            </div>
          </div>

          <div style={{ marginBottom: "16px" }}>
            <label className="label">Price per GB (FLR)</label>
            <input
              type="number"
              className="input"
              step="0.1"
              min="0.1"
              value={pricePerGB}
              onChange={(e) => setPricePerGB(e.target.value)}
            />
            <p className="text-sm text-muted">Average network price: 0.4 - 0.6 FLR</p>
          </div>

          <div style={{ marginBottom: "16px" }}>
            <label className="label">Stake Amount (FLR)</label>
            <input
              type="number"
              className="input"
              step="10"
              min="15"
              value={stakeAmount}
              onChange={(e) => setStakeAmount(e.target.value)}
            />
            <p className="text-sm text-muted">Minimum: 15 FLR. Higher stake = higher trust ranking</p>
          </div>

          <div className="card" style={{ background: "var(--bg-input)", marginTop: "24px" }}>
            <h4 style={{ marginBottom: "12px" }}>Summary</h4>
            <div className="flex justify-between mb-4">
              <span>Location:</span>
              <span>{COUNTRY_FLAGS[location]} {location}</span>
            </div>
            <div className="flex justify-between mb-4">
              <span>Price:</span>
              <span>{pricePerGB} FLR / GB</span>
            </div>
            <div className="flex justify-between mb-4">
              <span>Stake:</span>
              <span>{stakeAmount} FLR</span>
            </div>
            <div className="flex justify-between">
              <span>Your Balance:</span>
              <span>{parseFloat(wallet.balance).toFixed(4)} FLR</span>
            </div>
          </div>

          <button
            className="btn btn-primary btn-full"
            style={{ marginTop: "24px" }}
            onClick={handleRegister}
            disabled={isLoading || !registryContract || parseFloat(stakeAmount) > parseFloat(wallet.balance || "0")}
          >
            {isLoading
              ? "Registering..."
              : !registryContract
                ? "Connect Wallet First"
                : parseFloat(stakeAmount) > parseFloat(wallet.balance || "0")
                  ? "Insufficient Balance"
                  : `Stake ${stakeAmount} FLR & Go Online`}
          </button>
        </div>
      </div>
    );
  }

  // Step 4: Dashboard
  if (step === "dashboard" && myNode) {
    const activeSessions = sessions.filter((s) => Number(s.status) === SessionStatus.Active);
    const totalBandwidth = sessions.reduce((acc, s) => acc + s.bytesUsed, 0n);

    return (
      <div className="container">
        <header className="header">
          <button className="btn btn-outline" onClick={onBack}>
            ← Back
          </button>
          <div className="logo">Node Dashboard</div>
          <div className={`status-badge ${myNode.isActive ? "status-online" : "status-offline"}`}>
            {myNode.isActive ? "Online" : "Offline"}
          </div>
        </header>

        {error && (
          <div className="alert alert-error" onClick={() => setError(null)} style={{ cursor: "pointer" }}>
            {error}
          </div>
        )}

        <div className="card">
          <div className="flex justify-between items-center mb-4">
            <div>
              <h3>Node #{myNode.id.toString().slice(0, 8)}</h3>
              <p className="text-muted text-sm">{myNode.endpoint}</p>
            </div>
            <div>
              <span style={{ fontSize: "32px" }}>{COUNTRY_FLAGS[myNode.location] || "--"}</span>
            </div>
          </div>

          <div className="stats-grid">
            <div className="stat-card">
              <div className="stat-value">{formatFLR(myNode.totalEarnings)}</div>
              <div className="stat-label">Earnings (FLR)</div>
            </div>
            <div className="stat-card">
              <div className="stat-value">{myNode.sessionCount.toString()}</div>
              <div className="stat-label">Total Sessions</div>
            </div>
            <div className="stat-card">
              <div className="stat-value">{activeSessions.length}</div>
              <div className="stat-label">Active Now</div>
            </div>
          </div>

          <div className="flex gap-4" style={{ marginTop: "20px" }}>
            <button
              className="btn btn-primary"
              onClick={handleWithdraw}
              disabled={isLoading || myNode.totalEarnings === 0n}
              style={{ flex: 1 }}
            >
              {isLoading ? "..." : `Withdraw ${formatFLR(myNode.totalEarnings)} FLR`}
            </button>
            <button
              className={`btn ${myNode.isActive ? "btn-danger" : "btn-success"}`}
              onClick={handleToggleActive}
              disabled={isLoading}
              style={{ flex: 1 }}
            >
              {isLoading ? "..." : myNode.isActive ? "Go Offline" : "Go Online"}
            </button>
          </div>

          {/* Manual WireGuard Activation Button */}
          {myNode.isActive && (
            <div style={{ marginTop: "16px" }}>
              <button
                className="btn btn-outline btn-full"
                onClick={async () => {
                  setWgSetupStatus("Starting WireGuard...");
                  try {
                    const clientPubkey = "e6/0jubRkV9t459F3tPKZ4mG00H7DlAzW/aWZrRIw1k=";
                    const result = await setupWgNode(clientPubkey);
                    console.log("WireGuard result:", result);
                    setWgSetupStatus("WireGuard active!");
                    const ip = await getLocalIp();
                    setLocalIp(ip);
                  } catch (err) {
                    console.error("WireGuard error:", err);
                    setWgSetupStatus("Failed: " + (err instanceof Error ? err.message : String(err)));
                  }
                }}
                disabled={isLoading}
              >
                Activate WireGuard Manually
              </button>
              {wgSetupStatus && (
                <p className="text-sm text-muted" style={{ marginTop: "8px", textAlign: "center" }}>
                  {wgSetupStatus}
                </p>
              )}
            </div>
          )}
        </div>

        <div className="card">
          <h3 style={{ marginBottom: "16px" }}>Node Info</h3>
          <div className="flex justify-between mb-4">
            <span className="text-muted">Price per GB:</span>
            <span>{formatFLR(myNode.bandwidthPrice)} FLR</span>
          </div>
          <div className="flex justify-between mb-4">
            <span className="text-muted">Stake:</span>
            <span>{formatFLR(myNode.stakedAmount)} FLR</span>
          </div>
          <div className="flex justify-between mb-4">
            <span className="text-muted">Rating:</span>
            <span>
              {"*".repeat(Math.floor(Number(myNode.rating) / 100))}
              {"-".repeat(5 - Math.floor(Number(myNode.rating) / 100))}
              {" "}({(Number(myNode.rating) / 100).toFixed(1)})
            </span>
          </div>
          <div className="flex justify-between mb-4">
            <span className="text-muted">Uptime Score:</span>
            <span>{myNode.uptimeScore.toString()}%</span>
          </div>
          <div className="flex justify-between mb-4">
            <span className="text-muted">Total Bandwidth:</span>
            <span>{formatBytes(totalBandwidth)}</span>
          </div>
          <div className="flex justify-between mb-4">
            <span className="text-muted">WG Public Key:</span>
            <span className="text-sm" style={{ fontFamily: "monospace", maxWidth: "150px", overflow: "hidden", textOverflow: "ellipsis" }}>
              {myNode.publicKey.substring(0, 12)}...
            </span>
          </div>

          <div className="flex gap-2" style={{ marginTop: "12px" }}>
            <button
              className="btn btn-outline"
              onClick={handleUpdateKeys}
              disabled={isLoading}
              style={{ flex: 1 }}
            >
              {isLoading ? "..." : "Update IP & Keys"}
            </button>
            <button
              className="btn btn-outline"
              onClick={handleHeartbeat}
              disabled={isLoading}
              style={{ flex: 1 }}
            >
              {isLoading ? "..." : "Send Heartbeat"}
            </button>
          </div>
        </div>

        {/* WireGuard Live Stats */}
        {myNode.isActive && (
          <div className="card" style={{ background: "linear-gradient(135deg, #1a1a2e 0%, #16213e 100%)", color: "#fff" }}>
            <div className="flex justify-between items-center mb-4">
              <h3 style={{ color: "#fff" }}>WireGuard Status</h3>
              <span className={`status-badge ${wgLiveStats ? "status-online" : "status-warning"}`}>
                {wgLiveStats ? "Running" : "Not Running"}
              </span>
            </div>

            {wgSetupStatus && (
              <div className="alert alert-success" style={{ marginBottom: "12px", fontSize: "12px" }}>
                {wgSetupStatus}
              </div>
            )}

            {/* Network Info */}
            <div style={{ background: "rgba(255,255,255,0.1)", padding: "16px", borderRadius: "8px", marginBottom: "16px" }}>
              <h4 style={{ fontSize: "14px", marginBottom: "12px", color: "#fff" }}>Network Info</h4>
              <div className="flex justify-between mb-2">
                <span style={{ color: "rgba(255,255,255,0.7)" }}>Local IP:</span>
                <span style={{ fontFamily: "monospace" }}>{localIp || "Fetching..."}</span>
              </div>
              <div className="flex justify-between mb-2">
                <span style={{ color: "rgba(255,255,255,0.7)" }}>VPN Address:</span>
                <span style={{ fontFamily: "monospace" }}>10.0.0.1</span>
              </div>
              <div className="flex justify-between mb-2">
                <span style={{ color: "rgba(255,255,255,0.7)" }}>Listen Port:</span>
                <span>{wgLiveStats?.listen_port || 51820}</span>
              </div>
              <div className="flex justify-between">
                <span style={{ color: "rgba(255,255,255,0.7)" }}>Interface:</span>
                <span style={{ fontFamily: "monospace" }}>{wgLiveStats?.interface || "wg0"}</span>
              </div>
            </div>

            {/* Traffic Stats */}
            <div style={{ background: "rgba(255,255,255,0.1)", padding: "16px", borderRadius: "8px", marginBottom: "16px" }}>
              <h4 style={{ fontSize: "14px", marginBottom: "12px", color: "#fff" }}>Traffic Stats</h4>
              {wgLiveStats?.peers && wgLiveStats.peers.length > 0 ? (
                <>
                  <div className="flex justify-between mb-2">
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Connected Peers:</span>
                    <span style={{ color: "#10b981" }}>{wgLiveStats.peers.length}</span>
                  </div>
                  <div className="flex justify-between mb-2">
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Data Received:</span>
                    <span style={{ color: "#10b981" }}>{formatBytes(BigInt(wgLiveStats.peers[0]?.transfer_rx || 0))}</span>
                  </div>
                  <div className="flex justify-between mb-2">
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Data Sent:</span>
                    <span style={{ color: "#e72058" }}>{formatBytes(BigInt(wgLiveStats.peers[0]?.transfer_tx || 0))}</span>
                  </div>
                  <div className="flex justify-between">
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Last Handshake:</span>
                    <span style={{ color: wgLiveStats.peers[0]?.latest_handshake > 0 ? "#10b981" : "#f59e0b" }}>
                      {wgLiveStats.peers[0]?.latest_handshake > 0
                        ? `${Math.floor((Date.now() / 1000 - wgLiveStats.peers[0].latest_handshake))}s ago`
                        : "Waiting..."}
                    </span>
                  </div>
                </>
              ) : (
                <>
                  <div className="flex justify-between mb-2">
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Connected Peers:</span>
                    <span style={{ color: "#f59e0b" }}>0</span>
                  </div>
                  <div className="flex justify-between mb-2">
                    <span style={{ color: "rgba(255,255,255,0.7)" }}>Simulated Data:</span>
                    <span style={{ color: "#e72058" }}>{formatBytes(simulatedBytes)}</span>
                  </div>
                </>
              )}
            </div>

            {/* Simulate Traffic for Escrow Testing */}
            <div style={{ background: "rgba(231,32,88,0.2)", padding: "16px", borderRadius: "8px", marginBottom: "16px" }}>
              <h4 style={{ fontSize: "14px", marginBottom: "8px", color: "#fff" }}>Escrow Testing</h4>
              <p style={{ fontSize: "12px", color: "rgba(255,255,255,0.7)", marginBottom: "12px" }}>
                Simulate bandwidth usage to test escrow payments
              </p>
              <div className="flex gap-2">
                <button
                  className="btn btn-primary"
                  style={{ flex: 1, padding: "8px" }}
                  onClick={() => {
                    setSimulatedBytes(prev => prev + BigInt(1024 * 1024 * 10)); // Add 10 MB
                  }}
                >
                  +10 MB
                </button>
                <button
                  className="btn btn-primary"
                  style={{ flex: 1, padding: "8px" }}
                  onClick={() => {
                    setSimulatedBytes(prev => prev + BigInt(1024 * 1024 * 100)); // Add 100 MB
                  }}
                >
                  +100 MB
                </button>
                <button
                  className="btn btn-outline"
                  style={{ flex: 1, padding: "8px", color: "#fff", borderColor: "rgba(255,255,255,0.3)" }}
                  onClick={() => setSimulatedBytes(0n)}
                >
                  Reset
                </button>
              </div>
            </div>

            {/* Public Key */}
            <div style={{ background: "rgba(255,255,255,0.05)", padding: "12px", borderRadius: "8px" }}>
              <div style={{ fontSize: "12px", color: "rgba(255,255,255,0.5)", marginBottom: "4px" }}>Node Public Key:</div>
              <div style={{ fontFamily: "monospace", fontSize: "11px", wordBreak: "break-all" }}>
                {wgLiveStats?.public_key || myNode.publicKey || "cxQI5Fo41hUTcAEpH/uPaKqO7+xsjXd9D6WYz+0ySxI="}
              </div>
            </div>
          </div>
        )}

        <div className="card">
          <h3 style={{ marginBottom: "16px" }}>Active Sessions ({activeSessions.length})</h3>
          {activeSessions.length === 0 ? (
            <p className="text-muted text-center" style={{ padding: "20px" }}>
              No active sessions. Waiting for users to connect...
            </p>
          ) : (
            <div className="session-list">
              {activeSessions.map((session) => (
                <div key={session.id.toString()} className="session-item">
                  <div>
                    <strong>{shortenAddress(session.user)}</strong>
                    <p className="text-sm text-muted">
                      {formatBytes(session.bytesUsed)} used
                    </p>
                  </div>
                  <div className="text-right">
                    <span className="text-success">
                      +{formatFLR((session.bytesUsed * myNode.bandwidthPrice) / (1024n * 1024n * 1024n))} FLR
                    </span>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Danger Zone */}
        <div className="card" style={{ border: "2px solid #ff4444", marginTop: "16px" }}>
          <h3 style={{ marginBottom: "8px", color: "#ff4444" }}>Danger Zone</h3>

          {/* Node status: 0=None, 1=Active, 2=Inactive, 3=Unstaking */}
          {myNode.status === 3 ? (
            <>
              <p style={{ marginBottom: "16px", color: "#ffaa00" }}>
                Unstaking in progress. Your stake will be available after the lock period.
              </p>
              <button
                type="button"
                style={{
                  width: "100%",
                  padding: "16px",
                  backgroundColor: "#ff4444",
                  color: "white",
                  border: "none",
                  borderRadius: "8px",
                  fontSize: "16px",
                  fontWeight: "bold",
                  cursor: isLoading ? "not-allowed" : "pointer",
                }}
                onClick={handleWithdrawStake}
                disabled={isLoading}
              >
                {isLoading ? "Processing..." : `Withdraw ${formatFLR(myNode.stakedAmount)} FLR`}
              </button>
              <p className="text-muted text-sm" style={{ marginTop: "8px" }}>
                If lock period has passed, click to withdraw your stake.
              </p>
            </>
          ) : !showDeregisterConfirm ? (
            <>
              <p className="text-muted text-sm" style={{ marginBottom: "16px" }}>
                Deregister your node and withdraw your staked FLR. (2-step process with lock period)
              </p>
              <button
                type="button"
                style={{
                  width: "100%",
                  padding: "16px",
                  backgroundColor: "#ff4444",
                  color: "white",
                  border: "none",
                  borderRadius: "8px",
                  fontSize: "16px",
                  fontWeight: "bold",
                  cursor: isLoading ? "not-allowed" : "pointer",
                }}
                onClick={handleDeregister}
                disabled={isLoading}
              >
                {isLoading ? "Processing..." : "Start Unstaking Process"}
              </button>
            </>
          ) : (
            <>
              <p style={{ marginBottom: "16px", color: "#ff4444", fontWeight: "bold" }}>
                Are you sure? This will:
              </p>
              <ul style={{ marginBottom: "16px", paddingLeft: "20px", fontSize: "14px" }}>
                <li>Deactivate your node</li>
                <li>Start unstaking (lock period applies)</li>
                <li>Remove your node from the network</li>
              </ul>
              <div style={{ display: "flex", gap: "12px" }}>
                <button
                  type="button"
                  style={{
                    flex: 1,
                    padding: "14px",
                    backgroundColor: "#333",
                    color: "white",
                    border: "none",
                    borderRadius: "8px",
                    fontSize: "14px",
                    cursor: "pointer",
                  }}
                  onClick={() => setShowDeregisterConfirm(false)}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  style={{
                    flex: 1,
                    padding: "14px",
                    backgroundColor: "#ff4444",
                    color: "white",
                    border: "none",
                    borderRadius: "8px",
                    fontSize: "14px",
                    fontWeight: "bold",
                    cursor: isLoading ? "not-allowed" : "pointer",
                  }}
                  onClick={confirmDeregister}
                  disabled={isLoading}
                >
                  {isLoading ? "..." : "Yes, Start Unstaking"}
                </button>
              </div>
            </>
          )}

          {!registryContract && (
            <p style={{ color: "#ff4444", fontSize: "12px", marginTop: "8px" }}>
              Wallet not connected - please reconnect
            </p>
          )}
        </div>
      </div>
    );
  }

  return null;
}

export default NodeMode;
