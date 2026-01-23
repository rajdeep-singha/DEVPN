mod network;
mod node;
mod tailscale;
mod wireguard;

use node::{ActiveSession, NodeConfig, SharedNodeState};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tauri::State;
use tokio::sync::RwLock;

// ============ Response Types ============

#[derive(Debug, Serialize, Deserialize)]
pub struct NetworkCheckResult {
    pub public_ip: String,
    pub local_ip: String,
    pub country_code: String,
    pub port_open: bool,
    pub upload_speed: String,
    pub wireguard_installed: bool,
    pub internet_connected: bool,
    pub is_hotspot: bool,
    pub active_interface: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct NodeStatus {
    pub is_running: bool,
    pub is_registered: bool,
    pub node_id: Option<u64>,
    pub endpoint: String,
    pub location: String,
    pub price_per_gb: String,
    pub public_key: String,
    pub active_sessions: usize,
    pub total_earnings: u64,
    pub total_bytes_served: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SessionInfo {
    pub session_id: u64,
    pub user_address: String,
    pub bytes_used: u64,
    pub duration_secs: u64,
    pub earnings: String,
}

// ============ State Management ============

struct AppState {
    node_state: SharedNodeState,
    ip_allocator: Arc<RwLock<node::IpAllocator>>,
    wg_stats_cache: Arc<RwLock<HashMap<String, wireguard::WireGuardPeer>>>,
}

// ============ Tauri Commands ============

/// Check network status
#[tauri::command]
async fn check_network() -> Result<NetworkCheckResult, String> {
    let status = network::get_network_status().await;
    let wg_installed = wireguard::is_wireguard_installed();

    Ok(NetworkCheckResult {
        public_ip: status.public_ip,
        local_ip: status.local_ip,
        country_code: status.country_code,
        port_open: status.port_open,
        upload_speed: status.upload_speed,
        wireguard_installed: wg_installed,
        internet_connected: status.internet_connected,
        is_hotspot: status.is_hotspot,
        active_interface: status.active_interface,
    })
}

/// Generate WireGuard keys
#[tauri::command]
async fn generate_wg_keys() -> Result<wireguard::WireGuardKeys, String> {
    let keys = wireguard::generate_keypair();
    wireguard::save_keys(&keys)?;
    Ok(keys)
}

/// Get or create WireGuard keys
#[tauri::command]
async fn get_wg_keys() -> Result<wireguard::WireGuardKeys, String> {
    wireguard::load_keys()
}

/// Initialize node with config
#[tauri::command]
async fn init_node(
    state: State<'_, AppState>,
    endpoint: String,
    location: String,
    price_per_gb: String,
    stake_amount: String,
) -> Result<NodeConfig, String> {
    let keys = wireguard::load_keys()?;

    let config = NodeConfig {
        node_id: None, // Will be set after blockchain registration
        endpoint,
        location,
        price_per_gb,
        stake_amount,
        is_active: false,
        wg_keys: keys,
    };

    // Save config
    node::save_config(&config)?;

    // Update state
    let mut node_state = state.node_state.write().await;
    node_state.config = Some(config.clone());

    Ok(config)
}

/// Start the node (after blockchain registration)
#[tauri::command]
async fn start_node(
    state: State<'_, AppState>,
    node_id: u64,
) -> Result<(), String> {
    let mut node_state = state.node_state.write().await;

    if let Some(ref mut config) = node_state.config {
        config.node_id = Some(node_id);
        config.is_active = true;

        // Save updated config
        node::save_config(config)?;

        // Create WireGuard interface
        let ip_allocator = state.ip_allocator.read().await;
        let wg_config = wireguard::WireGuardConfig {
            interface: wireguard::WireGuardInterface {
                private_key: config.wg_keys.private_key.clone(),
                address: ip_allocator.get_server_address(),
                listen_port: 51820,
            },
            peers: vec![],
        };

        // Try to create interface (may fail if WireGuard not installed)
        if let Err(e) = wireguard::create_interface("devpn0", &wg_config) {
            log::warn!("Could not create WireGuard interface: {}", e);
            // Continue anyway - user might set it up manually
        }

        node_state.is_running = true;
    } else {
        return Err("Node not initialized".to_string());
    }

    Ok(())
}

/// Stop the node
#[tauri::command]
async fn stop_node(state: State<'_, AppState>) -> Result<(), String> {
    let mut node_state = state.node_state.write().await;

    if let Some(ref mut config) = node_state.config {
        config.is_active = false;
        node::save_config(config)?;
    }

    node_state.is_running = false;

    Ok(())
}

/// Get node status
#[tauri::command]
async fn get_node_status(state: State<'_, AppState>) -> Result<NodeStatus, String> {
    let node_state = state.node_state.read().await;

    let (is_registered, node_id, endpoint, location, price_per_gb, public_key) =
        if let Some(ref config) = node_state.config {
            (
                config.node_id.is_some(),
                config.node_id,
                config.endpoint.clone(),
                config.location.clone(),
                config.price_per_gb.clone(),
                config.wg_keys.public_key.clone(),
            )
        } else {
            (false, None, String::new(), String::new(), String::new(), String::new())
        };

    let total_bytes: u64 = node_state
        .sessions
        .values()
        .map(|s| s.bytes_used)
        .sum();

    Ok(NodeStatus {
        is_running: node_state.is_running,
        is_registered,
        node_id,
        endpoint,
        location,
        price_per_gb,
        public_key,
        active_sessions: node_state.sessions.len(),
        total_earnings: node_state.total_earnings,
        total_bytes_served: total_bytes,
    })
}

/// Handle new session from blockchain event
#[tauri::command]
async fn add_session(
    state: State<'_, AppState>,
    session_id: u64,
    user_address: String,
    user_wg_pubkey: String,
    deposit: String,
) -> Result<String, String> {
    let mut node_state = state.node_state.write().await;
    let mut ip_allocator = state.ip_allocator.write().await;

    // Allocate IP for user
    let assigned_ip = ip_allocator.allocate(&user_wg_pubkey)?;

    // Add peer to WireGuard - detect actual interface name (utun6 on macOS)
    let wg_interface = wireguard::get_active_interface().unwrap_or_else(|| "devpn0".to_string());
    if let Err(e) = wireguard::add_peer(&wg_interface, &user_wg_pubkey, &assigned_ip) {
        log::warn!("Could not add WireGuard peer to {}: {}", wg_interface, e);
    } else {
        log::info!("Added peer {} to interface {}", user_wg_pubkey, wg_interface);
    }

    // Create session
    let session = ActiveSession {
        session_id,
        user_address,
        user_wg_pubkey: user_wg_pubkey.clone(),
        deposit,
        start_time: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs(),
        bytes_used: 0,
        assigned_ip: assigned_ip.clone(),
    };

    node_state.sessions.insert(user_wg_pubkey, session);
    node_state.total_sessions += 1;

    Ok(assigned_ip)
}

/// Remove session (when ended)
#[tauri::command]
async fn remove_session(
    state: State<'_, AppState>,
    user_wg_pubkey: String,
) -> Result<u64, String> {
    let mut node_state = state.node_state.write().await;
    let mut ip_allocator = state.ip_allocator.write().await;

    // Get final bytes count before removing
    let bytes_used = node_state
        .sessions
        .get(&user_wg_pubkey)
        .map(|s| s.bytes_used)
        .unwrap_or(0);

    // Remove peer from WireGuard - detect actual interface name
    let wg_interface = wireguard::get_active_interface().unwrap_or_else(|| "devpn0".to_string());
    if let Err(e) = wireguard::remove_peer(&wg_interface, &user_wg_pubkey) {
        log::warn!("Could not remove WireGuard peer from {}: {}", wg_interface, e);
    } else {
        log::info!("Removed peer {} from interface {}", user_wg_pubkey, wg_interface);
    }

    // Release IP
    ip_allocator.release(&user_wg_pubkey);

    // Remove session
    node_state.sessions.remove(&user_wg_pubkey);

    Ok(bytes_used)
}

/// Update bandwidth stats for all sessions
#[tauri::command]
async fn update_bandwidth_stats(state: State<'_, AppState>) -> Result<Vec<SessionInfo>, String> {
    let mut node_state = state.node_state.write().await;
    let mut stats_cache = state.wg_stats_cache.write().await;

    // Get current WireGuard stats
    let wg_interface = wireguard::get_active_interface().unwrap_or_else(|| "devpn0".to_string());
    let new_stats = wireguard::get_interface_stats(&wg_interface).unwrap_or_default();

    // Update each session
    let mut session_infos = Vec::new();

    for (pubkey, session) in node_state.sessions.iter_mut() {
        let delta = node::calculate_bandwidth_delta(&stats_cache, &new_stats, pubkey);
        session.bytes_used += delta;

        let duration = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - session.start_time;

        session_infos.push(SessionInfo {
            session_id: session.session_id,
            user_address: session.user_address.clone(),
            bytes_used: session.bytes_used,
            duration_secs: duration,
            earnings: format!("{:.4}", session.bytes_used as f64 / 1e9), // Approximate
        });
    }

    // Update cache
    *stats_cache = new_stats;

    Ok(session_infos)
}

/// Get session info by pubkey
#[tauri::command]
async fn get_session_bytes(
    state: State<'_, AppState>,
    user_wg_pubkey: String,
) -> Result<u64, String> {
    let node_state = state.node_state.read().await;

    node_state
        .sessions
        .get(&user_wg_pubkey)
        .map(|s| s.bytes_used)
        .ok_or_else(|| "Session not found".to_string())
}

/// Load saved node config
#[tauri::command]
async fn load_saved_config(state: State<'_, AppState>) -> Result<Option<NodeConfig>, String> {
    let config = node::load_config()?;

    if let Some(ref cfg) = config {
        let mut node_state = state.node_state.write().await;
        node_state.config = Some(cfg.clone());
    }

    Ok(config)
}

/// Try UPnP port forwarding
#[tauri::command]
async fn try_upnp() -> Result<bool, String> {
    network::try_upnp_forward(51820)
}

/// Get all active sessions
#[tauri::command]
async fn get_active_sessions(state: State<'_, AppState>) -> Result<Vec<ActiveSession>, String> {
    let node_state = state.node_state.read().await;
    Ok(node_state.sessions.values().cloned().collect())
}

// ============ Client Commands ============

#[derive(Debug, Serialize, Deserialize)]
pub struct VpnConnectionInfo {
    pub connected: bool,
    pub server_endpoint: String,
    pub assigned_ip: String,
    pub server_public_key: String,
    pub client_public_key: String,
    pub interface_name: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct VpnStatus {
    pub connected: bool,
    pub interface_name: Option<String>,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    pub last_handshake: u64,
    pub server_endpoint: Option<String>,
}

/// Connect to a VPN node as a client
#[tauri::command]
async fn connect_vpn(
    server_endpoint: String,
    server_public_key: String,
) -> Result<VpnConnectionInfo, String> {
    // Get or generate our WireGuard keys
    let keys = wireguard::load_keys()?;
    let client_public_key = keys.public_key.clone();

    // Client address in the VPN
    let client_address = "10.0.0.2/32".to_string();

    // Create WireGuard client config with DNS
    let config_content = format!(
        r#"[Interface]
PrivateKey = {}
Address = {}
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = {}
Endpoint = {}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
"#,
        keys.private_key,
        client_address,
        server_public_key,
        server_endpoint
    );

    // Save config file
    let config_dir = wireguard::get_config_dir()?;
    let config_path = config_dir.join("devpn-client.conf");
    std::fs::write(&config_path, &config_content).map_err(|e| e.to_string())?;

    log::info!("Saved WireGuard client config to {:?}", config_path);

    // Platform-specific VPN connection
    #[cfg(target_os = "windows")]
    {
        connect_vpn_windows(&config_path)?;
    }

    #[cfg(not(target_os = "windows"))]
    {
        connect_vpn_unix(&config_path)?;
    }

    log::info!("VPN interface created successfully");

    // Get the interface name that was created
    let interface_name = wireguard::get_active_interface();
    log::info!("Active WireGuard interface: {:?}", interface_name);

    Ok(VpnConnectionInfo {
        connected: true,
        server_endpoint,
        assigned_ip: client_address,
        server_public_key,
        client_public_key,
        interface_name,
    })
}

/// Unix (macOS/Linux) VPN connection using wg-quick
#[cfg(not(target_os = "windows"))]
fn connect_vpn_unix(config_path: &std::path::Path) -> Result<(), String> {
    // First try to bring down any existing connection
    let _ = std::process::Command::new("sudo")
        .args(["wg-quick", "down", config_path.to_str().unwrap()])
        .output();

    // Bring up the interface using sudo wg-quick
    let output = std::process::Command::new("sudo")
        .args(["wg-quick", "up", config_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("Failed to run wg-quick: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        log::error!("wg-quick up failed: {} {}", stderr, stdout);
        return Err(format!("Failed to connect VPN: {}", stderr));
    }

    Ok(())
}

/// Windows VPN connection using WireGuard service
#[cfg(target_os = "windows")]
fn connect_vpn_windows(config_path: &std::path::Path) -> Result<(), String> {
    // Find WireGuard installation
    let wireguard_exe = find_wireguard_exe()?;

    // First try to uninstall any existing tunnel
    let _ = std::process::Command::new(&wireguard_exe)
        .args(["/uninstalltunnelservice", "devpn-client"])
        .output();

    // Small delay to ensure service is fully stopped
    std::thread::sleep(std::time::Duration::from_millis(500));

    // Install and start the tunnel service
    let output = std::process::Command::new(&wireguard_exe)
        .args(["/installtunnelservice", config_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("Failed to run wireguard.exe: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        log::error!("WireGuard tunnel install failed: {} {}", stderr, stdout);
        return Err(format!("Failed to connect VPN: {}. Make sure WireGuard is installed and you're running as Administrator.", stderr));
    }

    // Configure DNS via netsh (WireGuard on Windows doesn't always set DNS properly)
    let _ = std::process::Command::new("netsh")
        .args(["interface", "ip", "set", "dns", "name=devpn-client", "static", "1.1.1.1", "primary"])
        .output();

    let _ = std::process::Command::new("netsh")
        .args(["interface", "ip", "add", "dns", "name=devpn-client", "8.8.8.8", "index=2"])
        .output();

    Ok(())
}

/// Find WireGuard executable on Windows
#[cfg(target_os = "windows")]
fn find_wireguard_exe() -> Result<String, String> {
    // Common installation paths
    let paths = [
        r"C:\Program Files\WireGuard\wireguard.exe",
        r"C:\Program Files (x86)\WireGuard\wireguard.exe",
    ];

    for path in &paths {
        if std::path::Path::new(path).exists() {
            return Ok(path.to_string());
        }
    }

    // Try PATH
    if let Ok(output) = std::process::Command::new("where").arg("wireguard.exe").output() {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout);
            if let Some(first_line) = path.lines().next() {
                return Ok(first_line.trim().to_string());
            }
        }
    }

    Err("WireGuard not found. Please install WireGuard from https://www.wireguard.com/install/".to_string())
}

/// Disconnect from VPN
#[tauri::command]
async fn disconnect_vpn() -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        disconnect_vpn_windows()?;
    }

    #[cfg(not(target_os = "windows"))]
    {
        disconnect_vpn_unix()?;
    }

    log::info!("VPN disconnected");
    Ok(())
}

/// Unix (macOS/Linux) VPN disconnection
#[cfg(not(target_os = "windows"))]
fn disconnect_vpn_unix() -> Result<(), String> {
    let config_dir = wireguard::get_config_dir()?;
    let config_path = config_dir.join("devpn-client.conf");

    // Bring down the interface using sudo
    let output = std::process::Command::new("sudo")
        .args(["wg-quick", "down", config_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("Failed to run wg-quick: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // Ignore "not found" errors (interface already down)
        if !stderr.contains("is not a") && !stderr.contains("does not exist") {
            log::warn!("wg-quick down warning: {}", stderr);
        }
    }

    Ok(())
}

/// Windows VPN disconnection
#[cfg(target_os = "windows")]
fn disconnect_vpn_windows() -> Result<(), String> {
    // Find WireGuard installation
    let wireguard_exe = find_wireguard_exe()?;

    // Uninstall the tunnel service
    let output = std::process::Command::new(&wireguard_exe)
        .args(["/uninstalltunnelservice", "devpn-client"])
        .output()
        .map_err(|e| format!("Failed to run wireguard.exe: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // Ignore if tunnel doesn't exist
        if !stderr.contains("not found") && !stderr.contains("does not exist") {
            log::warn!("WireGuard tunnel uninstall warning: {}", stderr);
        }
    }

    Ok(())
}

/// Check VPN connection status with details
#[tauri::command]
async fn get_vpn_status() -> Result<VpnStatus, String> {
    // Check if any WireGuard interface exists
    let interface = wireguard::get_active_interface();

    if interface.is_none() {
        return Ok(VpnStatus {
            connected: false,
            interface_name: None,
            bytes_sent: 0,
            bytes_received: 0,
            last_handshake: 0,
            server_endpoint: None,
        });
    }

    let iface = interface.unwrap();

    // Get stats from the interface
    let stats = wireguard::get_interface_stats(&iface).unwrap_or_default();

    // Get the peer info (there should be one peer for client mode)
    let (bytes_sent, bytes_received, last_handshake, endpoint) = stats
        .values()
        .next()
        .map(|p| (p.bytes_sent, p.bytes_received, 0u64, p.endpoint.clone()))
        .unwrap_or((0, 0, 0, None));

    Ok(VpnStatus {
        connected: true,
        interface_name: Some(iface),
        bytes_sent,
        bytes_received,
        last_handshake,
        server_endpoint: endpoint,
    })
}

// ============ Tailscale Commands ============

#[tauri::command]
fn tailscale_status() -> tailscale::TailscaleStatus {
    tailscale::get_status()
}

#[tauri::command]
fn tailscale_install() -> Result<(), String> {
    tailscale::install()
}

#[tauri::command]
fn tailscale_start() -> Result<(), String> {
    tailscale::start_daemon()
}

#[tauri::command]
fn tailscale_authenticate(auth_key: Option<String>) -> Result<(), String> {
    if let Some(key) = auth_key {
        tailscale::authenticate_with_key(&key)
    } else {
        tailscale::authenticate_interactive()
    }
}

#[tauri::command]
fn tailscale_get_ip() -> Option<String> {
    tailscale::get_ip()
}

#[tauri::command]
fn tailscale_advertise_exit_node(enable: bool) -> Result<(), String> {
    tailscale::advertise_exit_node(enable)
}

#[tauri::command]
fn tailscale_connect_exit_node(exit_node_ip: String) -> Result<(), String> {
    tailscale::connect_exit_node(&exit_node_ip)
}

#[tauri::command]
fn tailscale_disconnect_exit_node() -> Result<(), String> {
    tailscale::disconnect_exit_node()
}

#[tauri::command]
fn tailscale_get_peers() -> Vec<tailscale::TailscalePeer> {
    tailscale::get_peers()
}

#[tauri::command]
fn tailscale_setup_node(auth_key: Option<String>) -> Result<tailscale::TailscaleStatus, String> {
    tailscale::setup_as_node(auth_key.as_deref())
}

#[tauri::command]
fn tailscale_setup_client(auth_key: Option<String>, exit_node_ip: String) -> Result<tailscale::TailscaleStatus, String> {
    tailscale::setup_as_client(auth_key.as_deref(), &exit_node_ip)
}

// ============ Live WireGuard Stats ============

#[derive(Debug, Serialize, Deserialize)]
pub struct WgLiveStats {
    pub interface: String,
    pub public_key: String,
    pub listen_port: u16,
    pub peers: Vec<WgPeerStats>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WgPeerStats {
    pub public_key: String,
    pub endpoint: Option<String>,
    pub allowed_ips: String,
    pub latest_handshake: u64,
    pub transfer_rx: u64,
    pub transfer_tx: u64,
    pub persistent_keepalive: u16,
}

/// Get live WireGuard statistics
#[tauri::command]
fn get_wg_live_stats() -> Result<WgLiveStats, String> {
    // Try different wg paths (homebrew and system)
    let wg_paths = [
        "/opt/homebrew/bin/wg",
        "/usr/local/bin/wg",
        "wg",
    ];

    let mut stdout_str = String::new();

    for wg_path in wg_paths {
        // Try without sudo first
        if let Ok(output) = std::process::Command::new(wg_path)
            .args(["show", "all", "dump"])
            .output()
        {
            if output.status.success() && !output.stdout.is_empty() {
                stdout_str = String::from_utf8_lossy(&output.stdout).to_string();
                break;
            }
        }
    }

    // If no luck, try using osascript to run with admin privileges
    if stdout_str.is_empty() {
        let osascript = r#"do shell script "/opt/homebrew/bin/wg show all dump 2>/dev/null || /usr/local/bin/wg show all dump 2>/dev/null || wg show all dump" with administrator privileges"#;
        if let Ok(output) = std::process::Command::new("osascript")
            .args(["-e", osascript])
            .output()
        {
            if output.status.success() {
                stdout_str = String::from_utf8_lossy(&output.stdout).to_string();
            }
        }
    }

    if stdout_str.is_empty() {
        return Err("WireGuard not running or no permission".to_string());
    }

    let lines: Vec<&str> = stdout_str.lines().collect();

    if lines.is_empty() {
        return Err("No WireGuard interface found".to_string());
    }

    // Parse the dump output
    // Format: interface, private_key, public_key, listen_port, fwmark
    // Then for each peer: interface, public_key, preshared_key, endpoint, allowed_ips, latest_handshake, transfer_rx, transfer_tx, persistent_keepalive

    let mut interface = String::new();
    let mut public_key = String::new();
    let mut listen_port = 0u16;
    let mut peers = Vec::new();

    for line in lines {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() >= 4 {
            if parts.len() == 5 {
                // Interface line
                interface = parts[0].to_string();
                public_key = parts[2].to_string();
                listen_port = parts[3].parse().unwrap_or(0);
            } else if parts.len() >= 8 {
                // Peer line
                peers.push(WgPeerStats {
                    public_key: parts[1].to_string(),
                    endpoint: if parts[3] == "(none)" { None } else { Some(parts[3].to_string()) },
                    allowed_ips: parts[4].to_string(),
                    latest_handshake: parts[5].parse().unwrap_or(0),
                    transfer_rx: parts[6].parse().unwrap_or(0),
                    transfer_tx: parts[7].parse().unwrap_or(0),
                    persistent_keepalive: parts.get(8).and_then(|s| s.parse().ok()).unwrap_or(0),
                });
            }
        }
    }

    Ok(WgLiveStats {
        interface,
        public_key,
        listen_port,
        peers,
    })
}

/// Run node setup script
#[tauri::command]
async fn run_node_setup() -> Result<String, String> {
    // Get the app's resource directory for scripts
    let script_content = include_str!("../../scripts/node-setup.sh");

    // Write to temp file
    let temp_path = std::env::temp_dir().join("devpn-node-setup.sh");
    std::fs::write(&temp_path, script_content).map_err(|e| e.to_string())?;

    // Make executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&temp_path, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| e.to_string())?;
    }

    // Run with osascript to get admin privileges (macOS)
    #[cfg(target_os = "macos")]
    {
        let script = format!(
            r#"do shell script "{}" with administrator privileges"#,
            temp_path.to_string_lossy().replace("\"", "\\\"")
        );

        let output = std::process::Command::new("osascript")
            .args(["-e", &script])
            .output()
            .map_err(|e| format!("Failed to run script: {}", e))?;

        if output.status.success() {
            Ok("Node setup completed".to_string())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("Setup failed: {}", stderr))
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("Auto setup only supported on macOS".to_string())
    }
}

/// Run client setup script
#[tauri::command]
async fn run_client_setup(node_ip: String) -> Result<String, String> {
    let script_content = include_str!("../../scripts/client-setup.sh");

    // Write to temp file
    let temp_path = std::env::temp_dir().join("devpn-client-setup.sh");
    std::fs::write(&temp_path, script_content).map_err(|e| e.to_string())?;

    // Make executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&temp_path, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| e.to_string())?;
    }

    // Run with osascript to get admin privileges (macOS)
    #[cfg(target_os = "macos")]
    {
        let script = format!(
            r#"do shell script "{} {}" with administrator privileges"#,
            temp_path.to_string_lossy().replace("\"", "\\\""),
            node_ip
        );

        let output = std::process::Command::new("osascript")
            .args(["-e", &script])
            .output()
            .map_err(|e| format!("Failed to run script: {}", e))?;

        if output.status.success() {
            Ok("Client connected".to_string())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("Setup failed: {}", stderr))
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("Auto setup only supported on macOS".to_string())
    }
}

/// Setup WireGuard node directly (no script, inline)
/// Uses osascript to prompt for admin password on macOS
#[tauri::command]
async fn setup_wg_node(client_pubkey: String) -> Result<String, String> {
    // Get home directory for writable path
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let devpn_dir = format!("{}/.devpn", home);

    // Create directory if needed
    let _ = std::fs::create_dir_all(&devpn_dir);

    // Debug log
    let log_path = format!("{}/debug.log", devpn_dir);
    let log = move |msg: &str| {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&log_path) {
            let _ = writeln!(f, "{}", msg);
        }
    };

    log(&format!("setup_wg_node called with pubkey: {}", client_pubkey));
    log(&format!("Using devpn_dir: {}", devpn_dir));

    // Server keys - YOUR laptop
    let server_private = "KC2zNfRGP0hM9A7GDSMfKqlMrqR+E4EVDQf1Usd7RFo=";

    // Create config
    let config = format!(
        "[Interface]\nPrivateKey = {}\nAddress = 10.0.0.1/24\nListenPort = 51820\n\n[Peer]\nPublicKey = {}\nAllowedIPs = 10.0.0.2/32\n",
        server_private, client_pubkey
    );

    // Write config to devpn directory
    let config_path = format!("{}/wg0.conf", devpn_dir);
    std::fs::write(&config_path, &config).map_err(|e| {
        log(&format!("Failed to write config: {}", e));
        e.to_string()
    })?;

    log(&format!("Config written to {}", config_path));

    #[cfg(target_os = "macos")]
    {
        // Full script with all the fallbacks from tested node-setup.sh
        let script_content = format!(r#"#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DEVPN_DIR="{devpn_dir}"
CONFIG_FILE="$DEVPN_DIR/wg0.conf"

# Disable firewall
/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off 2>/dev/null || true

# Stop any existing WireGuard
wg-quick down wg0 2>/dev/null || true
wg-quick down /etc/wireguard/wg0.conf 2>/dev/null || true
wg-quick down /opt/homebrew/etc/wireguard/wg0.conf 2>/dev/null || true
pkill -f wireguard-go 2>/dev/null || true
sleep 1

# Copy config to proper location
if [ -d "/opt/homebrew/etc" ]; then
    mkdir -p /opt/homebrew/etc/wireguard
    cp "$CONFIG_FILE" /opt/homebrew/etc/wireguard/wg0.conf
    chmod 600 /opt/homebrew/etc/wireguard/wg0.conf
    CONFIG_DIR="/opt/homebrew/etc/wireguard"
else
    mkdir -p /etc/wireguard
    cp "$CONFIG_FILE" /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    CONFIG_DIR="/etc/wireguard"
fi

# Enable IP forwarding
sysctl -w net.inet.ip.forwarding=1

# Setup NAT
pfctl -e 2>/dev/null || true
echo 'nat on en0 from 10.0.0.0/24 to any -> (en0)' | pfctl -f - 2>/dev/null || true

# Start WireGuard - try multiple methods
if wg-quick up wg0 2>/dev/null; then
    echo "WireGuard started via wg-quick"
elif wg-quick up "$CONFIG_DIR/wg0.conf" 2>/dev/null; then
    echo "WireGuard started with full path"
else
    # Manual fallback with wireguard-go
    IFACE=$(wireguard-go utun 2>&1 | grep -oE 'utun[0-9]+' | head -1)
    if [ -n "$IFACE" ]; then
        wg setconf "$IFACE" "$CONFIG_DIR/wg0.conf" 2>/dev/null || true
        ifconfig "$IFACE" inet 10.0.0.1/24 10.0.0.1 alias
        ifconfig "$IFACE" up
        route -q -n add -inet 10.0.0.2/32 -interface "$IFACE" 2>/dev/null || true
        echo "WireGuard started manually on $IFACE"
    else
        echo "FAILED to start WireGuard"
        exit 1
    fi
fi

echo "Node setup complete"
"#, devpn_dir = devpn_dir);

        // Write script to devpn directory
        let script_path = format!("{}/node-setup.sh", devpn_dir);
        std::fs::write(&script_path, script_content).map_err(|e| {
            log(&format!("Failed to write script: {}", e));
            e.to_string()
        })?;

        log(&format!("Script written to {}", script_path));

        // Make executable with full permissions
        std::process::Command::new("chmod")
            .args(["755", &script_path])
            .output()
            .ok();

        log("Script chmod done");

        // Use osascript to run script with admin privileges via bash
        let osascript = format!(
            r#"do shell script "bash {}" with administrator privileges"#,
            script_path
        );

        log(&format!("Running osascript: {}", osascript));

        let output = std::process::Command::new("osascript")
            .args(["-e", &osascript])
            .output()
            .map_err(|e| {
                log(&format!("osascript failed to run: {}", e));
                format!("Failed to run setup: {}", e)
            })?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        log(&format!("osascript exit code: {:?}", output.status.code()));
        log(&format!("osascript stdout: {}", stdout));
        log(&format!("osascript stderr: {}", stderr));

        if output.status.success() {
            Ok(format!("Node started: {}", stdout.trim()))
        } else {
            Err(format!("Failed: {}", stderr))
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("WireGuard setup only supported on macOS".to_string())
    }
}

/// Setup WireGuard client directly (no script, inline)
/// Uses osascript to prompt for admin password on macOS
#[tauri::command]
async fn setup_wg_client(node_ip: String, node_pubkey: String) -> Result<String, String> {
    // Get home directory for writable path
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let devpn_dir = format!("{}/.devpn", home);

    // Create directory if needed
    let _ = std::fs::create_dir_all(&devpn_dir);

    // Client keys - FRIEND's laptop
    let client_private = "EO6SoyWxAsClEy8I8CCXtNfafJ5AJiWlDDgluGjBH2A=";

    // Create config
    let config = format!(
        "[Interface]\nPrivateKey = {}\nAddress = 10.0.0.2/24\n\n[Peer]\nPublicKey = {}\nEndpoint = {}:51820\nAllowedIPs = 10.0.0.0/24\nPersistentKeepalive = 25\n",
        client_private, node_pubkey, node_ip
    );

    // Write config to devpn directory
    let config_path = format!("{}/wg0.conf", devpn_dir);
    std::fs::write(&config_path, &config).map_err(|e| format!("Failed to write config: {}", e))?;

    #[cfg(target_os = "macos")]
    {
        // Full script with all the fallbacks from tested client-setup.sh
        let script_content = format!(r#"#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DEVPN_DIR="{devpn_dir}"
CONFIG_FILE="$DEVPN_DIR/wg0.conf"

# Disable firewall
/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off 2>/dev/null || true

# Stop any existing WireGuard
wg-quick down wg0 2>/dev/null || true
wg-quick down /etc/wireguard/wg0.conf 2>/dev/null || true
wg-quick down /opt/homebrew/etc/wireguard/wg0.conf 2>/dev/null || true
pkill -f wireguard-go 2>/dev/null || true
sleep 1

# Copy config to proper location
if [ -d "/opt/homebrew/etc" ]; then
    mkdir -p /opt/homebrew/etc/wireguard
    cp "$CONFIG_FILE" /opt/homebrew/etc/wireguard/wg0.conf
    chmod 600 /opt/homebrew/etc/wireguard/wg0.conf
    CONFIG_DIR="/opt/homebrew/etc/wireguard"
else
    mkdir -p /etc/wireguard
    cp "$CONFIG_FILE" /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    CONFIG_DIR="/etc/wireguard"
fi

# Start WireGuard - try multiple methods
if wg-quick up wg0 2>/dev/null; then
    echo "WireGuard started via wg-quick"
elif wg-quick up "$CONFIG_DIR/wg0.conf" 2>/dev/null; then
    echo "WireGuard started with full path"
else
    # Manual fallback with wireguard-go
    IFACE=$(wireguard-go utun 2>&1 | grep -oE 'utun[0-9]+' | head -1)
    if [ -n "$IFACE" ]; then
        wg setconf "$IFACE" "$CONFIG_DIR/wg0.conf" 2>/dev/null || true
        ifconfig "$IFACE" inet 10.0.0.2/24 10.0.0.2 alias
        ifconfig "$IFACE" up
        route -q -n add -inet 10.0.0.0/24 -interface "$IFACE" 2>/dev/null || true
        echo "WireGuard started manually on $IFACE"
    else
        echo "FAILED to start WireGuard"
        exit 1
    fi
fi

# Test connection
sleep 2
if ping -c 1 -t 3 10.0.0.1 > /dev/null 2>&1; then
    echo "Connected to node at {node_ip}"
else
    echo "WireGuard up but ping failed - node may not be running"
fi
"#, devpn_dir = devpn_dir, node_ip = node_ip);

        // Write script to devpn directory
        let script_path = format!("{}/client-setup.sh", devpn_dir);
        std::fs::write(&script_path, &script_content).map_err(|e| format!("Failed to write script: {}", e))?;

        // Make executable with full permissions
        std::process::Command::new("chmod")
            .args(["755", &script_path])
            .output()
            .ok();

        // Use osascript to run script with admin privileges via bash
        let osascript = format!(
            r#"do shell script "bash {}" with administrator privileges"#,
            script_path
        );

        let output = std::process::Command::new("osascript")
            .args(["-e", &osascript])
            .output()
            .map_err(|e| format!("Failed to run setup: {}", e))?;

        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            Ok(format!("Client connected: {}", stdout.trim()))
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(format!("Failed: {}", stderr))
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("WireGuard setup only supported on macOS".to_string())
    }
}

/// Get local IP address
#[tauri::command]
fn get_local_ip() -> Result<String, String> {
    // Try en0 first (WiFi on macOS)
    let output = std::process::Command::new("ipconfig")
        .args(["getifaddr", "en0"])
        .output();

    if let Ok(o) = output {
        if o.status.success() {
            let ip = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !ip.is_empty() {
                return Ok(ip);
            }
        }
    }

    // Try bridge100 (hotspot)
    let output = std::process::Command::new("ipconfig")
        .args(["getifaddr", "bridge100"])
        .output();

    if let Ok(o) = output {
        if o.status.success() {
            let ip = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !ip.is_empty() {
                return Ok(ip);
            }
        }
    }

    // Fallback - try to find any local IP
    let output = std::process::Command::new("ifconfig")
        .output()
        .map_err(|e| e.to_string())?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if line.contains("inet ") && !line.contains("127.0.0.1") {
            if let Some(ip) = line.split_whitespace().nth(1) {
                return Ok(ip.to_string());
            }
        }
    }

    Err("Could not determine local IP".to_string())
}

// ============ App Entry Point ============

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(AppState {
            node_state: node::create_shared_state(),
            ip_allocator: Arc::new(RwLock::new(node::IpAllocator::new())),
            wg_stats_cache: Arc::new(RwLock::new(HashMap::new())),
        })
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            check_network,
            generate_wg_keys,
            get_wg_keys,
            init_node,
            start_node,
            stop_node,
            get_node_status,
            add_session,
            remove_session,
            update_bandwidth_stats,
            get_session_bytes,
            load_saved_config,
            try_upnp,
            get_active_sessions,
            connect_vpn,
            disconnect_vpn,
            get_vpn_status,
            // Tailscale commands
            tailscale_status,
            tailscale_install,
            tailscale_start,
            tailscale_authenticate,
            tailscale_get_ip,
            tailscale_advertise_exit_node,
            tailscale_connect_exit_node,
            tailscale_disconnect_exit_node,
            tailscale_get_peers,
            tailscale_setup_node,
            tailscale_setup_client,
            // Live stats
            get_wg_live_stats,
            get_local_ip,
            // Auto setup
            run_node_setup,
            run_client_setup,
            setup_wg_node,
            setup_wg_client,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
