import { invoke } from "@tauri-apps/api/core";

// Types matching Rust backend
export interface NetworkCheckResult {
  public_ip: string;
  local_ip: string;
  country_code: string;
  port_open: boolean;
  upload_speed: string;
  wireguard_installed: boolean;
  internet_connected: boolean;
  is_hotspot: boolean;
  active_interface: string;
}

export interface WireGuardKeys {
  private_key: string;
  public_key: string;
}

export interface NodeConfig {
  node_id: number | null;
  endpoint: string;
  location: string;
  price_per_gb: string;
  stake_amount: string;
  is_active: boolean;
  wg_keys: WireGuardKeys;
}

export interface NodeStatus {
  is_running: boolean;
  is_registered: boolean;
  node_id: number | null;
  endpoint: string;
  location: string;
  price_per_gb: string;
  public_key: string;
  active_sessions: number;
  total_earnings: number;
  total_bytes_served: number;
}

export interface SessionInfo {
  session_id: number;
  user_address: string;
  bytes_used: number;
  duration_secs: number;
  earnings: string;
}

export interface ActiveSession {
  session_id: number;
  user_address: string;
  user_wg_pubkey: string;
  deposit: string;
  start_time: number;
  bytes_used: number;
  assigned_ip: string;
}

// Tauri command wrappers
export async function checkNetwork(): Promise<NetworkCheckResult> {
  return invoke("check_network");
}

export async function generateWgKeys(): Promise<WireGuardKeys> {
  return invoke("generate_wg_keys");
}

export async function getWgKeys(): Promise<WireGuardKeys> {
  return invoke("get_wg_keys");
}

export async function initNode(
  endpoint: string,
  location: string,
  pricePerGb: string,
  stakeAmount: string
): Promise<NodeConfig> {
  return invoke("init_node", {
    endpoint,
    location,
    pricePerGb,
    stakeAmount,
  });
}

export async function startNode(nodeId: number): Promise<void> {
  return invoke("start_node", { nodeId });
}

export async function stopNode(): Promise<void> {
  return invoke("stop_node");
}

export async function getNodeStatus(): Promise<NodeStatus> {
  return invoke("get_node_status");
}

export async function addSession(
  sessionId: number,
  userAddress: string,
  userWgPubkey: string,
  deposit: string
): Promise<string> {
  return invoke("add_session", {
    sessionId,
    userAddress,
    userWgPubkey,
    deposit,
  });
}

export async function removeSession(userWgPubkey: string): Promise<number> {
  return invoke("remove_session", { userWgPubkey });
}

export async function updateBandwidthStats(): Promise<SessionInfo[]> {
  return invoke("update_bandwidth_stats");
}

export async function getSessionBytes(userWgPubkey: string): Promise<number> {
  return invoke("get_session_bytes", { userWgPubkey });
}

export async function loadSavedConfig(): Promise<NodeConfig | null> {
  return invoke("load_saved_config");
}

export async function tryUpnp(): Promise<boolean> {
  return invoke("try_upnp");
}

export async function getActiveSessions(): Promise<ActiveSession[]> {
  return invoke("get_active_sessions");
}

// ============ Client Commands ============

export interface VpnConnectionInfo {
  connected: boolean;
  server_endpoint: string;
  assigned_ip: string;
  server_public_key: string;
  client_public_key: string;
  interface_name: string | null;
}

export interface VpnStatus {
  connected: boolean;
  interface_name: string | null;
  bytes_sent: number;
  bytes_received: number;
  last_handshake: number;
  server_endpoint: string | null;
}

export async function connectVpn(
  serverEndpoint: string,
  serverPublicKey: string
): Promise<VpnConnectionInfo> {
  return invoke("connect_vpn", {
    serverEndpoint,
    serverPublicKey,
  });
}

export async function disconnectVpn(): Promise<void> {
  return invoke("disconnect_vpn");
}

export async function getVpnStatus(): Promise<VpnStatus> {
  return invoke("get_vpn_status");
}

// Check if running in Tauri
export function isTauri(): boolean {
  return typeof window !== "undefined" && (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ !== undefined;
}

// ============ Tailscale Commands ============

export interface TailscaleStatus {
  installed: boolean;
  running: boolean;
  authenticated: boolean;
  ip: string | null;
  hostname: string | null;
  exit_node_active: boolean;
  is_exit_node: boolean;
}

export interface TailscalePeer {
  hostname: string;
  ip: string;
  online: boolean;
  is_exit_node: boolean;
}

export async function tailscaleStatus(): Promise<TailscaleStatus> {
  return invoke("tailscale_status");
}

export async function tailscaleInstall(): Promise<void> {
  return invoke("tailscale_install");
}

export async function tailscaleStart(): Promise<void> {
  return invoke("tailscale_start");
}

export async function tailscaleAuthenticate(authKey?: string): Promise<void> {
  return invoke("tailscale_authenticate", { authKey });
}

export async function tailscaleGetIp(): Promise<string | null> {
  return invoke("tailscale_get_ip");
}

export async function tailscaleAdvertiseExitNode(enable: boolean): Promise<void> {
  return invoke("tailscale_advertise_exit_node", { enable });
}

export async function tailscaleConnectExitNode(exitNodeIp: string): Promise<void> {
  return invoke("tailscale_connect_exit_node", { exitNodeIp });
}

export async function tailscaleDisconnectExitNode(): Promise<void> {
  return invoke("tailscale_disconnect_exit_node");
}

export async function tailscaleGetPeers(): Promise<TailscalePeer[]> {
  return invoke("tailscale_get_peers");
}

export async function tailscaleSetupNode(authKey?: string): Promise<TailscaleStatus> {
  return invoke("tailscale_setup_node", { authKey });
}

export async function tailscaleSetupClient(exitNodeIp: string, authKey?: string): Promise<TailscaleStatus> {
  return invoke("tailscale_setup_client", { authKey, exitNodeIp });
}

// ============ Live WireGuard Stats ============

export interface WgPeerStats {
  public_key: string;
  endpoint: string | null;
  allowed_ips: string;
  latest_handshake: number;
  transfer_rx: number;
  transfer_tx: number;
  persistent_keepalive: number;
}

export interface WgLiveStats {
  interface: string;
  public_key: string;
  listen_port: number;
  peers: WgPeerStats[];
}

export async function getWgLiveStats(): Promise<WgLiveStats> {
  return invoke("get_wg_live_stats");
}

export async function getLocalIp(): Promise<string> {
  return invoke("get_local_ip");
}

// ============ Auto Setup Commands ============

export async function runNodeSetup(): Promise<string> {
  return invoke("run_node_setup");
}

export async function runClientSetup(nodeIp: string): Promise<string> {
  return invoke("run_client_setup", { nodeIp });
}

export async function setupWgNode(clientPubkey: string): Promise<string> {
  return invoke("setup_wg_node", { clientPubkey });
}

export async function setupWgClient(nodeIp: string, nodePubkey: string): Promise<string> {
  return invoke("setup_wg_client", { nodeIp, nodePubkey });
}
