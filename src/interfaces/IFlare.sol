// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title FtsoV2Interface
 * @notice Interface for Flare FTSO V2 price feeds
 */
interface FtsoV2Interface {
    function getFeedById(bytes21 _feedId) external view returns (uint256 value, int8 decimals, uint64 timestamp);
    function getFeedByIdInWei(bytes21 _feedId) external view returns (uint256 value, uint64 timestamp);
}

/**
 * @title IFdcVerification
 * @notice Interface for Flare Data Connector verification
 */
interface IFdcVerification {
    struct Proof {
        bytes32 merkleRoot;
        bytes32[] merkleProof;
        ProofData data;
    }

    struct ProofData {
        bytes32 attestationType;
        bytes32 sourceId;
        uint64 votingRound;
        uint64 lowestUsedTimestamp;
        bytes requestBody;
        bytes responseBody;
    }

    function verifyJsonApi(Proof calldata _proof) external view returns (bool);
}

/**
 * @title IJsonApi
 * @notice Interface for Flare JSON API requests
 */
interface IJsonApi {
    function requestData(string calldata url, bytes4 callback) external returns (bytes32);
}

/**
 * @title IFlareContractRegistry
 * @notice Interface for Flare's on-chain contract registry
 */
interface IFlareContractRegistry {
    function getContractAddressByName(string calldata _name) external view returns (address);
}

/**
 * @title ContractRegistry
 * @notice Library to fetch Flare contract addresses from on-chain registry
 */
library ContractRegistry {
    // Flare Contract Registry address for Coston2 testnet
    address constant FLARE_CONTRACT_REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;

    function getFtsoV2() internal view returns (FtsoV2Interface) {
        IFlareContractRegistry registry = IFlareContractRegistry(FLARE_CONTRACT_REGISTRY);
        address ftsoV2Address = registry.getContractAddressByName("FtsoV2");
        return FtsoV2Interface(ftsoV2Address);
    }

    function getFdcVerification() internal view returns (IFdcVerification) {
        IFlareContractRegistry registry = IFlareContractRegistry(FLARE_CONTRACT_REGISTRY);
        address fdcAddress = registry.getContractAddressByName("FdcVerification");
        return IFdcVerification(fdcAddress);
    }

    function getJsonApi() internal view returns (IJsonApi) {
        IFlareContractRegistry registry = IFlareContractRegistry(FLARE_CONTRACT_REGISTRY);
        address jsonApiAddress = registry.getContractAddressByName("JsonApi");
        return IJsonApi(jsonApiAddress);
    }
}
