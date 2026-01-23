// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeVPNnoderegistery.sol";

/**
 * @title DeVPNEscrow
 * @notice Manages VPN sessions, payments, and escrow for DeVPN
 * @dev Handles deposits, settlements, refunds, and disputes
 */
contract DeVPNEscrow {
    // ============ State Variables ============
    DeVPNNodeRegistry public nodeRegistry;
    address public owner;
    address public stateConnector;

    uint256 public constant PROTOCOL_FEE_BPS = 500; // 5% protocol fee
    uint256 public constant MAX_SESSION_DURATION = 24 hours;
    uint256 public constant MIN_DEPOSIT = 0.1 ether;
    uint256 public constant DISPUTE_PERIOD = 1 hours;
    uint256 public constant SETTLEMENT_DELAY = 5 minutes;

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
        uint256 endTime;
        uint256 bytesUsed;
        uint256 costInFlr;
        SessionStatus status;
        bool disputed;
    }

    enum SessionStatus {
        Active,
        Ended,
        Settled,
        Disputed,
        Refunded,
        Expired
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

    event SessionEnded(uint256 indexed sessionId, uint256 endTime, uint256 bytesUsed);

    event SessionSettled(
        uint256 indexed sessionId, uint256 nodePayout, uint256 userRefund, uint256 protocolFee
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
            endTime: 0,
            bytesUsed: 0,
            costInFlr: 0,
            status: SessionStatus.Active,
            disputed: false
        });

        userSessions[msg.sender].push(sessionId);
        nodeSessions[_nodeId].push(sessionId);
        activeSessionId[msg.sender] = sessionId;
        nodeActiveSessionCount[_nodeId]++;

        emit SessionStarted(sessionId, _nodeId, msg.sender, msg.value, _userPublicKey);
        return sessionId;
    }

    /**
     * @notice End an active session (called by user)
     */
    function endSession(uint256 _sessionId, uint256 _bytesUsed)
        external
        sessionExists(_sessionId)
        onlySessionUser(_sessionId)
    {
        Session storage session = sessions[_sessionId];
        require(session.status == SessionStatus.Active, "Session not active");

        session.status = SessionStatus.Ended;
        session.endTime = block.timestamp;
        session.bytesUsed = _bytesUsed;

        activeSessionId[msg.sender] = 0;
        nodeActiveSessionCount[session.nodeId]--;

        emit SessionEnded(_sessionId, session.endTime, _bytesUsed);
    }

    /**
     * @notice Submit bandwidth usage and settle (called by node)
     */
    function submitUsageAndSettle(uint256 _sessionId, uint256 _actualBytesUsed)
        external
        sessionExists(_sessionId)
    {
        Session storage session = sessions[_sessionId];

        DeVPNNodeRegistry.NodeInfo memory node = nodeRegistry.getNodeInfo(session.nodeId);
        require(node.owner == msg.sender, "Not node owner");
        require(
            session.status == SessionStatus.Active || session.status == SessionStatus.Ended,
            "Cannot settle"
        );

        if (session.status == SessionStatus.Active) {
            session.endTime = block.timestamp;
            activeSessionId[session.user] = 0;
            nodeActiveSessionCount[session.nodeId]--;
        }

        uint256 bytesUsed =
            _actualBytesUsed > session.bytesUsed ? _actualBytesUsed : session.bytesUsed;
        session.bytesUsed = bytesUsed;

        uint256 cost = nodeRegistry.calculateCostInFlr(session.nodeId, bytesUsed);
        if (cost > session.deposit) {
            cost = session.deposit;
        }
        session.costInFlr = cost;

        uint256 protocolFee = (cost * PROTOCOL_FEE_BPS) / 10_000;
        uint256 nodePayout = cost - protocolFee;
        uint256 userRefund = session.deposit - cost;

        session.status = SessionStatus.Settled;
        totalProtocolFees += protocolFee;
        totalVolumeProcessed += cost;

        if (nodePayout > 0) {
            nodeRegistry.addEarnings{ value: nodePayout }(session.nodeId, nodePayout);
        }
        nodeRegistry.recordBandwidthUsage(session.nodeId, bytesUsed);

        if (userRefund > 0) {
            (bool success,) = payable(session.user).call{ value: userRefund }("");
            require(success, "Refund failed");
        }

        emit SessionSettled(_sessionId, nodePayout, userRefund, protocolFee);
    }

    /**
     * @notice Force settle expired session
     */
    function forceSettleExpired(uint256 _sessionId) external sessionExists(_sessionId) {
        Session storage session = sessions[_sessionId];
        require(session.status == SessionStatus.Active, "Not active");
        require(block.timestamp >= session.startTime + MAX_SESSION_DURATION, "Not expired");

        if (activeSessionId[session.user] == _sessionId) {
            activeSessionId[session.user] = 0;
        }
        nodeActiveSessionCount[session.nodeId]--;

        session.status = SessionStatus.Expired;
        session.endTime = block.timestamp;

        (bool success,) = payable(session.user).call{ value: session.deposit }("");
        require(success, "Refund failed");

        emit SessionExpired(_sessionId, session.deposit);
    }

    /**
     * @notice User settle after delay
     */
    function userSettleSession(uint256 _sessionId)
        external
        sessionExists(_sessionId)
        onlySessionUser(_sessionId)
    {
        Session storage session = sessions[_sessionId];
        require(session.status == SessionStatus.Ended, "Not ended");
        require(block.timestamp >= session.endTime + SETTLEMENT_DELAY, "Wait for delay");

        uint256 cost = nodeRegistry.calculateCostInFlr(session.nodeId, session.bytesUsed);
        if (cost > session.deposit) cost = session.deposit;
        session.costInFlr = cost;

        uint256 protocolFee = (cost * PROTOCOL_FEE_BPS) / 10_000;
        uint256 nodePayout = cost - protocolFee;
        uint256 userRefund = session.deposit - cost;

        session.status = SessionStatus.Settled;
        totalProtocolFees += protocolFee;
        totalVolumeProcessed += cost;

        if (nodePayout > 0) {
            nodeRegistry.addEarnings{ value: nodePayout }(session.nodeId, nodePayout);
        }
        nodeRegistry.recordBandwidthUsage(session.nodeId, session.bytesUsed);

        if (userRefund > 0) {
            (bool success,) = payable(session.user).call{ value: userRefund }("");
            require(success, "Refund failed");
        }

        emit SessionSettled(_sessionId, nodePayout, userRefund, protocolFee);
    }

    // ============ Dispute Functions ============

    function disputeSession(uint256 _sessionId, string calldata _reason)
        external
        sessionExists(_sessionId)
    {
        Session storage session = sessions[_sessionId];
        require(
            session.status == SessionStatus.Ended || session.status == SessionStatus.Active,
            "Cannot dispute"
        );

        DeVPNNodeRegistry.NodeInfo memory node = nodeRegistry.getNodeInfo(session.nodeId);
        require(msg.sender == session.user || msg.sender == node.owner, "Not authorized");
        require(!session.disputed, "Already disputed");

        session.disputed = true;
        session.status = SessionStatus.Disputed;

        emit SessionDisputed(_sessionId, msg.sender, _reason);
    }

    function resolveDispute(uint256 _sessionId, bool _inFavorOfUser, uint256 _bytesUsed)
        external
        onlyOwner
        sessionExists(_sessionId)
    {
        Session storage session = sessions[_sessionId];
        require(session.status == SessionStatus.Disputed, "Not disputed");

        session.bytesUsed = _bytesUsed;

        if (_inFavorOfUser) {
            session.status = SessionStatus.Refunded;
            (bool success,) = payable(session.user).call{ value: session.deposit }("");
            require(success, "Refund failed");
            nodeRegistry.slashNode(session.nodeId, "Dispute lost");
            emit DisputeResolved(_sessionId, true, session.deposit);
        } else {
            uint256 cost = nodeRegistry.calculateCostInFlr(session.nodeId, _bytesUsed);
            if (cost > session.deposit) cost = session.deposit;
            session.costInFlr = cost;

            uint256 protocolFee = (cost * PROTOCOL_FEE_BPS) / 10_000;
            uint256 nodePayout = cost - protocolFee;
            uint256 userRefund = session.deposit - cost;

            session.status = SessionStatus.Settled;
            totalProtocolFees += protocolFee;

            if (nodePayout > 0) {
                nodeRegistry.addEarnings{ value: nodePayout }(session.nodeId, nodePayout);
            }
            nodeRegistry.recordBandwidthUsage(session.nodeId, _bytesUsed);

            if (userRefund > 0) {
                (bool success,) = payable(session.user).call{ value: userRefund }("");
                require(success, "Refund failed");
            }

            emit DisputeResolved(_sessionId, false, userRefund);
        }
    }

    // ============ Rating ============

    function rateNode(uint256 _sessionId, uint256 _rating)
        external
        sessionExists(_sessionId)
        onlySessionUser(_sessionId)
    {
        Session storage session = sessions[_sessionId];
        require(
            session.status == SessionStatus.Settled || session.status == SessionStatus.Refunded,
            "Not completed"
        );
        require(_rating <= 500, "Max rating 500");
        nodeRegistry.recordRating(session.nodeId, _rating, msg.sender);
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
            return
                Session(0, bytes32(0), address(0), "", 0, 0, 0, 0, 0, SessionStatus.Active, false);
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

    receive() external payable {
        revert("Use startSession");
    }
}
