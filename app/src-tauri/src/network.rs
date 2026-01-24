use serde::{Deserialize, Serialize};
use std::net::UdpSocket;
use std::time::Duration;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct NetworkStatus {
    pub public_ip: String,
    pub local_ip: String,
    pub country_code: String,
    pub port_open: bool,
    pub upload_speed: String,
    pub internet_connected: bool,
    pub is_hotspot: bool,
    pub active_interface: String,
}

/// IP info with geolocation
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct IpInfo {
    pub ip: String,
    pub country_code: String,
}

/// Get the public IP address and country using external service
pub async fn get_public_ip_with_location() -> Result<IpInfo, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;

    // Try ip-api.com first (includes country)
    if let Ok(response) = client.get("http://ip-api.com/json/?fields=query,countryCode").send().await {
        if let Ok(json) = response.json::<serde_json::Value>().await {
            if let (Some(ip), Some(country)) = (
                json.get("query").and_then(|v| v.as_str()),
                json.get("countryCode").and_then(|v| v.as_str()),
            ) {
                return Ok(IpInfo {
                    ip: ip.to_string(),
                    country_code: country.to_string(),
                });
            }
        }
    }

    // Fallback: try ipinfo.io
    if let Ok(response) = client.get("https://ipinfo.io/json").send().await {
        if let Ok(json) = response.json::<serde_json::Value>().await {
            if let (Some(ip), Some(country)) = (
                json.get("ip").and_then(|v| v.as_str()),
                json.get("country").and_then(|v| v.as_str()),
            ) {
                return Ok(IpInfo {
                    ip: ip.to_string(),
                    country_code: country.to_string(),
                });
            }
        }
    }

    // Last fallback: just get IP without location
    let services = [
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
    ];

    for service in services {
        if let Ok(response) = client.get(service).send().await {
            if let Ok(ip) = response.text().await {
                let ip = ip.trim().to_string();
                if !ip.is_empty() && ip.contains('.') {
                    return Ok(IpInfo {
                        ip,
                        country_code: "US".to_string(), // Default fallback
                    });
                }
            }
        }
    }

    Err("Could not determine public IP".to_string())
}

/// Get the public IP address using external service (legacy)
pub async fn get_public_ip() -> Result<String, String> {
    get_public_ip_with_location().await.map(|info| info.ip)
}

/// Get local IP address
pub fn get_local_ip() -> Result<String, String> {
    // Create a UDP socket and connect to a public IP to determine local IP
    let socket = UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
    socket
        .connect("8.8.8.8:80")
        .map_err(|e| e.to_string())?;
    let local_addr = socket.local_addr().map_err(|e| e.to_string())?;
    Ok(local_addr.ip().to_string())
}

/// Check if a port is reachable from the internet
pub async fn check_port_open(_port: u16) -> bool {
    // Port checking from within the app is unreliable
    // The user will need to manually configure port forwarding
    // and the app will guide them through the process
    //
    // In a production system, you could:
    // 1. Use an external port checker service
    // 2. Have a relay server try to connect back
    // 3. Use STUN/TURN protocols
    //
    // For now, return false - user needs to configure manually
    false
}

/// Estimate upload speed (simplified)
pub fn estimate_upload_speed() -> String {
    // In a real implementation, you'd do an actual speed test
    // For now, we'll just return a placeholder
    "~50 Mbps".to_string()
}

/// Check if internet is connected
pub fn check_internet() -> bool {
    // Try to resolve a known DNS
    std::net::ToSocketAddrs::to_socket_addrs(&("google.com", 80)).is_ok()
}

/// Try to enable UPnP port forwarding
pub fn try_upnp_forward(_port: u16) -> Result<bool, String> {
    // UPnP implementation would go here
    // For now, return false - requires additional library
    Ok(false)
}

/// Get the active network interface name
#[cfg(target_os = "macos")]
pub fn get_active_interface() -> Result<String, String> {
    use std::process::Command;

    // Get the default route interface
    let output = Command::new("route")
        .args(["-n", "get", "default"])
        .output()
        .map_err(|e| e.to_string())?;

    let output_str = String::from_utf8_lossy(&output.stdout);

    for line in output_str.lines() {
        if line.trim().starts_with("interface:") {
            return Ok(line.split(':').nth(1).unwrap_or("en0").trim().to_string());
        }
    }

    // Default to en0 (WiFi) on macOS
    Ok("en0".to_string())
}

#[cfg(target_os = "linux")]
pub fn get_active_interface() -> Result<String, String> {
    use std::process::Command;

    let output = Command::new("ip")
        .args(["route", "show", "default"])
        .output()
        .map_err(|e| e.to_string())?;

    let output_str = String::from_utf8_lossy(&output.stdout);

    // Parse: "default via x.x.x.x dev eth0 ..."
    for part in output_str.split_whitespace() {
        if part.starts_with("eth") || part.starts_with("wlan") || part.starts_with("en") {
            return Ok(part.to_string());
        }
    }

    // Check for device after "dev"
    let parts: Vec<&str> = output_str.split_whitespace().collect();
    for (i, part) in parts.iter().enumerate() {
        if *part == "dev" && i + 1 < parts.len() {
            return Ok(parts[i + 1].to_string());
        }
    }

    Ok("eth0".to_string())
}

#[cfg(target_os = "windows")]
pub fn get_active_interface() -> Result<String, String> {
    // On Windows, we don't need interface name for NAT
    Ok("Ethernet".to_string())
}

/// Check if likely on mobile hotspot
pub fn is_mobile_hotspot() -> bool {
    // Mobile hotspots often have specific IP ranges or gateway patterns
    // This is a heuristic check
    if let Ok(local_ip) = get_local_ip() {
        // Common mobile hotspot IP ranges
        if local_ip.starts_with("192.168.43.") // Android hotspot
            || local_ip.starts_with("172.20.10.") // iPhone hotspot
            || local_ip.starts_with("192.168.137.") // Windows mobile hotspot
        {
            return true;
        }
    }
    false
}

/// Get network status
pub async fn get_network_status() -> NetworkStatus {
    let ip_info = get_public_ip_with_location().await.unwrap_or_else(|_| IpInfo {
        ip: "Unknown".to_string(),
        country_code: "US".to_string(),
    });
    let local_ip = get_local_ip().unwrap_or_else(|_| "Unknown".to_string());
    let port_open = check_port_open(51820).await;
    let upload_speed = estimate_upload_speed();
    let internet_connected = check_internet();
    let is_hotspot = is_mobile_hotspot();
    let active_interface = get_active_interface().unwrap_or_else(|_| "unknown".to_string());

    NetworkStatus {
        public_ip: ip_info.ip,
        local_ip,
        country_code: ip_info.country_code,
        port_open,
        upload_speed,
        internet_connected,
        is_hotspot,
        active_interface,
    }
}
