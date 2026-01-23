// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/DeVPNnoderegistery.sol";
import "../src/DeVPNescrow.sol";
import "../src/DeVPNstateconnector.sol";

contract DeployDeVPN is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy NodeRegistry first
        DeVPNNodeRegistry nodeRegistry = new DeVPNNodeRegistry();
        console.log("DeVPNNodeRegistry deployed at:", address(nodeRegistry));

        // 2. Deploy Escrow with NodeRegistry address
        DeVPNEscrow escrow = new DeVPNEscrow(address(nodeRegistry));
        console.log("DeVPNEscrow deployed at:", address(escrow));

        // 3. Deploy StateConnector with both addresses
        DeVPNStateConnector stateConnector =
            new DeVPNStateConnector(address(nodeRegistry), address(escrow));
        console.log("DeVPNStateConnector deployed at:", address(stateConnector));

        // 4. Link contracts together
        nodeRegistry.setEscrowContract(address(escrow));
        console.log("NodeRegistry linked to Escrow");

        escrow.setStateConnector(address(stateConnector));
        console.log("Escrow linked to StateConnector");

        vm.stopBroadcast();

        // Print summary
        console.log("\n========== DEPLOYMENT COMPLETE ==========");
        console.log("Network: Coston2 Testnet");
        console.log("NodeRegistry:", address(nodeRegistry));
        console.log("Escrow:", address(escrow));
        console.log("StateConnector:", address(stateConnector));
        console.log("==========================================\n");
    }
}
