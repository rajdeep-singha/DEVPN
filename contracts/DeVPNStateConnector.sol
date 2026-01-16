// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

//  DeVPN State Connector Integration
interface IStateConnector {
   
    function requestAttestation(bytes calldata data) external;
    
   
    function getAttestation(bytes32 merkleRoot) external view returns (bool);
}

interface IDeVPNNodeRegistry {
    function submitHeartbeat(bytes32 _nodeId, uint256 _uptimeScore) external;
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
}

contract DeVPNStateConnector {
    
    // State Variables 
    
    IStateConnector public stateConnector;
    IDeVPNNodeRegistry public nodeRegistry;
    
    uint256 public constant HEARTBEAT_INTERVAL = 5 minutes;
    uint256 public constant UPTIME_CHECK_WINDOW = 1 hours;
    uint256 public constant MIN_SUCCESSFUL_PINGS = 10; // Out of 12 checks (5min intervals)
    
    struct HeartbeatAttestation {
        bytes32 nodeId;
        uint256 timestamp;
        bool isOnline;
        uint256 latency; // in milliseconds
        bytes32 attestationHash;
        bool verified;
    }
    
    struct UptimeRecord {
        uint256 totalChecks;
        uint256 successfulChecks;
        uint256 lastCheckTime;
        uint256 currentScore; // 0-100
    }
    
   
    mapping(bytes32 => UptimeRecord) public uptimeRecords;
    
    
    mapping(bytes32 => HeartbeatAttestation) public attestations;
    
    // Node ID => array of recent attestation hashes
    mapping(bytes32 => bytes32[]) public nodeAttestations;
    
    
    mapping(address => bool) public authorizedProviders;
    
    uint256 public totalAttestations;
    
    // Events 
    
    event AttestationRequested(
        bytes32 indexed nodeId,
        bytes32 indexed attestationHash,
        uint256 timestamp
    );
    
    event AttestationVerified(
        bytes32 indexed nodeId,
        bytes32 indexed attestationHash,
        bool isOnline,
        uint256 latency
    );
    
    event UptimeUpdated(
        bytes32 indexed nodeId,
        uint256 uptimeScore,
        uint256 successfulChecks,
        uint256 totalChecks
    );
    
    event ProviderAuthorized(
        address indexed provider,
        bool authorized
    );
    
    //  Modifiers
    
    modifier onlyAuthorized() {
        require(
            authorizedProviders[msg.sender],
            "Not authorized provider"
        );
        _;
    }
    
    // Constructor 
    
    constructor(
        address _stateConnector,
        address _nodeRegistry
    ) {
        require(_stateConnector != address(0), "Invalid state connector");
        require(_nodeRegistry != address(0), "Invalid registry");
        
        stateConnector = IStateConnector(_stateConnector);
        nodeRegistry = IDeVPNNodeRegistry(_nodeRegistry);
        
        // have to initialize with actual FTSO providers in production
        authorizedProviders[msg.sender] = true;
    }
    
    // Core Functions
    
    function requestUptimeCheck(
        bytes32 _nodeId,
        string memory _endpoint
    ) external returns (bytes32) {
        // node verification
        (address owner,,,,,,,,,,,,) = nodeRegistry.getNodeInfo(_nodeId);
        require(owner != address(0), "Node does not exist");
        
        // Generate attestation request
        bytes32 attestationHash = keccak256(
            abi.encodePacked(
                _nodeId,
                _endpoint,
                block.timestamp,
                totalAttestations
            )
        );
        
        // Create attestation record
        attestations[attestationHash] = HeartbeatAttestation({
            nodeId: _nodeId,
            timestamp: block.timestamp,
            isOnline: false,
            latency: 0,
            attestationHash: attestationHash,
            verified: false
        });
        
        // Store reference
        nodeAttestations[_nodeId].push(attestationHash);
        totalAttestations++;
        
        // Request attestation from State Connector
        bytes memory attestationData = abi.encode(
            _nodeId,
            _endpoint,
            block.timestamp
        );
        
        stateConnector.requestAttestation(attestationData);
        
        emit AttestationRequested(_nodeId, attestationHash, block.timestamp);
        
        return attestationHash;
    }
    
   
    function submitUptimeResult(
        bytes32 _attestationHash,
        bool _isOnline,
        uint256 _latency
    ) external onlyAuthorized {
        HeartbeatAttestation storage attestation = attestations[_attestationHash];
        
        require(
            attestation.timestamp > 0,
            "Attestation does not exist"
        );
        require(
            !attestation.verified,
            "Already verified"
        );
        
        // Update attestation
        attestation.isOnline = _isOnline;
        attestation.latency = _latency;
        attestation.verified = true;
        
        // Update uptime record
        _updateUptimeRecord(attestation.nodeId, _isOnline);
        
        emit AttestationVerified(
            attestation.nodeId,
            _attestationHash,
            _isOnline,
            _latency
        );
    }
    
  // Submit batch uptime results for efficiency
    function submitBatchUptimeResults(
        bytes32[] calldata _attestationHashes,
        bool[] calldata _isOnlineArray,
        uint256[] calldata _latencyArray
    ) external onlyAuthorized {
        require(
            _attestationHashes.length == _isOnlineArray.length &&
            _isOnlineArray.length == _latencyArray.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < _attestationHashes.length; i++) {
            HeartbeatAttestation storage attestation = attestations[_attestationHashes[i]];
            
            if (attestation.timestamp > 0 && !attestation.verified) {
                attestation.isOnline = _isOnlineArray[i];
                attestation.latency = _latencyArray[i];
                attestation.verified = true;
                
                _updateUptimeRecord(attestation.nodeId, _isOnlineArray[i]);
                
                emit AttestationVerified(
                    attestation.nodeId,
                    _attestationHashes[i],
                    _isOnlineArray[i],
                    _latencyArray[i]
                );
            }
        }
    }
  //Calculating  and submit uptime score to registry
    function updateNodeUptime(bytes32 _nodeId) external {
        UptimeRecord storage record = uptimeRecords[_nodeId];
        
        require(record.totalChecks > 0, "No checks recorded");
        require(
            block.timestamp >= record.lastCheckTime + HEARTBEAT_INTERVAL,
            "Too soon to update"
        );
        
        
        uint256 uptimeScore = (record.successfulChecks * 100) / record.totalChecks;
        record.currentScore = uptimeScore;
        
        
        nodeRegistry.submitHeartbeat(_nodeId, uptimeScore);
        
        emit UptimeUpdated(
            _nodeId,
            uptimeScore,
            record.successfulChecks,
            record.totalChecks
        );
        
        if (block.timestamp >= record.lastCheckTime + UPTIME_CHECK_WINDOW) {
            record.totalChecks = 0;
            record.successfulChecks = 0;
        }
        
        record.lastCheckTime = block.timestamp;
    }
    
    // Authorize attestation providers

    function authorizeProvider(address _provider, bool _authorized) external {
        // In production, restrict to governance
        authorizedProviders[_provider] = _authorized;
        emit ProviderAuthorized(_provider, _authorized);
    }
    
    // View Functions 
    

    function getAttestation(bytes32 _attestationHash) 
        external 
        view 
        returns (HeartbeatAttestation memory) 
    {
        return attestations[_attestationHash];
    }
    
    
    // Get node uptime record

    function getUptimeRecord(bytes32 _nodeId) 
        external 
        view 
        returns (UptimeRecord memory) 
    {
        return uptimeRecords[_nodeId];
    }
    
    // Get recent attestations for a node

    function getNodeAttestations(bytes32 _nodeId) 
        external 
        view 
        returns (bytes32[] memory) 
    {
        return nodeAttestations[_nodeId];
    }
    
    
    // Calculating current uptime score
    function calculateUptimeScore(bytes32 _nodeId) 
        external 
        view 
        returns (uint256) 
    {
        UptimeRecord storage record = uptimeRecords[_nodeId];
        
        if (record.totalChecks == 0) {
            return 0;
        }
        
        return (record.successfulChecks * 100) / record.totalChecks;
    }
    
    // Checking if node meets minimum uptime requirements
    function meetsUptimeRequirement(bytes32 _nodeId) 
        external 
        view 
        returns (bool) 
    {
        UptimeRecord storage record = uptimeRecords[_nodeId];
        
        if (record.totalChecks < MIN_SUCCESSFUL_PINGS) {
            return false;
        }
        
        return record.successfulChecks >= MIN_SUCCESSFUL_PINGS;
    }
    
    // Internal Functions 
    
   // Update uptime record with new check result
    function _updateUptimeRecord(bytes32 _nodeId, bool _isOnline) internal {
        UptimeRecord storage record = uptimeRecords[_nodeId];
        
        record.totalChecks++;
        if (_isOnline) {
            record.successfulChecks++;
        }
        
   
        if (record.totalChecks > 100) {
           
            record.totalChecks = 100;
            if (_isOnline) {
                record.successfulChecks = 
                    (record.successfulChecks * 100) / 101; // Proportional adjustment
            } else {
                record.successfulChecks = 
                    (record.successfulChecks * 100) / 101;
            }
        }
    }
}
