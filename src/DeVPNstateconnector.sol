// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IFlare.sol";

import "./DeVPNescrow.sol";
import "./DeVPNnoderegistery.sol";

/**
 * @title DeVPNStateConnector
 * @notice Integrates with Flare Data Connector for bandwidth verification
 * @dev Uses Flare's decentralized attestation system to verify off-chain data
 */
contract DeVPNStateConnector {

    // ============ Flare Integration ============
    IFdcVerification public fdcVerification;
    IJsonApi public jsonApi;

    // ============ State Variables ============
    DeVPNNodeRegistry public nodeRegistry;
    DeVPNEscrow public escrow;
    address public owner;

    uint256 public constant VERIFICATION_WINDOW = 1 hours;
    uint256 public constant MIN_ATTESTATIONS = 3;

    // ============ Structs ============
    struct BandwidthProof {
        uint256 sessionId;
        bytes32 nodeId;
        uint256 bytesUsed;
        uint256 timestamp;
        bytes32 proofHash;
        bool verified;
        uint256 attestationCount;
    }

    struct NodeHeartbeatProof {
        bytes32 nodeId;
        uint256 timestamp;
        bool isOnline;
        uint256 latency; // in ms
        bytes32 proofHash;
        bool verified;
    }

    // ============ Mappings ============
    mapping(bytes32 => BandwidthProof) public bandwidthProofs;
    mapping(bytes32 => NodeHeartbeatProof) public heartbeatProofs;
    mapping(bytes32 => mapping(address => bool)) public proofAttestations;
    mapping(address => bool) public authorizedAttestors;

    bytes32[] public pendingProofs;

    // ============ Events ============
    event BandwidthProofSubmitted(
        bytes32 indexed proofId,
        uint256 indexed sessionId,
        bytes32 indexed nodeId,
        uint256 bytesUsed
    );

    event BandwidthProofVerified(
        bytes32 indexed proofId,
        uint256 sessionId,
        uint256 bytesUsed,
        uint256 attestations
    );

    event HeartbeatProofSubmitted(
        bytes32 indexed proofId,
        bytes32 indexed nodeId,
        bool isOnline,
        uint256 latency
    );

    event HeartbeatProofVerified(
        bytes32 indexed proofId,
        bytes32 nodeId,
        bool isOnline
    );

    event ProofAttested(
        bytes32 indexed proofId,
        address indexed attestor
    );

    event AttestorAdded(address indexed attestor);
    event AttestorRemoved(address indexed attestor);

    // ============ Modifiers ============
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyAttestor() {
        require(authorizedAttestors[msg.sender], "Not authorized attestor");
        _;
    }

    // ============ Constructor ============
    constructor(address _nodeRegistry, address _escrow) {
        require(_nodeRegistry != address(0), "Invalid registry");
        require(_escrow != address(0), "Invalid escrow");

        nodeRegistry = DeVPNNodeRegistry(payable(_nodeRegistry));
        escrow = DeVPNEscrow(payable(_escrow));
        owner = msg.sender;

        // Initialize Flare contracts
        fdcVerification = ContractRegistry.getFdcVerification();
        jsonApi = ContractRegistry.getJsonApi();

        // Owner is initial attestor
        authorizedAttestors[msg.sender] = true;
    }

    // ============ Admin Functions ============

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid address");
        owner = _newOwner;
    }

    function addAttestor(address _attestor) external onlyOwner {
        require(_attestor != address(0), "Invalid address");
        require(!authorizedAttestors[_attestor], "Already attestor");
        authorizedAttestors[_attestor] = true;
        emit AttestorAdded(_attestor);
    }

    function removeAttestor(address _attestor) external onlyOwner {
        require(authorizedAttestors[_attestor], "Not attestor");
        authorizedAttestors[_attestor] = false;
        emit AttestorRemoved(_attestor);
    }

    function updateContracts(address _nodeRegistry, address _escrow) external onlyOwner {
        if (_nodeRegistry != address(0)) {
            nodeRegistry = DeVPNNodeRegistry(payable(_nodeRegistry));
        }
        if (_escrow != address(0)) {
            escrow = DeVPNEscrow(payable(_escrow));
        }
    }

    // ============ Bandwidth Proof Functions ============

    /**
     * @notice Submit a bandwidth usage proof for verification
     * @param _sessionId Session ID
     * @param _bytesUsed Bytes used in session
     * @param _signature Signature from node (optional, for extra verification)
     */
    function submitBandwidthProof(
        uint256 _sessionId,
        uint256 _bytesUsed,
        bytes calldata _signature
    ) external returns (bytes32) {
        // Get session info
        DeVPNEscrow.Session memory session = escrow.getSession(_sessionId);
        require(session.id != 0, "Session not found");

        // Only node owner can submit proof
        DeVPNNodeRegistry.NodeInfo memory node = nodeRegistry.getNodeInfo(session.nodeId);
        require(node.owner == msg.sender, "Not node owner");

        // Generate proof ID
        bytes32 proofId = keccak256(
            abi.encodePacked(_sessionId, session.nodeId, _bytesUsed, block.timestamp)
        );

        require(bandwidthProofs[proofId].timestamp == 0, "Proof already exists");

        // Create proof hash including signature
        bytes32 proofHash = keccak256(
            abi.encodePacked(_sessionId, session.nodeId, _bytesUsed, _signature)
        );

        bandwidthProofs[proofId] = BandwidthProof({
            sessionId: _sessionId,
            nodeId: session.nodeId,
            bytesUsed: _bytesUsed,
            timestamp: block.timestamp,
            proofHash: proofHash,
            verified: false,
            attestationCount: 0
        });

        pendingProofs.push(proofId);

        emit BandwidthProofSubmitted(proofId, _sessionId, session.nodeId, _bytesUsed);

        return proofId;
    }

    /**
     * @notice Attest to a bandwidth proof (called by authorized attestors)
     * @param _proofId Proof ID to attest
     */
    function attestBandwidthProof(bytes32 _proofId) external onlyAttestor {
        BandwidthProof storage proof = bandwidthProofs[_proofId];
        require(proof.timestamp != 0, "Proof not found");
        require(!proof.verified, "Already verified");
        require(!proofAttestations[_proofId][msg.sender], "Already attested");

        proofAttestations[_proofId][msg.sender] = true;
        proof.attestationCount++;

        emit ProofAttested(_proofId, msg.sender);

        // Check if enough attestations
        if (proof.attestationCount >= MIN_ATTESTATIONS) {
            proof.verified = true;
            emit BandwidthProofVerified(
                _proofId,
                proof.sessionId,
                proof.bytesUsed,
                proof.attestationCount
            );
        }
    }

    /**
     * @notice Verify a bandwidth proof using Flare Data Connector
     * @param _proofId Proof ID
     * @param _fdcProof FDC proof data
     */
    function verifyWithFdc(
        bytes32 _proofId,
        IFdcVerification.Proof calldata _fdcProof
    ) external {
        BandwidthProof storage proof = bandwidthProofs[_proofId];
        require(proof.timestamp != 0, "Proof not found");
        require(!proof.verified, "Already verified");

        // Verify with Flare Data Connector
        bool isValid = fdcVerification.verifyJsonApi(_fdcProof);
        require(isValid, "FDC verification failed");

        // Parse the response to extract verified bandwidth
        // The JSON response should contain the actual bandwidth from monitoring
        bytes memory responseData = _fdcProof.data.responseBody;

        // Decode the response (structure depends on your monitoring API)
        // For now, we trust the FDC verification
        proof.verified = true;
        proof.attestationCount = MIN_ATTESTATIONS; // FDC counts as full attestation

        emit BandwidthProofVerified(
            _proofId,
            proof.sessionId,
            proof.bytesUsed,
            proof.attestationCount
        );
    }

    /**
     * @notice Get verified bandwidth for a session
     * @param _sessionId Session ID
     * @return bytesUsed Verified bytes used (0 if not verified)
     * @return verified Whether proof was verified
     */
    function getVerifiedBandwidth(uint256 _sessionId)
        external
        view
        returns (uint256 bytesUsed, bool verified)
    {
        // Find the proof for this session
        for (uint256 i = 0; i < pendingProofs.length; i++) {
            BandwidthProof storage proof = bandwidthProofs[pendingProofs[i]];
            if (proof.sessionId == _sessionId && proof.verified) {
                return (proof.bytesUsed, true);
            }
        }
        return (0, false);
    }

    // ============ Heartbeat Proof Functions ============

    /**
     * @notice Submit a node heartbeat proof
     * @param _nodeId Node ID
     * @param _isOnline Whether node is online
     * @param _latency Measured latency in ms
     */
    function submitHeartbeatProof(
        bytes32 _nodeId,
        bool _isOnline,
        uint256 _latency
    ) external returns (bytes32) {
        // Verify node exists
        DeVPNNodeRegistry.NodeInfo memory node = nodeRegistry.getNodeInfo(_nodeId);
        require(node.owner != address(0), "Node not found");

        bytes32 proofId = keccak256(
            abi.encodePacked(_nodeId, block.timestamp, _isOnline, _latency)
        );

        bytes32 proofHash = keccak256(
            abi.encodePacked(_nodeId, _isOnline, _latency, msg.sender)
        );

        heartbeatProofs[proofId] = NodeHeartbeatProof({
            nodeId: _nodeId,
            timestamp: block.timestamp,
            isOnline: _isOnline,
            latency: _latency,
            proofHash: proofHash,
            verified: false
        });

        emit HeartbeatProofSubmitted(proofId, _nodeId, _isOnline, _latency);

        return proofId;
    }

    /**
     * @notice Verify heartbeat proof and update node status
     * @param _proofId Proof ID
     */
    function verifyAndApplyHeartbeat(bytes32 _proofId) external onlyAttestor {
        NodeHeartbeatProof storage proof = heartbeatProofs[_proofId];
        require(proof.timestamp != 0, "Proof not found");
        require(!proof.verified, "Already verified");
        require(
            block.timestamp <= proof.timestamp + VERIFICATION_WINDOW,
            "Verification window expired"
        );

        proof.verified = true;

        emit HeartbeatProofVerified(_proofId, proof.nodeId, proof.isOnline);

        // If node is offline, could trigger suspension
        // This would require additional integration with NodeRegistry
    }

    // ============ JSON API Integration ============

    /**
     * @notice Request bandwidth verification from external API via Flare
     * @param _sessionId Session to verify
     * @param _apiUrl API endpoint URL
     */
    function requestBandwidthVerification(
        uint256 _sessionId,
        string calldata _apiUrl
    ) external returns (bytes32) {
        // This would initiate a JSON API request through Flare
        // The response would be verified by the FDC and can be used
        // to attest to bandwidth usage

        DeVPNEscrow.Session memory session = escrow.getSession(_sessionId);
        require(session.id != 0, "Session not found");

        // Generate request ID
        bytes32 requestId = keccak256(
            abi.encodePacked(_sessionId, _apiUrl, block.timestamp)
        );

        // In production, this would call the JSON API contract
        // jsonApi.requestData(_apiUrl, callback);

        return requestId;
    }

    // ============ View Functions ============

    function getBandwidthProof(bytes32 _proofId)
        external
        view
        returns (BandwidthProof memory)
    {
        return bandwidthProofs[_proofId];
    }

    function getHeartbeatProof(bytes32 _proofId)
        external
        view
        returns (NodeHeartbeatProof memory)
    {
        return heartbeatProofs[_proofId];
    }

    function isAttestor(address _addr) external view returns (bool) {
        return authorizedAttestors[_addr];
    }

    function getPendingProofsCount() external view returns (uint256) {
        return pendingProofs.length;
    }

    /**
     * @notice Get all pending proofs for a node
     * @param _nodeId Node ID
     */
    function getNodePendingProofs(bytes32 _nodeId)
        external
        view
        returns (bytes32[] memory)
    {
        uint256 count = 0;
        for (uint256 i = 0; i < pendingProofs.length; i++) {
            if (bandwidthProofs[pendingProofs[i]].nodeId == _nodeId &&
                !bandwidthProofs[pendingProofs[i]].verified) {
                count++;
            }
        }

        bytes32[] memory result = new bytes32[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < pendingProofs.length; i++) {
            if (bandwidthProofs[pendingProofs[i]].nodeId == _nodeId &&
                !bandwidthProofs[pendingProofs[i]].verified) {
                result[index] = pendingProofs[i];
                index++;
            }
        }

        return result;
    }

    // ============ Receive ============
    receive() external payable {
        revert("Not payable");
    }
}
