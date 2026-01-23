import { useState } from "react";
import { useWallet } from "./hooks/useWallet";
import { shortenAddress } from "./utils/contract";
import NodeMode from "./pages/NodeMode";
import ClientMode from "./pages/ClientMode";
import PixelBlast from "./components/PixelBlast";

type AppMode = "select" | "client" | "node";

function App() {
  const [mode, setMode] = useState<AppMode>("select");
  const {
    wallet,
    registryContract,
    escrowContract,
    isLoading,
    error,
    connect,
    connectMetaMask,
    connectWalletConnect,
    disconnect,
    switchNetwork,
    showWalletOptions,
    setShowWalletOptions,
    clearError,
  } = useWallet();

  // Background component
  const Background = () => (
    <div className="pixel-blast-bg">
      <PixelBlast
        variant="square"
        pixelSize={4}
        color="#e72058"
        patternScale={2}
        patternDensity={1}
        pixelSizeJitter={0}
        enableRipples
        rippleSpeed={0.4}
        rippleThickness={0.12}
        rippleIntensityScale={1.5}
        liquid={false}
        speed={0.5}
        edgeFade={0.25}
        transparent
      />
    </div>
  );

  // Show loading spinner during initial auto-connect check
  if (isLoading && !wallet.isConnected && !showWalletOptions) {
    return (
      <>
        <Background />
        <div className="container">
          <header className="header" style={{ background: "transparent", border: "none" }}>
            <div className="logo">DeVPN</div>
            <div></div>
          </header>
          <div style={{ textAlign: "center", marginTop: "120px" }}>
            <div className="spinner" style={{ margin: "0 auto 24px" }}></div>
            <p className="text-muted">Checking wallet connection...</p>
          </div>
        </div>
      </>
    );
  }

  // Mode Selection Screen
  if (mode === "select") {
    return (
      <>
        <Background />
        <div className="container">
        <header className="header" style={{ background: "transparent", border: "none" }}>
          <div className="logo">DeVPN</div>
          {wallet.isConnected ? (
            <div className="wallet-info">
              <span className="wallet-address">{shortenAddress(wallet.address!)}</span>
              <span className="wallet-balance">{parseFloat(wallet.balance).toFixed(4)} {wallet.isCorrectNetwork ? "C2FLR" : "?"}</span>
              {!wallet.isCorrectNetwork && (
                <span style={{ color: "var(--warning)", fontSize: "12px", marginLeft: "8px" }}>
                  (Wrong Network)
                </span>
              )}
              <button className="btn btn-outline" onClick={disconnect} style={{ padding: "8px 16px", marginLeft: "12px" }}>
                Disconnect
              </button>
            </div>
          ) : (
            <button className="btn btn-primary" onClick={connect} disabled={isLoading}>
              {isLoading ? "Connecting..." : "Connect Wallet"}
            </button>
          )}
        </header>

        {error && (
          <div className="alert alert-error" onClick={clearError} style={{ cursor: "pointer" }}>
            {error}
          </div>
        )}

        {/* Wallet Selection Modal */}
        {showWalletOptions && (
          <div className="modal-overlay" onClick={() => setShowWalletOptions(false)}>
            <div className="modal-content" onClick={(e) => e.stopPropagation()}>
              <h2>Connect Wallet</h2>
              <p className="text-muted" style={{ marginBottom: "24px" }}>
                Choose connection method
              </p>

              <button
                className="btn btn-primary btn-full"
                style={{ marginBottom: "12px", padding: "14px" }}
                onClick={connectMetaMask}
                disabled={isLoading}
              >
                MetaMask Browser
              </button>

              <button
                className="btn btn-outline btn-full"
                style={{ padding: "14px" }}
                onClick={connectWalletConnect}
                disabled={isLoading}
              >
                WalletConnect Mobile
              </button>

              <p className="text-muted text-sm" style={{ marginTop: "16px" }}>
                {isLoading ? "Connecting..." : "Scan QR with mobile wallet"}
              </p>

              <button
                className="btn-link"
                style={{ marginTop: "12px" }}
                onClick={() => setShowWalletOptions(false)}
              >
                Cancel
              </button>
            </div>
          </div>
        )}

        {wallet.isConnected && !wallet.isCorrectNetwork && (
          <div className="card" style={{ background: "var(--warning)", color: "#000", marginBottom: "24px" }}>
            <h3 style={{ marginBottom: "8px" }}>Wrong Network</h3>
            <p style={{ marginBottom: "16px", opacity: 0.8 }}>
              Please switch to Coston2 Testnet (Chain ID: 114)
            </p>
            <button
              className="btn btn-primary"
              onClick={switchNetwork}
              disabled={isLoading}
              style={{ background: "#000", color: "#fff" }}
            >
              {isLoading ? "Switching..." : "Switch to Coston2 Testnet"}
            </button>
            <p className="text-sm" style={{ marginTop: "12px", opacity: 0.7 }}>
              Or add manually: RPC: https://coston2-api.flare.network/ext/C/rpc
            </p>
          </div>
        )}

        <div style={{ textAlign: "center", marginTop: "60px" }}>
          <h1 style={{ fontSize: "42px", marginBottom: "12px", fontWeight: "600" }}>DeVPN</h1>
          <p className="text-muted" style={{ fontSize: "16px", marginBottom: "48px" }}>
            Decentralized VPN on Flare Network
          </p>
        </div>

        <div className="mode-selector">
          <div
            className={`mode-card ${!wallet.isConnected || !wallet.isCorrectNetwork ? "disabled" : ""}`}
            onClick={() => wallet.isConnected && wallet.isCorrectNetwork && setMode("client")}
          >
            <div className="mode-icon">CLIENT</div>
            <div className="mode-title">Use VPN</div>
            <div className="mode-desc">Connect to nodes and browse privately</div>
          </div>

          <div
            className={`mode-card ${!wallet.isConnected || !wallet.isCorrectNetwork ? "disabled" : ""}`}
            onClick={() => wallet.isConnected && wallet.isCorrectNetwork && setMode("node")}
          >
            <div className="mode-icon">NODE</div>
            <div className="mode-title">Run Node</div>
            <div className="mode-desc">Share bandwidth and earn FLR</div>
          </div>
        </div>

        {!wallet.isConnected && (
          <p className="text-muted" style={{ textAlign: "center", marginTop: "24px" }}>
            Connect wallet to continue
          </p>
        )}

        {wallet.isConnected && !wallet.isCorrectNetwork && (
          <p className="text-muted" style={{ textAlign: "center", marginTop: "24px" }}>
            Switch to Coston2 Testnet to continue
          </p>
        )}

        <div style={{ textAlign: "center", marginTop: "60px" }}>
          <p className="text-muted text-sm">Flare Network | Coston2 Testnet</p>
          {wallet.isConnected && (
            <p className="text-muted text-sm" style={{ marginTop: "8px" }}>
              Connected Chain: {wallet.chainId} {wallet.chainId === 114 ? "(Coston2)" : "(Not Coston2)"}
            </p>
          )}
        </div>
      </div>
      </>
    );
  }

  // Client Mode
  if (mode === "client") {
    return (
      <>
        <Background />
        <ClientMode onBack={() => setMode("select")} wallet={wallet} contract={registryContract} escrowContract={escrowContract} />
      </>
    );
  }

  // Node Mode
  if (mode === "node") {
    return (
      <>
        <Background />
        <NodeMode onBack={() => setMode("select")} wallet={wallet} registryContract={registryContract} escrowContract={escrowContract} />
      </>
    );
  }

  return null;
}

export default App;
