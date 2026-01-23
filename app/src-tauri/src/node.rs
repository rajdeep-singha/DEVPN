use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::wireguard::{self, WireGuardKeys, WireGuardPeer};

/// Node configuration
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct NodeConfig {
    pub node_id: Option<u64>,
    pub endpoint: String,
    pub location: String,
    pub price_per_gb: String,
    pub stake_amount: String,
    pub is_active: bool,
    pub wg_keys: WireGuardKeys,
}

/// Active session info
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ActiveSession {
    pub session_id: u64,
    pub user_address: String,
    pub user_wg_pubkey: String,
    pub deposit: String,
    pub start_time: u64,
    pub bytes_used: u64,
    pub assigned_ip: String,
}

/// Node state
#[derive(Debug, Default)]
pub struct NodeState {
    pub config: Option<NodeConfig>,
    pub sessions: HashMap<String, ActiveSession>, // keyed by user wg pubkey
    pub total_earnings: u64,
    pub total_sessions: u64,
    pub is_running: bool,
}

pub type SharedNodeState = Arc<RwLock<NodeState>>;

/// Create a new shared node state
pub fn create_shared_state() -> SharedNodeState {
    Arc::new(RwLock::new(NodeState::default()))
}

/// Get config directory path
fn get_config_path() -> Result<std::path::PathBuf, String> {
    let config_dir = wireguard::get_config_dir()?;
    Ok(config_dir.join("node_config.json"))
}

/// Save node config
pub fn save_config(config: &NodeConfig) -> Result<(), String> {
    let config_path = get_config_path()?;
    let json = serde_json::to_string_pretty(config).map_err(|e| e.to_string())?;
    fs::write(&config_path, json).map_err(|e| e.to_string())?;
    Ok(())
}

/// Load node config
pub fn load_config() -> Result<Option<NodeConfig>, String> {
    let config_path = get_config_path()?;

    if !config_path.exists() {
        return Ok(None);
    }

    let json = fs::read_to_string(&config_path).map_err(|e| e.to_string())?;
    let config: NodeConfig = serde_json::from_str(&json).map_err(|e| e.to_string())?;
    Ok(Some(config))
}

/// IP address allocation for VPN clients
pub struct IpAllocator {
    base_ip: [u8; 4],
    allocated: HashMap<String, String>, // pubkey -> IP
    next_ip: u8,
}

impl IpAllocator {
    pub fn new() -> Self {
        IpAllocator {
            base_ip: [10, 0, 0, 0], // 10.0.0.0/24 subnet
            allocated: HashMap::new(),
            next_ip: 2, // Start from 10.0.0.2 (10.0.0.1 is server)
        }
    }

    pub fn allocate(&mut self, pubkey: &str) -> Result<String, String> {
        // Check if already allocated
        if let Some(ip) = self.allocated.get(pubkey) {
            return Ok(ip.clone());
        }

        if self.next_ip >= 254 {
            return Err("No more IPs available".to_string());
        }

        let ip = format!(
            "{}.{}.{}.{}/32",
            self.base_ip[0], self.base_ip[1], self.base_ip[2], self.next_ip
        );
        self.allocated.insert(pubkey.to_string(), ip.clone());
        self.next_ip += 1;

        Ok(ip)
    }

    pub fn release(&mut self, pubkey: &str) {
        self.allocated.remove(pubkey);
    }

    pub fn get_server_address(&self) -> String {
        format!(
            "{}.{}.{}.1/24",
            self.base_ip[0], self.base_ip[1], self.base_ip[2]
        )
    }
}

impl Default for IpAllocator {
    fn default() -> Self {
        Self::new()
    }
}

/// Calculate bandwidth usage from WireGuard stats
pub fn calculate_bandwidth_delta(
    old_stats: &HashMap<String, WireGuardPeer>,
    new_stats: &HashMap<String, WireGuardPeer>,
    pubkey: &str,
) -> u64 {
    let old = old_stats.get(pubkey);
    let new = new_stats.get(pubkey);

    match (old, new) {
        (Some(old_peer), Some(new_peer)) => {
            let rx_delta = new_peer.bytes_received.saturating_sub(old_peer.bytes_received);
            let tx_delta = new_peer.bytes_sent.saturating_sub(old_peer.bytes_sent);
            rx_delta + tx_delta
        }
        (None, Some(new_peer)) => new_peer.bytes_received + new_peer.bytes_sent,
        _ => 0,
    }
}

/// Format bytes to human readable
pub fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.2} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.2} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
