use serde::{Deserialize, Serialize};
use std::process::Command;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TailscaleStatus {
    pub installed: bool,
    pub running: bool,
    pub authenticated: bool,
    pub ip: Option<String>,
    pub hostname: Option<String>,
    pub exit_node_active: bool,
    pub is_exit_node: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TailscalePeer {
    pub hostname: String,
    pub ip: String,
    pub online: bool,
    pub is_exit_node: bool,
}

/// Check if Tailscale is installed
pub fn is_installed() -> bool {
    Command::new("which")
        .arg("tailscale")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Install Tailscale using Homebrew (macOS)
#[cfg(target_os = "macos")]
pub fn install() -> Result<(), String> {
    let output = Command::new("brew")
        .args(["install", "tailscale"])
        .output()
        .map_err(|e| format!("Failed to run brew: {}", e))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "Failed to install Tailscale: {}",
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

/// Install Tailscale on Linux
#[cfg(target_os = "linux")]
pub fn install() -> Result<(), String> {
    // Use the official install script
    let output = Command::new("sh")
        .args(["-c", "curl -fsSL https://tailscale.com/install.sh | sh"])
        .output()
        .map_err(|e| format!("Failed to install: {}", e))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "Failed to install Tailscale: {}",
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

#[cfg(target_os = "windows")]
pub fn install() -> Result<(), String> {
    Err("Please install Tailscale manually from https://tailscale.com/download/windows".to_string())
}

/// Start Tailscale daemon
#[cfg(target_os = "macos")]
pub fn start_daemon() -> Result<(), String> {
    // Try brew services first
    let output = Command::new("brew")
        .args(["services", "start", "tailscale"])
        .output();

    if let Ok(o) = output {
        if o.status.success() {
            // Wait for daemon to start
            std::thread::sleep(std::time::Duration::from_secs(2));
            return Ok(());
        }
    }

    // Fallback: start tailscaled directly
    let _ = Command::new("sudo")
        .args(["tailscaled", "--state=/var/lib/tailscale/tailscaled.state"])
        .spawn();

    std::thread::sleep(std::time::Duration::from_secs(2));
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn start_daemon() -> Result<(), String> {
    let output = Command::new("sudo")
        .args(["systemctl", "start", "tailscaled"])
        .output()
        .map_err(|e| format!("Failed to start tailscaled: {}", e))?;

    if output.status.success() {
        std::thread::sleep(std::time::Duration::from_secs(2));
        Ok(())
    } else {
        Err(format!(
            "Failed to start Tailscale: {}",
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

#[cfg(target_os = "windows")]
pub fn start_daemon() -> Result<(), String> {
    // On Windows, Tailscale runs as a service automatically
    Ok(())
}

/// Authenticate with Tailscale (interactive - opens browser)
pub fn authenticate_interactive() -> Result<(), String> {
    let output = Command::new("tailscale")
        .args(["up"])
        .output()
        .map_err(|e| format!("Failed to run tailscale up: {}", e))?;

    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("already logged in") || stderr.is_empty() {
            Ok(())
        } else {
            Err(format!("Failed to authenticate: {}", stderr))
        }
    }
}

/// Authenticate with Tailscale using auth key (automated)
pub fn authenticate_with_key(auth_key: &str) -> Result<(), String> {
    let output = Command::new("tailscale")
        .args(["up", "--authkey", auth_key])
        .output()
        .map_err(|e| format!("Failed to run tailscale up: {}", e))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "Failed to authenticate: {}",
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

/// Get Tailscale IP
pub fn get_ip() -> Option<String> {
    let output = Command::new("tailscale")
        .args(["ip", "-4"])
        .output()
        .ok()?;

    if output.status.success() {
        let ip = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !ip.is_empty() {
            Some(ip)
        } else {
            None
        }
    } else {
        None
    }
}

/// Get Tailscale status
pub fn get_status() -> TailscaleStatus {
    let installed = is_installed();

    if !installed {
        return TailscaleStatus {
            installed: false,
            running: false,
            authenticated: false,
            ip: None,
            hostname: None,
            exit_node_active: false,
            is_exit_node: false,
        };
    }

    let ip = get_ip();
    let authenticated = ip.is_some();

    // Get hostname
    let hostname = Command::new("tailscale")
        .args(["status", "--self", "--json"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                serde_json::from_slice::<serde_json::Value>(&o.stdout)
                    .ok()
                    .and_then(|v| v["Self"]["HostName"].as_str().map(|s| s.to_string()))
            } else {
                None
            }
        });

    // Check if running
    let running = Command::new("tailscale")
        .args(["status"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    // Check exit node status
    let status_output = Command::new("tailscale")
        .args(["status", "--json"])
        .output()
        .ok();

    let (exit_node_active, is_exit_node) = status_output
        .and_then(|o| {
            if o.status.success() {
                serde_json::from_slice::<serde_json::Value>(&o.stdout).ok()
            } else {
                None
            }
        })
        .map(|v| {
            let exit_active = v["ExitNodeStatus"]["Online"].as_bool().unwrap_or(false);
            let is_exit = v["Self"]["ExitNode"].as_bool().unwrap_or(false);
            (exit_active, is_exit)
        })
        .unwrap_or((false, false));

    TailscaleStatus {
        installed,
        running,
        authenticated,
        ip,
        hostname,
        exit_node_active,
        is_exit_node,
    }
}

/// Advertise as exit node (for VPN nodes)
pub fn advertise_exit_node(enable: bool) -> Result<(), String> {
    let args = if enable {
        vec!["up", "--advertise-exit-node"]
    } else {
        vec!["up", "--advertise-exit-node=false"]
    };

    let output = Command::new("tailscale")
        .args(&args)
        .output()
        .map_err(|e| format!("Failed to run tailscale: {}", e))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "Failed to set exit node: {}",
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

/// Connect to an exit node (for VPN clients)
pub fn connect_exit_node(exit_node_ip: &str) -> Result<(), String> {
    let output = Command::new("tailscale")
        .args(["up", "--exit-node", exit_node_ip])
        .output()
        .map_err(|e| format!("Failed to run tailscale: {}", e))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "Failed to connect to exit node: {}",
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

/// Disconnect from exit node
pub fn disconnect_exit_node() -> Result<(), String> {
    let output = Command::new("tailscale")
        .args(["up", "--exit-node="])
        .output()
        .map_err(|e| format!("Failed to run tailscale: {}", e))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "Failed to disconnect: {}",
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

/// Get list of peers (other devices on the Tailscale network)
pub fn get_peers() -> Vec<TailscalePeer> {
    let output = Command::new("tailscale")
        .args(["status", "--json"])
        .output()
        .ok();

    let Some(o) = output else {
        return vec![];
    };

    if !o.status.success() {
        return vec![];
    }

    let Ok(json) = serde_json::from_slice::<serde_json::Value>(&o.stdout) else {
        return vec![];
    };

    let Some(peers) = json["Peer"].as_object() else {
        return vec![];
    };

    peers
        .values()
        .filter_map(|peer| {
            let hostname = peer["HostName"].as_str()?.to_string();
            let ip = peer["TailscaleIPs"]
                .as_array()?
                .first()?
                .as_str()?
                .to_string();
            let online = peer["Online"].as_bool().unwrap_or(false);
            let is_exit_node = peer["ExitNodeOption"].as_bool().unwrap_or(false);

            Some(TailscalePeer {
                hostname,
                ip,
                online,
                is_exit_node,
            })
        })
        .collect()
}

/// Enable IP forwarding (required for exit nodes)
#[cfg(target_os = "macos")]
pub fn enable_ip_forwarding() -> Result<(), String> {
    let output = Command::new("sudo")
        .args(["sysctl", "-w", "net.inet.ip.forwarding=1"])
        .output()
        .map_err(|e| format!("Failed to enable IP forwarding: {}", e))?;

    if output.status.success() {
        Ok(())
    } else {
        Err("Failed to enable IP forwarding".to_string())
    }
}

#[cfg(target_os = "linux")]
pub fn enable_ip_forwarding() -> Result<(), String> {
    let output = Command::new("sudo")
        .args(["sysctl", "-w", "net.ipv4.ip_forward=1"])
        .output()
        .map_err(|e| format!("Failed to enable IP forwarding: {}", e))?;

    if output.status.success() {
        Ok(())
    } else {
        Err("Failed to enable IP forwarding".to_string())
    }
}

#[cfg(target_os = "windows")]
pub fn enable_ip_forwarding() -> Result<(), String> {
    // Windows handles this automatically with Tailscale
    Ok(())
}

/// Full setup for a VPN node
pub fn setup_as_node(auth_key: Option<&str>) -> Result<TailscaleStatus, String> {
    // 1. Check if installed, install if not
    if !is_installed() {
        log::info!("Installing Tailscale...");
        install()?;
    }

    // 2. Start daemon
    log::info!("Starting Tailscale daemon...");
    start_daemon()?;

    // 3. Authenticate
    log::info!("Authenticating...");
    if let Some(key) = auth_key {
        authenticate_with_key(key)?;
    } else {
        authenticate_interactive()?;
    }

    // 4. Enable IP forwarding
    log::info!("Enabling IP forwarding...");
    let _ = enable_ip_forwarding();

    // 5. Advertise as exit node
    log::info!("Advertising as exit node...");
    advertise_exit_node(true)?;

    // Return status
    Ok(get_status())
}

/// Full setup for a VPN client
pub fn setup_as_client(auth_key: Option<&str>, exit_node_ip: &str) -> Result<TailscaleStatus, String> {
    // 1. Check if installed, install if not
    if !is_installed() {
        log::info!("Installing Tailscale...");
        install()?;
    }

    // 2. Start daemon
    log::info!("Starting Tailscale daemon...");
    start_daemon()?;

    // 3. Authenticate
    log::info!("Authenticating...");
    if let Some(key) = auth_key {
        authenticate_with_key(key)?;
    } else {
        authenticate_interactive()?;
    }

    // 4. Connect to exit node
    log::info!("Connecting to exit node {}...", exit_node_ip);
    connect_exit_node(exit_node_ip)?;

    // Return status
    Ok(get_status())
}
