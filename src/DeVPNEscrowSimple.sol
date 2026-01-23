// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeVPNnoderegistery.sol";

/**
 * @title DeVPNEscrowSimple
 * @notice Simplified escrow for DeVPN with single-transaction settlement
 * @dev Eliminates complex multi-step settlement and delays
 */
contract DeVPNEscrowSimple {
    // ============ State Variables ============
    DeVPNNodeRegistry public nodeRegistry;
    address public owner;
    address public stateConnector;

    uint256 public constant PROTOCOL_FEE_BPS = 500; // 5% protocol fee
    uint256 public constant MAX_SESSION_DURATION = 24 hours;
    uint256 public constant MIN_DEPOSIT = 0.1 ether;
    uint256 public constant MIN_BYTES_CHARGE = 1024 * 1024; // 1 MB minimum
    uint256 public constant FORCE_SETTLE_DELAY = 1 hours; // Node can force-settle after 1 hour
    uint256 public constant DISPUTE_WINDOW = 1 hours; // 1 hour to dispute after settlement

    uint256 public sessionCounter;
    uint256 public totalProtocolFees;
    uint256 public totalVolumeProcessed;

    // ============ Structs ============
    struct Session {
        uint256 id;
        bytes32 nodeId;
        address user;
        string userPublicKey;
        uint256 deposit;
        uint256 startTime;
        uint256 settlementTime; // When session was settled
        uint256 bytesUsed;
        uint256 costInFlr;
        SessionStatus status;
        bool disputed;
        address settler; // Who settled the session
    }

    enum SessionStatus {
        Active, // 0 - Session ongoing
        Settled, // 1 - Payment processed (FINAL)
        Disputed, // 2 - Under dispute
        Expired // 3 - Expired and refunded
    }

    // ============ Mappings ============
    mapping(uint256 => Session) public sessions;
    mapping(address => uint256[]) public userSessions;
    mapping(bytes32 => uint256[]) public nodeSessions;
    mapping(address => uint256) public activeSessionId;
    mapping(bytes32 => uint256) public nodeActiveSessionCount;

    // ============ Events ============
    event SessionStarted(
        uint256 indexed sessionId,
        bytes32 indexed nodeId,
        address indexed user,
        uint256 deposit,
        string userPublicKey
    );

    event SessionSettled(
        uint256 indexed sessionId,
        address indexed settler,
        uint256 bytesUsed,
        uint256 nodePayout,
        uint256 userRefund,
        uint256 protocolFee
    );

    event SessionDisputed(uint256 indexed sessionId, address indexed disputer, string reason);

    event DisputeResolved(uint256 indexed sessionId, bool inFavorOfUser, uint256 refundAmount);

    event SessionExpired(uint256 indexed sessionId, uint256 refundAmount);

    event ProtocolFeesWithdrawn(address indexed recipient, uint256 amount);
    event StateConnectorUpdated(address indexed newConnector);

    // ============ Modifiers ============
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier sessionExists(uint256 _sessionId) {
        require(sessions[_sessionId].user != address(0), "Session does not exist");
        _;
    }

    modifier onlySessionUser(uint256 _sessionId) {
        require(sessions[_sessionId].user == msg.sender, "Not session user");
        _;
    }

    modifier onlyNodeOwner(uint256 _sessionId) {
        DeVPNNodeRegistry.NodeInfo memory node =
            nodeRegistry.getNodeInfo(sessions[_sessionId].nodeId);
        require(node.owner == msg.sender, "Not node owner");
        _;
    }

    // ============ Constructor ============
    constructor(address _nodeRegistry) {
        require(_nodeRegistry != address(0), "Invalid registry address");
        nodeRegistry = DeVPNNodeRegistry(payable(_nodeRegistry));
        owner = msg.sender;
    }

    // ============ Admin Functions ============

    function setStateConnector(address _stateConnector) external onlyOwner {
        require(_stateConnector != address(0), "Invalid address");
        stateConnector = _stateConnector;
        emit StateConnectorUpdated(_stateConnector);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid address");
        owner = _newOwner;
    }

    function withdrawProtocolFees() external onlyOwner {
        uint256 amount = totalProtocolFees;
        require(amount > 0, "No fees to withdraw");
        totalProtocolFees = 0;
        (bool success,) = payable(owner).call{ value: amount }("");
        require(success, "Transfer failed");
        emit ProtocolFeesWithdrawn(owner, amount);
    }

    // ============ Session Management ============

    /**
     * @notice Start a new VPN session
     * @param _nodeId The node to connect to
     * @param _userPublicKey User's WireGuard public key
     * @return sessionId The ID of the created session
     */
    function startSession(bytes32 _nodeId, string calldata _userPublicKey)
        external
        payable
        returns (uint256)
    {
        require(msg.value >= MIN_DEPOSIT, "Insufficient deposit");
        require(bytes(_userPublicKey).length == 44, "Invalid WireGuard key");
        require(activeSessionId[msg.sender] == 0, "Already have active session");

        DeVPNNodeRegistry.NodeInfo memory node = nodeRegistry.getNodeInfo(_nodeId);
        require(node.isActive, "Node not active");
        require(node.owner != msg.sender, "Cannot connect to own node");

        sessionCounter++;
        uint256 sessionId = sessionCounter;

        sessions[sessionId] = Session({
            id: sessionId,
            nodeId: _nodeId,
            user: msg.sender,
            userPublicKey: _userPublicKey,
            deposit: msg.value,
            startTime: block.timestamp,
            settlementTime: 0,
            bytesUsed: 0,
            costInFlr: 0,
            status: SessionStatus.Active,
            disputed: false,
            settler: address(0)
        });

        userSessions[msg.sender].push(sessionId);
        nodeSessions[_nodeId].push(sessionId);
        activeSessionId[msg.sender] = sessionId;
        nodeActiveSessionCount[_nodeId]++;

        emit SessionStarted(sessionId, _nodeId, msg.sender, msg.value, _userPublicKey);
        return sessionId;
    }

    /**
     * @notice User ends session and settles payment in ONE transaction
     * @param _sessionId The session to end
     * @param _bytesUsed Bytes consumed by user
     */
    function endSessionAndSettle(uint256 _sessionId, uint256 _bytesUsed)
        external
        sessionExists(_sessionId)
        onlySessionUser(_sessionId)
    {
        Session storage session = sessions[_sessionId];
        require(session.status == SessionStatus.Active, "Session not active");
        require(_bytesUsed >= MIN_BYTES_CHARGE, "Below minimum charge");

        // Update session state
        session.status = SessionStatus.Settled;
        session.settlementTime = block.timestamp;
        session.bytesUsed = _bytesUsed;
        session.settler = msg.sender;

        // Clear active session
        activeSessionId[msg.sender] = 0;
        nodeActiveSessionCount[session.nodeId]--;

        // Calculate and distribute payment
        _settlePayment(_sessionId, _bytesUsed);
    }

    /**
     * @notice Node force-settles session after timeout or user abandonment
     * @param _sessionId The session to settle
     * @param _actualBytesUsed Actual bytes used (from WireGuard stats)
     */
    function forceSettleSession(uint256 _sessionId, uint256 _actualBytesUsed)
        external
        sessionExists(_sessionId)
        onlyNodeOwner(_sessionId)
    {
        Session storage session = sessions[_sessionId];
        require(session.status == SessionStatus.Active, "Session not active");
        require(
            block.timestamp >= session.startTime + FORCE_SETTLE_DELAY, "Too early to force settle"
        );

        // Use max of user's reported bytes (if any) and node's actual bytes
        uint256 bytesToCharge =
            _actualBytesUsed > session.bytesUsed ? _actualBytesUsed : session.bytesUsed;

        if (bytesToCharge < MIN_BYTES_CHARGE) {
            bytesToCharge = MIN_BYTES_CHARGE;
        }

        // Update session state
        session.status = SessionStatus.Settled;
        session.settlementTime = block.timestamp;
        session.bytesUsed = bytesToCharge;
        session.settler = msg.sender;

        // Clear active session if still active
        if (activeSessionId[session.user] == _sessionId) {
            activeSessionId[session.user] = 0;
        }
        nodeActiveSessionCount[session.nodeId]--;

        // Calculate and distribute payment
        _settlePayment(_sessionId, bytesToCharge);
    }

    /**
     * @notice Internal function to calculate and distribute payment
     * @param _sessionId The session to settle
     * @param _bytes Bytes to charge for
     */
    function _settlePayment(uint256 _sessionId, uint256 _bytes) private {
        Session storage session = sessions[_sessionId];

        // Calculate cost using NodeRegistry's FTSO-based pricing
        uint256 cost = nodeRegistry.calculateCostInFlr(session.nodeId, _bytes);

        // Cap cost at deposit
        if (cost > session.deposit) {
            cost = session.deposit;
        }
        session.costInFlr = cost;

        // Split payment
        uint256 protocolFee = (cost * PROTOCOL_FEE_BPS) / 10_000; // 5%
        uint256 nodePayout = cost - protocolFee;
        uint256 userRefund = session.deposit - cost;

        // Update totals
        totalProtocolFees += protocolFee;
        totalVolumeProcessed += cost;

        // Transfer node payout via NodeRegistry
        if (nodePayout > 0) {
            nodeRegistry.addEarnings{ value: nodePayout }(session.nodeId, nodePayout);
        }

        // Record bandwidth usage
        nodeRegistry.recordBandwidthUsage(session.nodeId, _bytes);

        // Refund user if any deposit remains
        if (userRefund > 0) {
            (bool success,) = payable(session.user).call{ value: userRefund }("");
            require(success, "Refund failed");
        }

        emit SessionSettled(
            _sessionId, session.settler, _bytes, nodePayout, userRefund, protocolFee
        );
    }

    /**
     * @notice Auto-expire session after MAX_SESSION_DURATION
     * @param _sessionId The session to expire
     */
    function expireSession(uint256 _sessionId) external sessionExists(_sessionId) {
        Session storage session = sessions[_sessionId];
        require(session.status == SessionStatus.Active, "Not active");
        require(block.timestamp >= session.startTime + MAX_SESSION_DURATION, "Not expired yet");

        // Mark as expired
        session.status = SessionStatus.Expired;
        session.settlementTime = block.timestamp;

        // Clear active session
        if (activeSessionId[session.user] == _sessionId) {
            activeSessionId[session.user] = 0;
        }
        nodeActiveSessionCount[session.nodeId]--;

        // Full refund to user
        (bool success,) = payable(session.user).call{ value: session.deposit }("");
        require(success, "Refund failed");

        emit SessionExpired(_sessionId, session.deposit);
    }

    // ============ Dispute Functions ============

    /**
     * @notice Dispute a session (before or after settlement)
     * @param _sessionId The session to dispute
     * @param _reason Reason for dispute
     */
    function disputeSession(uint256 _sessionId, string calldata _reason)
        external
        sessionExists(_sessionId)
    {
        Session storage session = sessions[_sessionId];

        // Can only dispute Active or recently Settled sessions
        if (session.status == SessionStatus.Settled) {
            require(
                block.timestamp <= session.settlementTime + DISPUTE_WINDOW, "Dispute window closed"
            );
        } else {
            require(session.status == SessionStatus.Active, "Cannot dispute");
        }

        // Only user or node owner can dispute
        DeVPNNodeRegistry.NodeInfo memory node = nodeRegistry.getNodeInfo(session.nodeId);
        require(msg.sender == session.user || msg.sender == node.owner, "Not authorized");
        require(!session.disputed, "Already disputed");

        session.disputed = true;
        session.status = SessionStatus.Disputed;

        emit SessionDisputed(_sessionId, msg.sender, _reason);
    }

    /**
     * @notice Resolve dispute (owner only)
     * @param _sessionId The session in dispute
     * @param _inFavorOfUser True if user wins dispute
     * @param _correctBytesUsed Correct bandwidth usage
     */
    function resolveDispute(uint256 _sessionId, bool _inFavorOfUser, uint256 _correctBytesUsed)
        external
        onlyOwner
        sessionExists(_sessionId)
    {
        Session storage session = sessions[_sessionId];
        require(session.status == SessionStatus.Disputed, "Not disputed");

        session.bytesUsed = _correctBytesUsed;

        if (_inFavorOfUser) {
            // Full refund to user
            session.status = SessionStatus.Settled;
            session.settlementTime = block.timestamp;

            (bool success,) = payable(session.user).call{ value: session.deposit }("");
            require(success, "Refund failed");

            // Slash the node for misbehavior
            nodeRegistry.slashNode(session.nodeId, "Dispute lost");

            emit DisputeResolved(_sessionId, true, session.deposit);
        } else {
            // Re-settle with correct bytes
            session.status = SessionStatus.Active; // Temporarily set to Active
            session.status = SessionStatus.Settled; // Then settle
            session.settlementTime = block.timestamp;

            _settlePayment(_sessionId, _correctBytesUsed);

            emit DisputeResolved(_sessionId, false, session.deposit - session.costInFlr);
        }
    }

    // ============ View Functions ============

    function getSession(uint256 _sessionId)
        external
        view
        sessionExists(_sessionId)
        returns (Session memory)
    {
        return sessions[_sessionId];
    }

    function getUserSessions(address _user) external view returns (uint256[] memory) {
        return userSessions[_user];
    }

    function getUserSessionDetails(address _user) external view returns (Session[] memory) {
        uint256[] memory ids = userSessions[_user];
        Session[] memory result = new Session[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = sessions[ids[i]];
        }
        return result;
    }

    function getNodeSessions(bytes32 _nodeId) external view returns (uint256[] memory) {
        return nodeSessions[_nodeId];
    }

    function getNodeSessionDetails(bytes32 _nodeId) external view returns (Session[] memory) {
        uint256[] memory ids = nodeSessions[_nodeId];
        Session[] memory result = new Session[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = sessions[ids[i]];
        }
        return result;
    }

    function getActiveSession(address _user) external view returns (Session memory) {
        uint256 id = activeSessionId[_user];
        if (id == 0) {
            return Session(
                0,
                bytes32(0),
                address(0),
                "",
                0,
                0,
                0,
                0,
                0,
                SessionStatus.Active,
                false,
                address(0)
            );
        }
        return sessions[id];
    }

    function hasActiveSession(address _user) external view returns (bool, uint256) {
        uint256 id = activeSessionId[_user];
        return (id != 0, id);
    }

    function getEscrowStats() external view returns (uint256, uint256, uint256) {
        return (sessionCounter, totalVolumeProcessed, totalProtocolFees);
    }

    function estimateSessionCost(bytes32 _nodeId, uint256 _bytes)
        external
        view
        returns (uint256 cost, uint256 fee, uint256 payout)
    {
        cost = nodeRegistry.calculateCostInFlr(_nodeId, _bytes);
        fee = (cost * PROTOCOL_FEE_BPS) / 10_000;
        payout = cost - fee;
    }

    /**
     * @notice Check if session can be force-settled by node
     * @param _sessionId The session to check
     * @return allowed Whether force settlement is allowed
     * @return timeRemaining Seconds until force settlement is allowed
     */
    function canForceSettle(uint256 _sessionId)
        external
        view
        sessionExists(_sessionId)
        returns (bool allowed, uint256 timeRemaining)
    {
        Session memory session = sessions[_sessionId];

        if (session.status != SessionStatus.Active) {
            return (false, 0);
        }

        uint256 forceSettleTime = session.startTime + FORCE_SETTLE_DELAY;

        if (block.timestamp >= forceSettleTime) {
            return (true, 0);
        } else {
            return (false, forceSettleTime - block.timestamp);
        }
    }

    /**
     * @notice Check if session can be expired
     * @param _sessionId The session to check
     * @return allowed Whether expiration is allowed
     * @return timeRemaining Seconds until expiration is allowed
     */
    function canExpire(uint256 _sessionId)
        external
        view
        sessionExists(_sessionId)
        returns (bool allowed, uint256 timeRemaining)
    {
        Session memory session = sessions[_sessionId];

        if (session.status != SessionStatus.Active) {
            return (false, 0);
        }

        uint256 expiryTime = session.startTime + MAX_SESSION_DURATION;

        if (block.timestamp >= expiryTime) {
            return (true, 0);
        } else {
            return (false, expiryTime - block.timestamp);
        }
    }

    receive() external payable {
        revert("Use startSession");
    }
}
