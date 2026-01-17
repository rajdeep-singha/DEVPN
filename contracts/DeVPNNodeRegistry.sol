// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "@flarenetwork/flare-periphery-contracts/flare/ContractRegistry.sol";
import "@flarenetwork/flare-periphery-contracts/flare/FtsoV2Interface.sol";


 //  manages node registration, staking, and status tracking
 
contract DeVPNNodeRegistry {
    
    FtsoV2Interface public ftsoV2;
    
    uint256 public constant MIN_STAKE = 1000 ether; // Minimum 1000 FLR to register
    uint256 public constant STAKE_LOCK_PERIOD = 30 days;
    uint256 public constant UPTIME_THRESHOLD = 80; // 80% minimum uptime
    
    struct NodeInfo {
        address owner;
        string endpoint; // IP:Port or domain
        string publicKey; // WireGuard public key
        uint256 stakedAmount;
        uint256 stakeTimestamp;
        uint256 bandwidthPrice; // Price per GB in USD (with 2 decimals)
        string location; // ISO country code
        uint256 maxBandwidth; // Max bandwidth in Mbps
        NodeStatus status;
        uint256 totalBandwidthServed; // Total GB served
        uint256 lastHeartbeat;
        uint256 uptimeScore; // Percentage (0-100)
        bool isActive;
    }
    
    enum NodeStatus {
        Pending,      
        Active,       
        Suspended,   
        Unstaking,    
        Slashed       
    }
    

    mapping(bytes32 => NodeInfo) public nodes;
    
 
    mapping(address => bytes32[]) public ownerNodes;
    

    bytes32[] public allNodeIds;
    
  
    uint256 public totalNodes;
    uint256 public activeNodes;
    

    
    event NodeRegistered(
        bytes32 indexed nodeId,
        address indexed owner,
        string endpoint,
        uint256 stakedAmount
    );
    
    event NodeUpdated(
        bytes32 indexed nodeId,
        string endpoint,
        uint256 bandwidthPrice,
        uint256 maxBandwidth
    );
    
    event NodeStatusChanged(
        bytes32 indexed nodeId,
        NodeStatus oldStatus,
        NodeStatus newStatus
    );
    
    event StakeIncreased(
        bytes32 indexed nodeId,
        uint256 additionalAmount,
        uint256 totalStake
    );
    
    event UnstakeInitiated(
        bytes32 indexed nodeId,
        uint256 amount,
        uint256 unlockTime
    );
    
    event StakeWithdrawn(
        bytes32 indexed nodeId,
        uint256 amount
    );
    
    event HeartbeatReceived(
        bytes32 indexed nodeId,
        uint256 timestamp,
        uint256 uptimeScore
    );
    
    event NodeSlashed(
        bytes32 indexed nodeId,
        uint256 slashedAmount,
        string reason
    );
    
    
    
    modifier onlyNodeOwner(bytes32 _nodeId) {
        require(nodes[_nodeId].owner == msg.sender, "Not node owner");
        _;
    }
    
    modifier nodeExists(bytes32 _nodeId) {
        require(nodes[_nodeId].owner != address(0), "Node does not exist");
        _;
    }
    
    
    
    constructor() {
       
        ftsoV2 = ContractRegistry.getFtsoV2();
    }

 

   
     // Register a new VPN node
     // _endpoint Node endpoint (IP:Port or domain)
     // _publicKey WireGuard public key for the node
     // _bandwidthPrice Price per GB in USD cents (e.g., 50 = $0.50/GB)
     // _location ISO country code (e.g., "US", "DE", "SG")
     // _maxBandwidth Maximum bandwidth in Mbps
     
    function registerNode(
        string memory _endpoint,
        string memory _publicKey,
        uint256 _bandwidthPrice,
        string memory _location,
        uint256 _maxBandwidth
    ) external payable returns (bytes32) {
        require(msg.value >= MIN_STAKE, "Insufficient stake");
        require(bytes(_endpoint).length > 0, "Invalid endpoint");
        require(bytes(_publicKey).length > 0, "Invalid public key");
        require(_bandwidthPrice > 0, "Price must be positive");
        require(_maxBandwidth > 0, "Bandwidth must be positive");
        
        // Generate unique node ID from owner + timestamp + endpoint
        bytes32 nodeId = keccak256(
            abi.encodePacked(msg.sender, block.timestamp, _endpoint)
        );
        
        require(nodes[nodeId].owner == address(0), "Node ID collision");
        
        nodes[nodeId] = NodeInfo({
            owner: msg.sender,
            endpoint: _endpoint,
            publicKey: _publicKey,
            stakedAmount: msg.value,
            stakeTimestamp: block.timestamp,
            bandwidthPrice: _bandwidthPrice,
            location: _location,
            maxBandwidth: _maxBandwidth,
            status: NodeStatus.Pending,
            totalBandwidthServed: 0,
            lastHeartbeat: block.timestamp,
            uptimeScore: 100, // Start with perfect score
            isActive: false
        });
        
        ownerNodes[msg.sender].push(nodeId);
        allNodeIds.push(nodeId);
        totalNodes++;
        
        emit NodeRegistered(nodeId, msg.sender, _endpoint, msg.value);
        
        return nodeId;
    }
    
    

     
    function updateNode(
        bytes32 _nodeId,
        string memory _endpoint,
        uint256 _bandwidthPrice,
        uint256 _maxBandwidth
    ) external onlyNodeOwner(_nodeId) nodeExists(_nodeId) {
        NodeInfo storage node = nodes[_nodeId];
        
        require(
            node.status != NodeStatus.Slashed,
            "Cannot update slashed node"
        );
        
        if (bytes(_endpoint).length > 0) {
            node.endpoint = _endpoint;
        }
        if (_bandwidthPrice > 0) {
            node.bandwidthPrice = _bandwidthPrice;
        }
        if (_maxBandwidth > 0) {
            node.maxBandwidth = _maxBandwidth;
        }
        
        emit NodeUpdated(_nodeId, _endpoint, _bandwidthPrice, _maxBandwidth);
    }
    
 
     
   
    function increaseStake(bytes32 _nodeId) 
        external 
        payable 
        onlyNodeOwner(_nodeId) 
        nodeExists(_nodeId) 
    {
        require(msg.value > 0, "Must send FLR");
        
        NodeInfo storage node = nodes[_nodeId];
        node.stakedAmount += msg.value;
        
        emit StakeIncreased(_nodeId, msg.value, node.stakedAmount);
    }
    
    
      // Initiate unstaking process
    
    function initiateUnstake(bytes32 _nodeId) 
        external 
        onlyNodeOwner(_nodeId) 
        nodeExists(_nodeId) 
    {
        NodeInfo storage node = nodes[_nodeId];
        
        require(
            node.status != NodeStatus.Unstaking,
            "Already unstaking"
        );
        require(
            node.status != NodeStatus.Slashed,
            "Cannot unstake slashed node"
        );
        
        NodeStatus oldStatus = node.status;
        node.status = NodeStatus.Unstaking;
        node.isActive = false;
        
        if (oldStatus == NodeStatus.Active) {
            activeNodes--;
        }
        
        emit NodeStatusChanged(_nodeId, oldStatus, NodeStatus.Unstaking);
        emit UnstakeInitiated(
            _nodeId,
            node.stakedAmount,
            block.timestamp + STAKE_LOCK_PERIOD
        );
    }
    
  
     //Withdraw stake after lock period
    
    function withdrawStake(bytes32 _nodeId) 
        external 
        onlyNodeOwner(_nodeId) 
        nodeExists(_nodeId) 
    {
        NodeInfo storage node = nodes[_nodeId];
        
        require(
            node.status == NodeStatus.Unstaking,
            "Not in unstaking status"
        );
        require(
            block.timestamp >= node.stakeTimestamp + STAKE_LOCK_PERIOD,
            "Lock period not ended"
        );
        
        uint256 amount = node.stakedAmount;
        node.stakedAmount = 0;
        
        // Transfer stake back to owner
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
        
        emit StakeWithdrawn(_nodeId, amount);
    }
    

    //Activating a pending node (called by oracle/admin after verification)
   
    function activateNode(bytes32 _nodeId) external nodeExists(_nodeId) {
        // In production, this would be restricted to oracle/admin 
        NodeInfo storage node = nodes[_nodeId];
        
        require(
            node.status == NodeStatus.Pending,
            "Node not in pending status"
        );
        
        NodeStatus oldStatus = node.status;
        node.status = NodeStatus.Active;
        node.isActive = true;
        activeNodes++;
        
        emit NodeStatusChanged(_nodeId, oldStatus, NodeStatus.Active);
    }

    // Submit heartbeat to prove node is online
    // _nodeId Node identifier
    // _uptimeScore Current uptime percentage (0-100)

    function submitHeartbeat(bytes32 _nodeId, uint256 _uptimeScore) 
        external 
        onlyNodeOwner(_nodeId) 
        nodeExists(_nodeId) 
    {
        require(_uptimeScore <= 100, "Invalid uptime score");
        
        NodeInfo storage node = nodes[_nodeId];
        node.lastHeartbeat = block.timestamp;
        node.uptimeScore = _uptimeScore;
        
        // Check if uptime is below threshold
        if (_uptimeScore < UPTIME_THRESHOLD && node.status == NodeStatus.Active) {
            NodeStatus oldStatus = node.status;
            node.status = NodeStatus.Suspended;
            node.isActive = false;
            activeNodes--;
            
            emit NodeStatusChanged(_nodeId, oldStatus, NodeStatus.Suspended);
        }
        
        emit HeartbeatReceived(_nodeId, block.timestamp, _uptimeScore);
    }
    
   
    function getFlrUsdPrice() 
        public 
        // view
        returns (uint256 value, int8 decimals, uint64 timestamp) 
    {
        bytes21 flrUsdId = 0x01464c522f55534400000000000000000000000000;
        return ftsoV2.getFeedById(flrUsdId);
    }
    
  
     // Calculate bandwidth cost in FLR
     // _nodeId Node identifier
     // _gigabytes Amount of bandwidth in GB
     // Cost in FLR (wei)
     
    function calculateCostInFlr(bytes32 _nodeId, uint256 _gigabytes) 
        public 
        // view 
        nodeExists(_nodeId) 
        returns (uint256) 
    {
        NodeInfo storage node = nodes[_nodeId];
        
        // Get current FLR/USD price
        (uint256 flrPrice, int8 decimals, ) = getFlrUsdPrice();
        
        // Calculate cost in USD cents
        uint256 costUsdCents = node.bandwidthPrice * _gigabytes;
        
        // Convert to FLR
        // costUsdCents is in cents, flrPrice is in USD with decimals
        // FLR needed = (costUsdCents / 100) / (flrPrice / 10^decimals)
        uint256 costInFlr = (costUsdCents * (10 ** uint8(decimals))) / (flrPrice * 100);
        
        return costInFlr * 1 ether; // Convert to wei
    }
    
 
    //Record bandwidth usage (called by oracle/escrow contract)
     
    function recordBandwidthUsage(bytes32 _nodeId, uint256 _gigabytes) 
        external 
        nodeExists(_nodeId) 
    {
        // In production, restrict to authorized contracts only
        NodeInfo storage node = nodes[_nodeId];
        node.totalBandwidthServed += _gigabytes;
    }
    
  
     
    function getNodeInfo(bytes32 _nodeId) 
        external 
        view 
        nodeExists(_nodeId) 
        returns (NodeInfo memory) 
    {
        return nodes[_nodeId];
    }
    
  
     //Get all nodes owned by an address
     
    function getNodesByOwner(address _owner) 
        external 
        view 
        returns (bytes32[] memory) 
    {
        return ownerNodes[_owner];
    }

    //Get all active nodes
    function getActiveNodes() external view returns (bytes32[] memory) {
        bytes32[] memory activeNodeList = new bytes32[](activeNodes);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allNodeIds.length; i++) {
            if (nodes[allNodeIds[i]].isActive) {
                activeNodeList[index] = allNodeIds[i];
                index++;
            }
        }
        
        return activeNodeList;
    }

    // Filter nodes by location
    function getNodesByLocation(string memory _location) 
        external 
        view 
        returns (bytes32[] memory) 
    {
        uint256 count = 0;
        
        // First pass: count matching nodes
        for (uint256 i = 0; i < allNodeIds.length; i++) {
            if (
                keccak256(bytes(nodes[allNodeIds[i]].location)) == 
                keccak256(bytes(_location)) &&
                nodes[allNodeIds[i]].isActive
            ) {
                count++;
            }
        }
        
        // Second pass: populate array
        bytes32[] memory locationNodes = new bytes32[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allNodeIds.length; i++) {
            if (
                keccak256(bytes(nodes[allNodeIds[i]].location)) == 
                keccak256(bytes(_location)) &&
                nodes[allNodeIds[i]].isActive
            ) {
                locationNodes[index] = allNodeIds[i];
                index++;
            }
        }
        
        return locationNodes;
    }

    // Get network statistics
    function getNetworkStats() 
        external 
        view 
        returns (
            uint256 _totalNodes,
            uint256 _activeNodes,
            uint256 _totalStaked
        ) 
    {
        uint256 totalStaked = 0;
        for (uint256 i = 0; i < allNodeIds.length; i++) {
            totalStaked += nodes[allNodeIds[i]].stakedAmount;
        }
        
        return (totalNodes, activeNodes, totalStaked);
    }
}