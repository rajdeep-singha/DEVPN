// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/DeVPNEscrowSimple.sol";
import "../src/DeVPNnoderegistery.sol";

contract DeployEscrowSimple is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address nodeRegistryAddress = vm.envOr("NODE_REGISTRY_ADDRESS", address(0));

        vm.startBroadcast(deployerPrivateKey);

        DeVPNNodeRegistry nodeRegistry;

        // If NODE_REGISTRY_ADDRESS not provided, deploy new NodeRegistry
        if (nodeRegistryAddress == address(0)) {
            console.log("Deploying new NodeRegistry...");
            nodeRegistry = new DeVPNNodeRegistry();
            console.log("NodeRegistry deployed at:", address(nodeRegistry));
        } else {
            console.log("Using existing NodeRegistry at:", nodeRegistryAddress);
            nodeRegistry = DeVPNNodeRegistry(payable(nodeRegistryAddress));
        }

        // Deploy new simplified escrow
        console.log("Deploying DeVPNEscrowSimple...");
        DeVPNEscrowSimple escrow = new DeVPNEscrowSimple(address(nodeRegistry));
        console.log("DeVPNEscrowSimple deployed at:", address(escrow));

        // Link escrow with node registry
        console.log("Linking escrow with NodeRegistry...");
        nodeRegistry.setEscrowContract(address(escrow));
        console.log("Escrow linked successfully!");

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("NodeRegistry:", address(nodeRegistry));
        console.log("EscrowSimple:", address(escrow));
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("==========================\n");
    }
}
