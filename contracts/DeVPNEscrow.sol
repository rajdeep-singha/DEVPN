// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;


 // Manages trustless payments between VPN users and node providers

interface IDeVPNNodeRegistry {
    function getNodeInfo(bytes32 _nodeId) external view returns (
        address owner,
        string memory endpoint,
        string memory publicKey,
        uint256 stakedAmount,
        uint256 stakeTimestamp,
        uint256 bandwidthPrice,
        string memory location,
        uint256 maxBandwidth,
        uint8 status,
        uint256 totalBandwidthServed,
        uint256 lastHeartbeat,
        uint256 uptimeScore,
        bool isActive
    );
    
    function calculateCostInFlr(bytes32 _nodeId, uint256 _gigabytes) 
        external view returns (uint256);
    
    function recordBandwidthUsage(bytes32 _nodeId, uint256 _gigabytes) external;
}

contract DeVPNEscrow {
    
    //  State Variables 
    
    IDeVPNNodeRegistry public nodeRegistry;
    
    uint256 public constant MIN_SESSION_DEPOSIT = 0.1 ether;
    uint256 public constant MAX_SESSION_DURATION = 24 hours;
    uint256 public constant SETTLEMENT_INTERVAL = 5 minutes;
    uint256 public constant DISPUTE_PERIOD = 1 hours;
    
    struct Session {
        bytes32 sessionId;
        address user;
        bytes32 nodeId;
        uint256 depositAmount;
        uint256 startTime;
        uint256 lastSettlement;
        uint256 bandwidthUsed; // in GB (with 3 decimals, so 1000 = 1GB)
        uint256 totalPaid;
        SessionStatus status;
        uint256 endTime;
    }
    
    enum SessionStatus {
        Active,      
        Completed,   
        Disputed,    
        Refunded,   
        Settled      
    }
    
    struct Dispute {
        bytes32 sessionId;
        address initiator;
        string reason;
        uint256 timestamp;
        uint256 claimedBandwidth;
        bool resolved;
        bool userFavored;
    }
    
    // Session ID 
    mapping(bytes32 => Session) public sessions;
    
    // User address
    mapping(address => bytes32[]) public userSessions;
    
    // Node ID 
    mapping(bytes32 => bytes32[]) public nodeSessions;
    
    // Session ID 
    mapping(bytes32 => Dispute) public disputes;
    
    // Provider earnings : mostly pending withdrawals ke liye 
    mapping(address => uint256) public providerBalances;
    
    uint256 public totalSessions;
    uint256 public activeSessions;
    
    //  Events
    
    event SessionCreated(
        bytes32 indexed sessionId,
        address indexed user,
        bytes32 indexed nodeId,
        uint256 depositAmount
    );
    
    event BandwidthReported(
        bytes32 indexed sessionId,
        uint256 bandwidthUsed,
        uint256 amountPaid
    );
    
    event SessionSettled(
        bytes32 indexed sessionId,
        uint256 totalPaid,
        uint256 refundAmount
    );
    
    event SessionCompleted(
        bytes32 indexed sessionId,
        uint256 totalBandwidth,
        uint256 totalCost
    );
    
    event DisputeRaised(
        bytes32 indexed sessionId,
        address indexed initiator,
        string reason
    );
    
    event DisputeResolved(
        bytes32 indexed sessionId,
        bool userFavored,
        uint256 refundAmount
    );
    
    event FundsWithdrawn(
        address indexed provider,
        uint256 amount
    );
    
    // Modifiers 
    
    modifier onlySessionUser(bytes32 _sessionId) {
        require(sessions[_sessionId].user == msg.sender, "Not session user");
        _;
    }
    
    modifier sessionExists(bytes32 _sessionId) {
        require(
            sessions[_sessionId].user != address(0),
            "Session does not exist"
        );
        _;
    }
    
    modifier sessionActive(bytes32 _sessionId) {
        require(
            sessions[_sessionId].status == SessionStatus.Active,
            "Session not active"
        );
        _;
    }
    
    // Constructor 
    
    constructor(address _nodeRegistry) {
        require(_nodeRegistry != address(0), "Invalid registry address");
        nodeRegistry = IDeVPNNodeRegistry(_nodeRegistry);
    }
    
    // Core Functions 
    

    function startSession(bytes32 _nodeId) 
        external 
        payable 
        returns (bytes32) 
    {
        require(msg.value >= MIN_SESSION_DEPOSIT, "Insufficient deposit");
        
        // Verify node is active
        (address nodeOwner,,,,,,,,, bool isActive) = _getNodeBasicInfo(_nodeId);
        require(isActive, "Node not active");
        require(nodeOwner != address(0), "Invalid node");
        
        // Generate unique session ID
        bytes32 sessionId = keccak256(
            abi.encodePacked(msg.sender, _nodeId, block.timestamp, totalSessions)
        );
        
        sessions[sessionId] = Session({
            sessionId: sessionId,
            user: msg.sender,
            nodeId: _nodeId,
            depositAmount: msg.value,
            startTime: block.timestamp,
            lastSettlement: block.timestamp,
            bandwidthUsed: 0,
            totalPaid: 0,
            status: SessionStatus.Active,
            endTime: 0
        });
        
        userSessions[msg.sender].push(sessionId);
        nodeSessions[_nodeId].push(sessionId);
        
        totalSessions++;
        activeSessions++;
        
        emit SessionCreated(sessionId, msg.sender, _nodeId, msg.value);
        
        return sessionId;
    }
    
    
     // Report bandwidth usage for a session
     
    function reportBandwidth(bytes32 _sessionId, uint256 _bandwidthGb) 
        external 
        sessionExists(_sessionId) 
        sessionActive(_sessionId) 
    {
        Session storage session = sessions[_sessionId];
        
        // In production, verify caller is authorized (oracle or node owner)
        (address nodeOwner,,,,,,,,,) = _getNodeBasicInfo(session.nodeId);
        require(msg.sender == nodeOwner, "Not authorized");
        
       
        require(
            block.timestamp >= session.lastSettlement + SETTLEMENT_INTERVAL,
            "Settlement interval not reached"
        );
        
   
        uint256 newBandwidth = _bandwidthGb;
        session.bandwidthUsed += newBandwidth;
        
        
        uint256 cost = nodeRegistry.calculateCostInFlr(
            session.nodeId,
            newBandwidth / 1000 // Convert back to GB
        );
        
      
        require(
            session.totalPaid + cost <= session.depositAmount,
            "Insufficient deposit for usage"
        );
        
       
        session.totalPaid += cost;
        session.lastSettlement = block.timestamp;
        
      
        providerBalances[nodeOwner] += cost;
        
        emit BandwidthReported(_sessionId, newBandwidth, cost);
        
       
        nodeRegistry.recordBandwidthUsage(
            session.nodeId,
            newBandwidth / 1000
        );
    }
    
   
    // End a session and settle remaining balance
   
    function endSession(bytes32 _sessionId) 
        external 
        onlySessionUser(_sessionId) 
        sessionExists(_sessionId) 
        sessionActive(_sessionId) 
    {
        Session storage session = sessions[_sessionId];
        
        // Calculate final settlement
        uint256 refund = session.depositAmount - session.totalPaid;
        
        session.status = SessionStatus.Completed;
        session.endTime = block.timestamp;
        activeSessions--;
        
        // Refund remaining deposit to user
        if (refund > 0) {
            (bool success, ) = payable(session.user).call{value: refund}("");
            require(success, "Refund failed");
        }
        
        emit SessionCompleted(
            _sessionId,
            session.bandwidthUsed,
            session.totalPaid
        );
        emit SessionSettled(_sessionId, session.totalPaid, refund);
    }
    
    
   // Force-end a session (if node goes offline)
    
    function forceEndSession(bytes32 _sessionId) 
        external 
        sessionExists(_sessionId) 
        sessionActive(_sessionId) 
    {
        Session storage session = sessions[_sessionId];
        
        // Check if session has exceeded max duration or node is offline
        require(
            block.timestamp > session.startTime + MAX_SESSION_DURATION,
            "Session not expired"
        );
        
        uint256 refund = session.depositAmount - session.totalPaid;
        
        session.status = SessionStatus.Refunded;
        session.endTime = block.timestamp;
        activeSessions--;
        
        // Refund to user
        if (refund > 0) {
            (bool success, ) = payable(session.user).call{value: refund}("");
            require(success, "Refund failed");
        }
        
        emit SessionSettled(_sessionId, session.totalPaid, refund);
    }
    
    
    // Raise a dispute for a session
    function raiseDispute(
        bytes32 _sessionId,
        string memory _reason,
        uint256 _claimedBandwidth
    ) 
        external 
        onlySessionUser(_sessionId) 
        sessionExists(_sessionId) 
    {
        Session storage session = sessions[_sessionId];
        
        require(
            session.status == SessionStatus.Active ||
            session.status == SessionStatus.Completed,
            "Cannot dispute this session"
        );
        
        require(disputes[_sessionId].timestamp == 0, "Dispute already exists");
        
        session.status = SessionStatus.Disputed;
        
        disputes[_sessionId] = Dispute({
            sessionId: _sessionId,
            initiator: msg.sender,
            reason: _reason,
            timestamp: block.timestamp,
            claimedBandwidth: _claimedBandwidth,
            resolved: false,
            userFavored: false
        });
        
        emit DisputeRaised(_sessionId, msg.sender, _reason);
    }
    
    // Resolve a dispute (to be called by governance/arbitration in production) : In future governance dao banana hoga 
    function resolveDispute(
        bytes32 _sessionId,
        bool _favorUser,
        uint256 _refundAmount
    ) external {
        // In production, restrict to governance/arbitration contract
        Dispute storage dispute = disputes[_sessionId];
        Session storage session = sessions[_sessionId];
        
        require(!dispute.resolved, "Dispute already resolved");
        require(dispute.timestamp > 0, "No dispute exists");
        
        dispute.resolved = true;
        dispute.userFavored = _favorUser;
        
        if (_favorUser && _refundAmount > 0) {
            // Get node owner to deduct from their balance
            (address nodeOwner,,,,,,,,,) = _getNodeBasicInfo(session.nodeId);
            
           
            if (providerBalances[nodeOwner] >= _refundAmount) {
                providerBalances[nodeOwner] -= _refundAmount;
            }
            
           
            (bool success, ) = payable(session.user).call{value: _refundAmount}("");
            require(success, "Refund failed");
        }
        
        session.status = SessionStatus.Settled;
        
        emit DisputeResolved(_sessionId, _favorUser, _refundAmount);
    }
    
    // Withdraw provider earnings
    function withdrawEarnings() external {
        uint256 balance = providerBalances[msg.sender];
        require(balance > 0, "No balance to withdraw");
        
        providerBalances[msg.sender] = 0;
        
        (bool success, ) = payable(msg.sender).call{value: balance}("");
        require(success, "Withdrawal failed");
        
        emit FundsWithdrawn(msg.sender, balance);
    }
    
    // View Functions 
    
    
    function getSession(bytes32 _sessionId) 
        external 
        view 
        sessionExists(_sessionId) 
        returns (Session memory) 
    {
        return sessions[_sessionId];
    }
    
  
    function getUserSessions(address _user) 
        external 
        view 
        returns (bytes32[] memory) 
    {
        return userSessions[_user];
    }
    
   
    function getNodeSessions(bytes32 _nodeId) 
        external 
        view 
        returns (bytes32[] memory) 
    {
        return nodeSessions[_nodeId];
    }
    
    
    function getProviderBalance(address _provider) 
        external 
        view 
        returns (uint256) 
    {
        return providerBalances[_provider];
    }
    
    
    function getDispute(bytes32 _sessionId) 
        external 
        view 
        returns (Dispute memory) 
    {
        return disputes[_sessionId];
    }
    
    // Internal Functions 
    
    function _getNodeBasicInfo(bytes32 _nodeId) 
        internal 
        view 
        returns (
            address owner,
            string memory endpoint,
            string memory publicKey,
            uint256 stakedAmount,
            uint256 stakeTimestamp,
            uint256 bandwidthPrice,
            string memory location,
            uint256 maxBandwidth,
            uint8 status,
            bool isActive
        ) 
    {
        (
            owner,
            endpoint,
            publicKey,
            stakedAmount,
            stakeTimestamp,
            bandwidthPrice,
            location,
            maxBandwidth,
            status,
            ,
            ,
            ,
            isActive
        ) = nodeRegistry.getNodeInfo(_nodeId);
    }
}