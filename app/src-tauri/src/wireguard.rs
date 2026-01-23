use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use x25519_dalek::{PublicKey, StaticSecret};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WireGuardKeys {
    pub private_key: String,
    pub public_key: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WireGuardPeer {
    pub public_key: String,
    pub allowed_ips: String,
    pub endpoint: Option<String>,
    pub bytes_received: u64,
    pub bytes_sent: u64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WireGuardConfig {
    pub interface: WireGuardInterface,
    pub peers: Vec<WireGuardPeer>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WireGuardInterface {
    pub private_key: String,
    pub address: String,
    pub listen_port: u16,
}

/// Generate a new WireGuard keypair
pub fn generate_keypair() -> WireGuardKeys {
    let secret = StaticSecret::random_from_rng(OsRng);
    let public = PublicKey::from(&secret);

    WireGuardKeys {
        private_key: BASE64.encode(secret.as_bytes()),
        public_key: BASE64.encode(public.as_bytes()),
    }
}

/// Get the WireGuard config directory
pub fn get_config_dir() -> Result<PathBuf, String> {
    let config_dir = dirs::config_dir()
        .ok_or("Could not find config directory")?
        .join("devpn");

    if !config_dir.exists() {
        fs::create_dir_all(&config_dir).map_err(|e| e.to_string())?;
    }

    Ok(config_dir)
}

/// Save WireGuard keys
pub fn save_keys(keys: &WireGuardKeys) -> Result<(), String> {
    let config_dir = get_config_dir()?;
    let keys_path = config_dir.join("wg_keys.json");

    let json = serde_json::to_string_pretty(keys).map_err(|e| e.to_string())?;
    fs::write(&keys_path, json).map_err(|e| e.to_string())?;

    Ok(())
}

/// Load WireGuard keys
pub fn load_keys() -> Result<WireGuardKeys, String> {
    let config_dir = get_config_dir()?;
    let keys_path = config_dir.join("wg_keys.json");

    if !keys_path.exists() {
        // Generate new keys if none exist
        let keys = generate_keypair();
        save_keys(&keys)?;
        return Ok(keys);
    }

    let json = fs::read_to_string(&keys_path).map_err(|e| e.to_string())?;
    serde_json::from_str(&json).map_err(|e| e.to_string())
}

/// Generate WireGuard server config
#[cfg(target_os = "macos")]
pub fn generate_server_config(
    private_key: &str,
    address: &str,
    port: u16,
) -> String {
    // On macOS, we use pfctl for NAT and sysctl for IP forwarding
    // Get the active interface dynamically
    let interface = crate::network::get_active_interface().unwrap_or_else(|_| "en0".to_string());

    format!(
        r#"[Interface]
PrivateKey = {}
Address = {}
ListenPort = {}
PostUp = sysctl -w net.inet.ip.forwarding=1; echo "nat on {} from 10.0.0.0/24 to any -> ({}) " | pfctl -ef -
PostDown = pfctl -d; sysctl -w net.inet.ip.forwarding=0
"#,
        private_key, address, port, interface, interface
    )
}

#[cfg(target_os = "linux")]
pub fn generate_server_config(
    private_key: &str,
    address: &str,
    port: u16,
) -> String {
    let interface = crate::network::get_active_interface().unwrap_or_else(|_| "eth0".to_string());

    format!(
        r#"[Interface]
PrivateKey = {}
Address = {}
ListenPort = {}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o {} -j MASQUERADE; sysctl -w net.ipv4.ip_forward=1
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o {} -j MASQUERADE
"#,
        private_key, address, port, interface, interface
    )
}

#[cfg(target_os = "windows")]
pub fn generate_server_config(
    private_key: &str,
    address: &str,
    port: u16,
) -> String {
    // Windows WireGuard handles routing differently
    format!(
        r#"[Interface]
PrivateKey = {}
Address = {}
ListenPort = {}
"#,
        private_key, address, port
    )
}

/// Generate peer config section
pub fn generate_peer_config(public_key: &str, allowed_ip: &str) -> String {
    format!(
        r#"
[Peer]
PublicKey = {}
AllowedIPs = {}
"#,
        public_key, allowed_ip
    )
}

/// Add a peer to WireGuard (platform-specific)
pub fn add_peer(interface: &str, public_key: &str, allowed_ip: &str) -> Result<(), String> {
    let wg_cmd = get_wg_command();

    // Try direct command first
    let output = Command::new(&wg_cmd)
        .args([
            "set",
            interface,
            "peer",
            public_key,
            "allowed-ips",
            allowed_ip,
        ])
        .output();

    match output {
        Ok(out) if out.status.success() => return Ok(()),
        _ => {}
    }

    // On Unix, try with sudo
    #[cfg(not(target_os = "windows"))]
    {
        let output = Command::new("sudo")
            .args([
                &wg_cmd,
                "set",
                interface,
                "peer",
                public_key,
                "allowed-ips",
                allowed_ip,
            ])
            .output()
            .map_err(|e| format!("Failed to execute wg command: {}", e))?;

        if !output.status.success() {
            return Err(format!(
                "Failed to add peer: {}",
                String::from_utf8_lossy(&output.stderr)
            ));
        }
    }

    // On Windows, if direct command failed, show admin message
    #[cfg(target_os = "windows")]
    {
        return Err("Failed to add peer. Please run the application as Administrator.".to_string());
    }

    Ok(())
}

/// Remove a peer from WireGuard (platform-specific)
pub fn remove_peer(interface: &str, public_key: &str) -> Result<(), String> {
    let wg_cmd = get_wg_command();

    // Try direct command first
    let output = Command::new(&wg_cmd)
        .args(["set", interface, "peer", public_key, "remove"])
        .output();

    match output {
        Ok(out) if out.status.success() => return Ok(()),
        _ => {}
    }

    // On Unix, try with sudo
    #[cfg(not(target_os = "windows"))]
    {
        let output = Command::new("sudo")
            .args([&wg_cmd, "set", interface, "peer", public_key, "remove"])
            .output()
            .map_err(|e| format!("Failed to execute wg command: {}", e))?;

        if !output.status.success() {
            return Err(format!(
                "Failed to remove peer: {}",
                String::from_utf8_lossy(&output.stderr)
            ));
        }
    }

    // On Windows, if direct command failed, show admin message
    #[cfg(target_os = "windows")]
    {
        return Err("Failed to remove peer. Please run the application as Administrator.".to_string());
    }

    Ok(())
}

/// Get WireGuard interface stats
pub fn get_interface_stats(interface: &str) -> Result<HashMap<String, WireGuardPeer>, String> {
    let wg_cmd = get_wg_command();
    let output = Command::new(&wg_cmd)
        .args(["show", interface, "dump"])
        .output()
        .map_err(|e| format!("Failed to execute wg command: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Failed to get stats: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let output_str = String::from_utf8_lossy(&output.stdout);
    let mut peers = HashMap::new();

    // Parse wg show dump output
    // Format: private_key public_key listen_port fwmark
    // Then for each peer: public_key preshared_key endpoint allowed_ips latest_handshake transfer_rx transfer_tx persistent_keepalive

    let lines: Vec<&str> = output_str.lines().collect();

    // Skip the interface line (first line)
    for line in lines.iter().skip(1) {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() >= 6 {
            let public_key = parts[0].to_string();
            let endpoint = if parts[2] != "(none)" {
                Some(parts[2].to_string())
            } else {
                None
            };
            let bytes_received: u64 = parts[5].parse().unwrap_or(0);
            let bytes_sent: u64 = parts[6].parse().unwrap_or(0);

            peers.insert(
                public_key.clone(),
                WireGuardPeer {
                    public_key,
                    allowed_ips: parts[3].to_string(),
                    endpoint,
                    bytes_received,
                    bytes_sent,
                },
            );
        }
    }

    Ok(peers)
}

/// Get the wg command path (platform-specific)
fn get_wg_command() -> String {
    #[cfg(target_os = "windows")]
    {
        // Check common Windows installation paths
        let paths = [
            r"C:\Program Files\WireGuard\wg.exe",
            r"C:\Program Files (x86)\WireGuard\wg.exe",
        ];
        for path in &paths {
            if std::path::Path::new(path).exists() {
                return path.to_string();
            }
        }
        // Fallback to PATH
        "wg".to_string()
    }

    #[cfg(not(target_os = "windows"))]
    {
        "wg".to_string()
    }
}

/// Check if WireGuard is installed
pub fn is_wireguard_installed() -> bool {
    let wg_cmd = get_wg_command();
    Command::new(&wg_cmd)
        .arg("--version")
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

/// Get the active WireGuard interface name (e.g., utun6 on macOS, devpn-client on Windows)
pub fn get_active_interface() -> Option<String> {
    let wg_cmd = get_wg_command();
    let output = Command::new(&wg_cmd)
        .args(["show", "interfaces"])
        .output()
        .ok()?;

    if output.status.success() {
        let interfaces = String::from_utf8_lossy(&output.stdout);
        // Return the first interface (usually there's only one for our use case)
        interfaces.split_whitespace().next().map(|s| s.to_string())
    } else {
        None
    }
}

/// Check if WireGuard interface exists
pub fn interface_exists(interface: &str) -> bool {
    let wg_cmd = get_wg_command();
    Command::new(&wg_cmd)
        .args(["show", interface])
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

/// Create WireGuard interface (platform specific)
#[cfg(target_os = "macos")]
pub fn create_interface(interface: &str, config: &WireGuardConfig) -> Result<(), String> {
    // On macOS, we need to use wireguard-go or the WireGuard app
    // For now, we'll create a config file
    let config_dir = get_config_dir()?;
    let config_path = config_dir.join(format!("{}.conf", interface));

    let mut config_content = generate_server_config(
        &config.interface.private_key,
        &config.interface.address,
        config.interface.listen_port,
    );

    for peer in &config.peers {
        config_content.push_str(&generate_peer_config(&peer.public_key, &peer.allowed_ips));
    }

    fs::write(&config_path, config_content).map_err(|e| e.to_string())?;

    // Try to bring up the interface using wg-quick
    let output = Command::new("wg-quick")
        .args(["up", config_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("Failed to execute wg-quick: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Failed to create interface: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

#[cfg(target_os = "windows")]
pub fn create_interface(interface: &str, config: &WireGuardConfig) -> Result<(), String> {
    // On Windows, we use the WireGuard service
    let config_dir = get_config_dir()?;
    let config_path = config_dir.join(format!("{}.conf", interface));

    let mut config_content = generate_server_config(
        &config.interface.private_key,
        &config.interface.address,
        config.interface.listen_port,
    );

    for peer in &config.peers {
        config_content.push_str(&generate_peer_config(&peer.public_key, &peer.allowed_ips));
    }

    fs::write(&config_path, &config_content).map_err(|e| e.to_string())?;

    // Use WireGuard Windows CLI
    let output = Command::new("wireguard")
        .args(["/installtunnelservice", config_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("Failed to execute wireguard: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Failed to create interface: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}

#[cfg(target_os = "linux")]
pub fn create_interface(interface: &str, config: &WireGuardConfig) -> Result<(), String> {
    let config_path = format!("/etc/wireguard/{}.conf", interface);

    let mut config_content = generate_server_config(
        &config.interface.private_key,
        &config.interface.address,
        config.interface.listen_port,
    );

    for peer in &config.peers {
        config_content.push_str(&generate_peer_config(&peer.public_key, &peer.allowed_ips));
    }

    fs::write(&config_path, config_content).map_err(|e| e.to_string())?;

    let output = Command::new("wg-quick")
        .args(["up", interface])
        .output()
        .map_err(|e| format!("Failed to execute wg-quick: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "Failed to create interface: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(())
}
