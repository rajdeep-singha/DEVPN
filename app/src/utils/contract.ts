// DeVPN Contract Configuration
export const NODE_REGISTRY_ADDRESS = "0x4Dda664964b91F9247a2344d3ea2BE8485c8b74b";
export const ESCROW_ADDRESS = "0xBB2C060D38a148D9bE5a207f6a247268953ACA37";
export const STATE_CONNECTOR_ADDRESS = "0x0000000000000000000000000000000000000000";
export const FLARE_CONFIG = {
  chainId: 14,
  chainName: "Flare Mainnet",
  rpcUrls: ["https://flare-api.flare.network/ext/C/rpc"],
  nativeCurrency: {
    name: "Flare",
    symbol: "FLR",
    decimals: 18,
  },
  blockExplorerUrls: ["https://flare-explorer.flare.network"],
};

export const COSTON2_CONFIG = {
  chainId: 114,
  chainName: "Flare Coston2 Testnet",
  rpcUrls: ["https://coston2-api.flare.network/ext/C/rpc"],
  nativeCurrency: {
    name: "Coston2 Flare",
    symbol: "C2FLR",
    decimals: 18,
  },
  blockExplorerUrls: ["https://coston2-explorer.flare.network"],
};

export const NETWORK_CONFIG = COSTON2_CONFIG;

export const NODE_REGISTRY_ABI = [
  "function MIN_STAKE() view returns (uint256)",
  "function STAKE_LOCK_PERIOD() view returns (uint256)",
  "function HEARTBEAT_INTERVAL() view returns (uint256)",
  "function UPTIME_THRESHOLD() view returns (uint256)",
  "function SLASH_PERCENTAGE() view returns (uint256)",
  "function totalNodes() view returns (uint256)",
  "function activeNodes() view returns (uint256)",
  "function owner() view returns (address)",
  "function escrowContract() view returns (address)",

  // Node Registration
  "function registerNode(string _endpoint, string _publicKey, uint256 _bandwidthPrice, string _location, uint256 _maxBandwidth) payable returns (bytes32)",
  "function updateNode(bytes32 _nodeId, string _endpoint, string _publicKey, uint256 _bandwidthPrice, uint256 _maxBandwidth)",

  // Staking
  "function increaseStake(bytes32 _nodeId) payable",
  "function initiateUnstake(bytes32 _nodeId)",
  "function withdrawStake(bytes32 _nodeId)",
  "function withdrawEarnings(bytes32 _nodeId)",

  // Status Management
  "function activateNode(bytes32 _nodeId)",
  "function deactivateNode(bytes32 _nodeId)",
  "function submitHeartbeat(bytes32 _nodeId)",

  // View Functions
  "function getNodeInfo(bytes32 _nodeId) view returns (tuple(uint256 id, address owner, string endpoint, string publicKey, uint256 stakedAmount, uint256 stakeTimestamp, uint256 bandwidthPrice, string location, uint256 maxBandwidth, uint8 status, uint256 totalBandwidthServed, uint256 totalEarnings, uint256 lastHeartbeat, uint256 uptimeScore, uint256 sessionCount, uint256 rating, uint256 ratingCount, bool isActive))",
  "function getNodesByOwner(address _owner) view returns (bytes32[])",
  "function primaryNode(address) view returns (bytes32)",
  "function getActiveNodeIds() view returns (bytes32[])",
  "function getActiveNodes() view returns (tuple(uint256 id, address owner, string endpoint, string publicKey, uint256 stakedAmount, uint256 stakeTimestamp, uint256 bandwidthPrice, string location, uint256 maxBandwidth, uint8 status, uint256 totalBandwidthServed, uint256 totalEarnings, uint256 lastHeartbeat, uint256 uptimeScore, uint256 sessionCount, uint256 rating, uint256 ratingCount, bool isActive)[])",
  "function getNodesByLocation(string _location) view returns (bytes32[])",
  "function getNetworkStats() view returns (uint256 _totalNodes, uint256 _activeNodes, uint256 _totalStaked, uint256 _totalBandwidth)",
  "function isNodeHealthy(bytes32 _nodeId) view returns (bool)",
  "function calculateCostInFlr(bytes32 _nodeId, uint256 _bytes) view returns (uint256)",
  "function getFlrUsdPrice() view returns (uint256 price, int8 decimals, uint64 timestamp)",

  // Events
  "event NodeRegistered(bytes32 indexed nodeId, address indexed owner, string endpoint, string publicKey, uint256 stakedAmount, string location)",
  "event NodeUpdated(bytes32 indexed nodeId, string endpoint, uint256 bandwidthPrice, uint256 maxBandwidth)",
  "event NodeStatusChanged(bytes32 indexed nodeId, uint8 oldStatus, uint8 newStatus)",
  "event StakeIncreased(bytes32 indexed nodeId, uint256 additionalAmount, uint256 totalStake)",
  "event UnstakeInitiated(bytes32 indexed nodeId, uint256 amount, uint256 unlockTime)",
  "event StakeWithdrawn(bytes32 indexed nodeId, address indexed owner, uint256 amount)",
  "event HeartbeatReceived(bytes32 indexed nodeId, uint256 timestamp, uint256 uptimeScore)",
  "event NodeSlashed(bytes32 indexed nodeId, uint256 slashedAmount, string reason)",
  "event NodeRated(bytes32 indexed nodeId, address indexed user, uint256 rating)",
  "event EarningsAdded(bytes32 indexed nodeId, uint256 amount)",
  "event EarningsWithdrawn(bytes32 indexed nodeId, address indexed owner, uint256 amount)",
];

import ESCROW_SIMPLE_ABI from './DeVPNEscrowSimple.abi.json' assert { type: 'json' };
export const ESCROW_ABI = ESCROW_SIMPLE_ABI;
export const NodeStatus = {
  Pending: 0,
  Active: 1,
  Suspended: 2,
  Unstaking: 3,
  Slashed: 4,
} as const;

export const SessionStatus = {
  Active: 0,
  Settled: 1,
  Disputed: 2,
  Expired: 3,
} as const;

export interface Node {
  id: bigint;
  owner: string;
  endpoint: string;
  publicKey: string;
  stakedAmount: bigint;
  stakeTimestamp: bigint;
  bandwidthPrice: bigint;
  location: string;
  maxBandwidth: bigint;
  status: number;
  totalBandwidthServed: bigint;
  totalEarnings: bigint;
  lastHeartbeat: bigint;
  uptimeScore: bigint;
  sessionCount: bigint;
  rating: bigint;
  ratingCount: bigint;
  isActive: boolean;
}

export interface Session {
  id: bigint;
  nodeId: string; // bytes32 as hex string
  user: string;
  userPublicKey: string;
  deposit: bigint;
  startTime: bigint;
  endTime: bigint;
  bytesUsed: bigint;
  costInFlr: bigint;
  status: number;
  disputed: boolean;
}

export function formatFLR(wei: bigint): string {
  const flr = Number(wei) / 1e18;
  if (flr < 0.01) return flr.toFixed(4);
  return flr.toFixed(2);
}

export function parseFLR(flr: string): bigint {
  return BigInt(Math.floor(parseFloat(flr) * 1e18));
}

export function formatBytes(bytes: bigint): string {
  const num = Number(bytes);
  if (num >= 1024 * 1024 * 1024) {
    return (num / (1024 * 1024 * 1024)).toFixed(2) + " GB";
  } else if (num >= 1024 * 1024) {
    return (num / (1024 * 1024)).toFixed(2) + " MB";
  } else if (num >= 1024) {
    return (num / 1024).toFixed(2) + " KB";
  }
  return num + " B";
}

export function shortenAddress(address: string): string {
  return address.slice(0, 6) + "..." + address.slice(-4);
}

export function getRatingStars(rating: bigint): string {
  const stars = Number(rating) / 100;
  const fullStars = Math.floor(stars);
  const halfStar = stars - fullStars >= 0.5;
  return "★".repeat(fullStars) + (halfStar ? "½" : "") + "☆".repeat(5 - fullStars - (halfStar ? 1 : 0));
}

export function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = Math.floor(seconds % 60);
  return `${hours.toString().padStart(2, "0")}:${minutes.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
}

export function nodeStatusToString(status: number): string {
  switch (status) {
    case NodeStatus.Pending: return "Pending";
    case NodeStatus.Active: return "Active";
    case NodeStatus.Suspended: return "Suspended";
    case NodeStatus.Unstaking: return "Unstaking";
    case NodeStatus.Slashed: return "Slashed";
    default: return "Unknown";
  }
}

export function sessionStatusToString(status: number): string {
  switch (status) {
    case SessionStatus.Active: return "Active";
    case SessionStatus.Settled: return "Settled";
    case SessionStatus.Disputed: return "Disputed";
    case SessionStatus.Expired: return "Expired";
    default: return "Unknown";
  }
}

export const COUNTRY_FLAGS: Record<string, string> = {
  US: "US",
  DE: "DE",
  GB: "GB",
  FR: "FR",
  JP: "JP",
  SG: "SG",
  AU: "AU",
  CA: "CA",
  NL: "NL",
  IN: "IN",
  BR: "BR",
  KR: "KR",
  CH: "CH",
  SE: "SE",
  NO: "NO",
  FI: "FI",
  DK: "DK",
  IE: "IE",
  ES: "ES",
  IT: "IT",
  PL: "PL",
  CZ: "CZ",
  AT: "AT",
  BE: "BE",
  HK: "HK",
  TW: "TW",
  MY: "MY",
  TH: "TH",
  ID: "ID",
  PH: "PH",
  VN: "VN",
  NZ: "NZ",
  ZA: "ZA",
  AE: "AE",
  IL: "IL",
  TR: "TR",
  RU: "RU",
  UA: "UA",
  MX: "MX",
  AR: "AR",
  CL: "CL",
  CO: "CO",
  PE: "PE",
};

export function getCountryFlag(code: string): string {
  return COUNTRY_FLAGS[code?.toUpperCase()] || code?.toUpperCase() || "--";
}

export const DEVPN_ADDRESS = NODE_REGISTRY_ADDRESS;
export const DEVPN_ABI = NODE_REGISTRY_ABI;
