// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IFlare.sol";

/**
 * @title DeVPNNodeRegistry
 * @notice Manages node registration, staking, and status tracking for DeVPN
 * @dev Uses Flare FTSO for FLR/USD price feeds
 */
contract DeVPNNodeRegistry {
    // ============ Flare Integration ============
    FtsoV2Interface public ftsoV2;
    bytes21 public constant FLR_USD_FEED_ID = 0x01464c522f55534400000000000000000000000000;

    // ============ Constants ============
    uint256 public constant MIN_STAKE = 15 ether; // Minimum 15 FLR to register
    uint256 public constant STAKE_LOCK_PERIOD = 7 days;
    uint256 public constant UPTIME_THRESHOLD = 80; // 80% minimum uptime
    uint256 public constant HEARTBEAT_INTERVAL = 5 minutes;
    uint256 public constant SLASH_PERCENTAGE = 10; // 10% slash for violations

    // ============ State Variables ============
    address public owner;
    address public escrowContract;

    uint256 public totalNodes;
    uint256 public activeNodes;
    uint256 public nodeCounter;

    // ============ Structs ============
    struct NodeInfo {
        uint256 id;
        address owner;
        string endpoint; // IP:Port or domain
        string publicKey; // WireGuard public key
        uint256 stakedAmount;
        uint256 stakeTimestamp;
        uint256 bandwidthPrice; // Price per GB in USD cents (e.g., 50 = $0.50/GB)
        string location; // ISO country code
        uint256 maxBandwidth; // Max bandwidth in Mbps
        NodeStatus status;
        uint256 totalBandwidthServed; // Total bytes served
        uint256 totalEarnings;
        uint256 lastHeartbeat;
        uint256 uptimeScore; // Percentage (0-100)
        uint256 sessionCount;
        uint256 rating; // 0-500 (0-5 stars * 100)
        uint256 ratingCount;
        bool isActive;
    }

    enum NodeStatus {
        Pending, // Awaiting activation
        Active, // Online and serving
        Suspended, // Temporarily suspended
        Unstaking, // In unstaking period
        Slashed // Penalized
    }

    // ============ Mappings ============
    mapping(bytes32 => NodeInfo) public nodes;
    mapping(address => bytes32[]) public ownerNodes;
    mapping(address => bytes32) public primaryNode; // Main node for each owner
    bytes32[] public allNodeIds;

    // ============ Events ============
    event NodeRegistered(
        bytes32 indexed nodeId,
        address indexed owner,
        string endpoint,
        string publicKey,
        uint256 stakedAmount,
        string location
    );

    event NodeUpdated(
        bytes32 indexed nodeId, string endpoint, uint256 bandwidthPrice, uint256 maxBandwidth
    );

    event NodeStatusChanged(bytes32 indexed nodeId, NodeStatus oldStatus, NodeStatus newStatus);

    event StakeIncreased(bytes32 indexed nodeId, uint256 additionalAmount, uint256 totalStake);

    event UnstakeInitiated(bytes32 indexed nodeId, uint256 amount, uint256 unlockTime);

    event StakeWithdrawn(bytes32 indexed nodeId, address indexed owner, uint256 amount);

    event HeartbeatReceived(bytes32 indexed nodeId, uint256 timestamp, uint256 uptimeScore);

    event NodeSlashed(bytes32 indexed nodeId, uint256 slashedAmount, string reason);

    event NodeRated(bytes32 indexed nodeId, address indexed user, uint256 rating);

    event EarningsAdded(bytes32 indexed nodeId, uint256 amount);

    event EarningsWithdrawn(bytes32 indexed nodeId, address indexed owner, uint256 amount);

    event EscrowContractUpdated(address indexed newEscrow);

    // ============ Modifiers ============
    modifier onlyOwner() {
        require(msg.sender == owner, "Not contract owner");
        _;
    }

    modifier onlyNodeOwner(bytes32 _nodeId) {
        require(nodes[_nodeId].owner == msg.sender, "Not node owner");
        _;
    }

    modifier nodeExists(bytes32 _nodeId) {
        require(nodes[_nodeId].owner != address(0), "Node does not exist");
        _;
    }

    modifier onlyEscrow() {
        require(msg.sender == escrowContract, "Only escrow contract");
        _;
    }

    modifier onlyOwnerOrEscrow() {
        require(msg.sender == owner || msg.sender == escrowContract, "Not authorized");
        _;
    }

    // ============ Constructor ============
    constructor() {
        owner = msg.sender;
        ftsoV2 = ContractRegistry.getFtsoV2();
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the escrow contract address
     * @param _escrow Address of the escrow contract
     */
    function setEscrowContract(address _escrow) external onlyOwner {
        require(_escrow != address(0), "Invalid address");
        escrowContract = _escrow;
        emit EscrowContractUpdated(_escrow);
    }

    /**
     * @notice Transfer ownership
     * @param _newOwner New owner address
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid address");
        owner = _newOwner;
    }

    // ============ Node Registration ============

    /**
     * @notice Register a new VPN node
     * @param _endpoint Node endpoint (IP:Port or domain)
     * @param _publicKey WireGuard public key
     * @param _bandwidthPrice Price per GB in USD cents (e.g., 50 = $0.50/GB)
     * @param _location ISO country code (e.g., "US", "DE", "SG")
     * @param _maxBandwidth Maximum bandwidth in Mbps
     * @return nodeId The unique identifier for the registered node
     */
    function registerNode(
        string calldata _endpoint,
        string calldata _publicKey,
        uint256 _bandwidthPrice,
        string calldata _location,
        uint256 _maxBandwidth
    ) external payable returns (bytes32) {
        require(msg.value >= MIN_STAKE, "Insufficient stake");
        require(bytes(_endpoint).length > 0, "Invalid endpoint");
        require(bytes(_publicKey).length == 44, "Invalid WireGuard key length");
        require(_bandwidthPrice > 0, "Price must be positive");
        require(_maxBandwidth > 0, "Bandwidth must be positive");

        nodeCounter++;

        // Generate unique node ID
        bytes32 nodeId =
            keccak256(abi.encodePacked(msg.sender, block.timestamp, nodeCounter, _publicKey));

        require(nodes[nodeId].owner == address(0), "Node ID collision");

        nodes[nodeId] = NodeInfo({
            id: nodeCounter,
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
            totalEarnings: 0,
            lastHeartbeat: block.timestamp,
            uptimeScore: 100,
            sessionCount: 0,
            rating: 0,
            ratingCount: 0,
            isActive: false
        });

        ownerNodes[msg.sender].push(nodeId);

        // Set as primary if first node
        if (primaryNode[msg.sender] == bytes32(0)) {
            primaryNode[msg.sender] = nodeId;
        }

        allNodeIds.push(nodeId);
        totalNodes++;

        emit NodeRegistered(nodeId, msg.sender, _endpoint, _publicKey, msg.value, _location);

        return nodeId;
    }

    /**
     * @notice Update node configuration
     * @param _nodeId Node identifier
     * @param _endpoint New endpoint (empty to keep current)
     * @param _publicKey New public key (empty to keep current)
     * @param _bandwidthPrice New price (0 to keep current)
     * @param _maxBandwidth New bandwidth (0 to keep current)
     */
    function updateNode(
        bytes32 _nodeId,
        string calldata _endpoint,
        string calldata _publicKey,
        uint256 _bandwidthPrice,
        uint256 _maxBandwidth
    ) external onlyNodeOwner(_nodeId) nodeExists(_nodeId) {
        NodeInfo storage node = nodes[_nodeId];

        require(node.status != NodeStatus.Slashed, "Cannot update slashed node");

        if (bytes(_endpoint).length > 0) {
            node.endpoint = _endpoint;
        }
        if (bytes(_publicKey).length > 0) {
            require(bytes(_publicKey).length == 44, "Invalid WireGuard key length");
            node.publicKey = _publicKey;
        }
        if (_bandwidthPrice > 0) {
            node.bandwidthPrice = _bandwidthPrice;
        }
        if (_maxBandwidth > 0) {
            node.maxBandwidth = _maxBandwidth;
        }

        emit NodeUpdated(_nodeId, node.endpoint, node.bandwidthPrice, node.maxBandwidth);
    }

    // ============ Staking Functions ============

    /**
     * @notice Increase stake for a node
     * @param _nodeId Node identifier
     */
    function increaseStake(bytes32 _nodeId)
        external
        payable
        onlyNodeOwner(_nodeId)
        nodeExists(_nodeId)
    {
        require(msg.value > 0, "Must send FLR");

        NodeInfo storage node = nodes[_nodeId];
        require(node.status != NodeStatus.Slashed, "Cannot stake on slashed node");

        node.stakedAmount += msg.value;

        emit StakeIncreased(_nodeId, msg.value, node.stakedAmount);
    }

    /**
     * @notice Initiate unstaking process
     * @param _nodeId Node identifier
     */
    function initiateUnstake(bytes32 _nodeId) external onlyNodeOwner(_nodeId) nodeExists(_nodeId) {
        NodeInfo storage node = nodes[_nodeId];

        require(node.status != NodeStatus.Unstaking, "Already unstaking");
        require(node.status != NodeStatus.Slashed, "Cannot unstake slashed node");

        NodeStatus oldStatus = node.status;
        node.status = NodeStatus.Unstaking;
        node.isActive = false;
        node.stakeTimestamp = block.timestamp; // Reset for lock period

        if (oldStatus == NodeStatus.Active) {
            activeNodes--;
        }

        emit NodeStatusChanged(_nodeId, oldStatus, NodeStatus.Unstaking);
        emit UnstakeInitiated(_nodeId, node.stakedAmount, block.timestamp + STAKE_LOCK_PERIOD);
    }

    /**
     * @notice Withdraw stake after lock period
     * @param _nodeId Node identifier
     */
    function withdrawStake(bytes32 _nodeId) external onlyNodeOwner(_nodeId) nodeExists(_nodeId) {
        NodeInfo storage node = nodes[_nodeId];

        require(node.status == NodeStatus.Unstaking, "Not in unstaking status");
        require(block.timestamp >= node.stakeTimestamp + STAKE_LOCK_PERIOD, "Lock period not ended");

        uint256 amount = node.stakedAmount;
        require(amount > 0, "No stake to withdraw");

        node.stakedAmount = 0;

        (bool success,) = payable(msg.sender).call{ value: amount }("");
        require(success, "Transfer failed");

        emit StakeWithdrawn(_nodeId, msg.sender, amount);
    }

    /**
     * @notice Withdraw accumulated earnings
     * @param _nodeId Node identifier
     */
    function withdrawEarnings(bytes32 _nodeId) external onlyNodeOwner(_nodeId) nodeExists(_nodeId) {
        NodeInfo storage node = nodes[_nodeId];

        uint256 earnings = node.totalEarnings;
        require(earnings > 0, "No earnings to withdraw");

        node.totalEarnings = 0;

        (bool success,) = payable(msg.sender).call{ value: earnings }("");
        require(success, "Transfer failed");

        emit EarningsWithdrawn(_nodeId, msg.sender, earnings);
    }

    // ============ Status Management ============

    /**
     * @notice Activate a pending node (self-activation after registration)
     * @param _nodeId Node identifier
     */
    function activateNode(bytes32 _nodeId) external onlyNodeOwner(_nodeId) nodeExists(_nodeId) {
        NodeInfo storage node = nodes[_nodeId];

        require(
            node.status == NodeStatus.Pending || node.status == NodeStatus.Suspended,
            "Cannot activate from current status"
        );
        require(node.stakedAmount >= MIN_STAKE, "Insufficient stake");

        NodeStatus oldStatus = node.status;
        node.status = NodeStatus.Active;
        node.isActive = true;
        node.lastHeartbeat = block.timestamp;

        if (oldStatus != NodeStatus.Active) {
            activeNodes++;
        }

        emit NodeStatusChanged(_nodeId, oldStatus, NodeStatus.Active);
    }

    /**
     * @notice Deactivate a node (go offline)
     * @param _nodeId Node identifier
     */
    function deactivateNode(bytes32 _nodeId) external onlyNodeOwner(_nodeId) nodeExists(_nodeId) {
        NodeInfo storage node = nodes[_nodeId];

        require(node.status == NodeStatus.Active, "Node not active");

        NodeStatus oldStatus = node.status;
        node.status = NodeStatus.Suspended;
        node.isActive = false;
        activeNodes--;

        emit NodeStatusChanged(_nodeId, oldStatus, NodeStatus.Suspended);
    }

    /**
     * @notice Submit heartbeat to prove node is online
     * @param _nodeId Node identifier
     */
    function submitHeartbeat(bytes32 _nodeId) external onlyNodeOwner(_nodeId) nodeExists(_nodeId) {
        NodeInfo storage node = nodes[_nodeId];

        require(node.status == NodeStatus.Active, "Node not active");

        uint256 timeSinceLastHeartbeat = block.timestamp - node.lastHeartbeat;

        // Calculate uptime based on heartbeat frequency
        if (timeSinceLastHeartbeat <= HEARTBEAT_INTERVAL * 2) {
            // On time - maintain or improve score
            if (node.uptimeScore < 100) {
                node.uptimeScore = node.uptimeScore + 1 > 100 ? 100 : node.uptimeScore + 1;
            }
        } else {
            // Late - reduce score
            uint256 missedIntervals = timeSinceLastHeartbeat / HEARTBEAT_INTERVAL;
            uint256 penalty = missedIntervals * 5;
            node.uptimeScore = node.uptimeScore > penalty ? node.uptimeScore - penalty : 0;
        }

        node.lastHeartbeat = block.timestamp;

        // Auto-suspend if uptime drops too low
        if (node.uptimeScore < UPTIME_THRESHOLD) {
            NodeStatus oldStatus = node.status;
            node.status = NodeStatus.Suspended;
            node.isActive = false;
            activeNodes--;
            emit NodeStatusChanged(_nodeId, oldStatus, NodeStatus.Suspended);
        }

        emit HeartbeatReceived(_nodeId, block.timestamp, node.uptimeScore);
    }

    // ============ Escrow Integration ============

    /**
     * @notice Add earnings to a node (called by escrow contract)
     * @param _nodeId Node identifier
     * @param _amount Amount to add
     */
    function addEarnings(bytes32 _nodeId, uint256 _amount)
        external
        payable
        onlyEscrow
        nodeExists(_nodeId)
    {
        require(msg.value == _amount, "Amount mismatch");

        NodeInfo storage node = nodes[_nodeId];
        node.totalEarnings += _amount;

        emit EarningsAdded(_nodeId, _amount);
    }

    /**
     * @notice Record bandwidth usage (called by escrow contract)
     * @param _nodeId Node identifier
     * @param _bytes Bytes served
     */
    function recordBandwidthUsage(bytes32 _nodeId, uint256 _bytes)
        external
        onlyEscrow
        nodeExists(_nodeId)
    {
        NodeInfo storage node = nodes[_nodeId];
        node.totalBandwidthServed += _bytes;
        node.sessionCount++;
    }

    /**
     * @notice Record a rating for a node (called by escrow contract)
     * @param _nodeId Node identifier
     * @param _rating Rating value (0-500)
     */
    function recordRating(bytes32 _nodeId, uint256 _rating, address _user)
        external
        onlyEscrow
        nodeExists(_nodeId)
    {
        require(_rating <= 500, "Rating must be 0-500");

        NodeInfo storage node = nodes[_nodeId];

        // Calculate new average rating
        uint256 totalRating = node.rating * node.ratingCount + _rating;
        node.ratingCount++;
        node.rating = totalRating / node.ratingCount;

        emit NodeRated(_nodeId, _user, _rating);
    }

    /**
     * @notice Slash a node for violations (called by owner or escrow)
     * @param _nodeId Node identifier
     * @param _reason Reason for slashing
     */
    function slashNode(bytes32 _nodeId, string calldata _reason)
        external
        onlyOwnerOrEscrow
        nodeExists(_nodeId)
    {
        NodeInfo storage node = nodes[_nodeId];

        require(node.status != NodeStatus.Slashed, "Already slashed");

        uint256 slashAmount = (node.stakedAmount * SLASH_PERCENTAGE) / 100;
        node.stakedAmount -= slashAmount;

        NodeStatus oldStatus = node.status;
        node.status = NodeStatus.Slashed;
        node.isActive = false;

        if (oldStatus == NodeStatus.Active) {
            activeNodes--;
        }

        // Slashed funds go to contract owner (treasury)
        (bool success,) = payable(owner).call{ value: slashAmount }("");
        require(success, "Slash transfer failed");

        emit NodeSlashed(_nodeId, slashAmount, _reason);
        emit NodeStatusChanged(_nodeId, oldStatus, NodeStatus.Slashed);
    }

    // ============ Price Functions ============

    /**
     * @notice Get current FLR/USD price from FTSO
     * @return price Current price
     * @return decimals Decimal places
     * @return timestamp Last update time
     */
    function getFlrUsdPrice() public view returns (uint256 price, int8 decimals, uint64 timestamp) {
        return ftsoV2.getFeedById(FLR_USD_FEED_ID);
    }

    /**
     * @notice Calculate bandwidth cost in FLR
     * @param _nodeId Node identifier
     * @param _bytes Amount of bandwidth in bytes
     * @return Cost in FLR (wei)
     */
    function calculateCostInFlr(bytes32 _nodeId, uint256 _bytes)
        public
        view
        nodeExists(_nodeId)
        returns (uint256)
    {
        NodeInfo storage node = nodes[_nodeId];

        // Convert bytes to GB (with 18 decimal precision)
        uint256 gigabytes = (_bytes * 1e18) / (1024 * 1024 * 1024);

        // Get current FLR/USD price
        (uint256 flrPrice, int8 decimals,) = getFlrUsdPrice();

        if (flrPrice == 0) {
            // Fallback if FTSO unavailable: assume $0.02 per FLR
            flrPrice = 2;
            decimals = 2;
        }

        // Calculate cost in USD cents
        // bandwidthPrice is in cents per GB
        uint256 costUsdCents = (node.bandwidthPrice * gigabytes) / 1e18;

        // Convert to FLR
        // FLR = (USD cents / 100) / (flrPrice / 10^decimals)
        // FLR = (costUsdCents * 10^decimals) / (flrPrice * 100)
        uint256 costInFlr;
        if (decimals >= 0) {
            costInFlr = (costUsdCents * (10 ** uint8(decimals))) / (flrPrice * 100);
        } else {
            costInFlr = (costUsdCents) / (flrPrice * 100 * (10 ** uint8(-decimals)));
        }

        return costInFlr * 1 ether;
    }

    // ============ View Functions ============

    /**
     * @notice Get detailed node information
     * @param _nodeId Node identifier
     * @return NodeInfo struct
     */
    function getNodeInfo(bytes32 _nodeId)
        external
        view
        nodeExists(_nodeId)
        returns (NodeInfo memory)
    {
        return nodes[_nodeId];
    }

    /**
     * @notice Get all nodes owned by an address
     * @param _owner Owner address
     * @return Array of node IDs
     */
    function getNodesByOwner(address _owner) external view returns (bytes32[] memory) {
        return ownerNodes[_owner];
    }

    /**
     * @notice Get all active node IDs
     * @return Array of active node IDs
     */
    function getActiveNodeIds() external view returns (bytes32[] memory) {
        bytes32[] memory activeNodeList = new bytes32[](activeNodes);
        uint256 index = 0;

        for (uint256 i = 0; i < allNodeIds.length && index < activeNodes; i++) {
            if (nodes[allNodeIds[i]].isActive) {
                activeNodeList[index] = allNodeIds[i];
                index++;
            }
        }

        return activeNodeList;
    }

    /**
     * @notice Get all active nodes with full details
     * @return Array of NodeInfo structs
     */
    function getActiveNodes() external view returns (NodeInfo[] memory) {
        NodeInfo[] memory activeNodeList = new NodeInfo[](activeNodes);
        uint256 index = 0;

        for (uint256 i = 0; i < allNodeIds.length && index < activeNodes; i++) {
            if (nodes[allNodeIds[i]].isActive) {
                activeNodeList[index] = nodes[allNodeIds[i]];
                index++;
            }
        }

        return activeNodeList;
    }

    /**
     * @notice Get nodes by location
     * @param _location ISO country code
     * @return Array of node IDs
     */
    function getNodesByLocation(string calldata _location)
        external
        view
        returns (bytes32[] memory)
    {
        uint256 count = 0;

        for (uint256 i = 0; i < allNodeIds.length; i++) {
            if (
                keccak256(bytes(nodes[allNodeIds[i]].location)) == keccak256(bytes(_location))
                    && nodes[allNodeIds[i]].isActive
            ) {
                count++;
            }
        }

        bytes32[] memory locationNodes = new bytes32[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < allNodeIds.length; i++) {
            if (
                keccak256(bytes(nodes[allNodeIds[i]].location)) == keccak256(bytes(_location))
                    && nodes[allNodeIds[i]].isActive
            ) {
                locationNodes[index] = allNodeIds[i];
                index++;
            }
        }

        return locationNodes;
    }

    /**
     * @notice Get network statistics
     * @return _totalNodes Total registered nodes
     * @return _activeNodes Currently active nodes
     * @return _totalStaked Total FLR staked
     * @return _totalBandwidth Total bandwidth served (bytes)
     */
    function getNetworkStats()
        external
        view
        returns (
            uint256 _totalNodes,
            uint256 _activeNodes,
            uint256 _totalStaked,
            uint256 _totalBandwidth
        )
    {
        uint256 totalStaked = 0;
        uint256 totalBandwidth = 0;

        for (uint256 i = 0; i < allNodeIds.length; i++) {
            totalStaked += nodes[allNodeIds[i]].stakedAmount;
            totalBandwidth += nodes[allNodeIds[i]].totalBandwidthServed;
        }

        return (totalNodes, activeNodes, totalStaked, totalBandwidth);
    }

    /**
     * @notice Check if a node is healthy (good uptime, active)
     * @param _nodeId Node identifier
     * @return isHealthy True if node is healthy
     */
    function isNodeHealthy(bytes32 _nodeId) external view nodeExists(_nodeId) returns (bool) {
        NodeInfo storage node = nodes[_nodeId];

        return (node.isActive && node.status == NodeStatus.Active
                && node.uptimeScore >= UPTIME_THRESHOLD
                && block.timestamp - node.lastHeartbeat <= HEARTBEAT_INTERVAL * 3);
    }

    // ============ Receive Function ============
    receive() external payable {
        revert("Use registerNode or increaseStake");
    }
}
