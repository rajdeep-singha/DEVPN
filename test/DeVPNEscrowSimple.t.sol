// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/DeVPNEscrowSimple.sol";
import "../src/DeVPNnoderegistery.sol";

contract DeVPNEscrowSimpleTest is Test {
    DeVPNNodeRegistry public registry;
    DeVPNEscrowSimple public escrow;

    address public owner = address(1);
    address public nodeOperator = address(2);
    address public user = address(3);
    address public user2 = address(4);

    bytes32 public nodeId;

    // Events for testing
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

    function setUp() public {
        // Deploy contracts
        vm.startPrank(owner);
        registry = new DeVPNNodeRegistry();
        escrow = new DeVPNEscrowSimple(address(registry));

        // Link contracts
        registry.setEscrowContract(address(escrow));
        vm.stopPrank();

        // Register a node
        vm.startPrank(nodeOperator);
        vm.deal(nodeOperator, 1000 ether);

        nodeId = registry.registerNode{ value: 100 ether }(
            "192.168.1.1:51820",
            "dGVzdHB1YmtleWZvcm5vZGUxMjM0NTY3ODkwMTIzNA==", // 44 chars
            50, // 50 cents per GB
            "US",
            1000 // 1 Gbps
        );

        registry.activateNode(nodeId);
        vm.stopPrank();

        // Give users some FLR
        vm.deal(user, 100 ether);
        vm.deal(user2, 100 ether);
    }

    // ============ Start Session Tests ============

    function testStartSession() public {
        vm.startPrank(user);

        uint256 deposit = 5 ether;
        string memory userPubKey = "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"; // 44 chars

        vm.expectEmit(true, true, true, true);
        emit SessionStarted(1, nodeId, user, deposit, userPubKey);

        uint256 sessionId = escrow.startSession{ value: deposit }(nodeId, userPubKey);

        assertEq(sessionId, 1);

        // Check session details
        DeVPNEscrowSimple.Session memory session = escrow.getSession(sessionId);
        assertEq(session.id, 1);
        assertEq(session.nodeId, nodeId);
        assertEq(session.user, user);
        assertEq(session.deposit, deposit);
        assertEq(uint256(session.status), uint256(DeVPNEscrowSimple.SessionStatus.Active));

        // Check active session tracking
        (bool hasActive, uint256 activeId) = escrow.hasActiveSession(user);
        assertTrue(hasActive);
        assertEq(activeId, sessionId);

        vm.stopPrank();
    }

    function testStartSessionRevertsInsufficientDeposit() public {
        vm.startPrank(user);

        vm.expectRevert("Insufficient deposit");
        escrow.startSession{ value: 0.05 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        vm.stopPrank();
    }

    function testStartSessionRevertsInvalidWgKey() public {
        vm.startPrank(user);

        vm.expectRevert("Invalid WireGuard key");
        escrow.startSession{ value: 1 ether }(nodeId, "short");

        vm.stopPrank();
    }

    function testStartSessionRevertsAlreadyActive() public {
        vm.startPrank(user);

        // Start first session
        escrow.startSession{ value: 1 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        // Try to start second session
        vm.expectRevert("Already have active session");
        escrow.startSession{ value: 1 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM1"
        );

        vm.stopPrank();
    }

    function testStartSessionRevertsInactiveNode() public {
        // Deactivate node
        vm.prank(nodeOperator);
        registry.deactivateNode(nodeId);

        vm.startPrank(user);

        vm.expectRevert("Node not active");
        escrow.startSession{ value: 1 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        vm.stopPrank();
    }

    // ============ End Session And Settle Tests ============

    function testEndSessionAndSettle() public {
        // Start session
        vm.startPrank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        // User ends and settles
        uint256 bytesUsed = 2 * 1024 * 1024 * 1024; // 2 GB
        uint256 userBalanceBefore = user.balance;

        escrow.endSessionAndSettle(sessionId, bytesUsed);

        // Check session is settled
        DeVPNEscrowSimple.Session memory session = escrow.getSession(sessionId);
        assertEq(uint256(session.status), uint256(DeVPNEscrowSimple.SessionStatus.Settled));
        assertEq(session.bytesUsed, bytesUsed);
        assertEq(session.settler, user);
        assertTrue(session.settlementTime > 0);

        // Check active session cleared
        (bool hasActive,) = escrow.hasActiveSession(user);
        assertFalse(hasActive);

        // Check user got refund
        uint256 userBalanceAfter = user.balance;
        assertTrue(userBalanceAfter > userBalanceBefore);

        vm.stopPrank();
    }

    function testEndSessionAndSettleRevertsNotActive() public {
        vm.startPrank(user);

        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        // End once
        escrow.endSessionAndSettle(sessionId, 2 * 1024 * 1024 * 1024);

        // Try to end again
        vm.expectRevert("Session not active");
        escrow.endSessionAndSettle(sessionId, 1 * 1024 * 1024 * 1024);

        vm.stopPrank();
    }

    function testEndSessionAndSettleRevertsNotUser() public {
        // User starts session
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        // Someone else tries to end it
        vm.startPrank(user2);

        vm.expectRevert("Not session user");
        escrow.endSessionAndSettle(sessionId, 2 * 1024 * 1024 * 1024);

        vm.stopPrank();
    }

    function testEndSessionAndSettleRevertsMinimumBytes() public {
        vm.startPrank(user);

        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        // Try to settle with less than 1 MB
        vm.expectRevert("Below minimum charge");
        escrow.endSessionAndSettle(sessionId, 1024); // 1 KB

        vm.stopPrank();
    }

    function testEndSessionAndSettlePaymentDistribution() public {
        vm.startPrank(user);

        uint256 deposit = 10 ether;
        uint256 sessionId = escrow.startSession{ value: deposit }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        uint256 userBalanceBefore = user.balance;
        uint256 nodeEarningsBefore = registry.getNodeInfo(nodeId).totalEarnings;
        uint256 protocolFeesBefore = escrow.totalProtocolFees();

        // Settle with 1 GB
        uint256 bytesUsed = 1 * 1024 * 1024 * 1024;
        escrow.endSessionAndSettle(sessionId, bytesUsed);

        // Check payments
        DeVPNEscrowSimple.Session memory session = escrow.getSession(sessionId);
        uint256 cost = session.costInFlr;
        uint256 protocolFee = (cost * 500) / 10_000; // 5%
        uint256 nodePayout = cost - protocolFee;
        uint256 expectedRefund = deposit - cost;

        // User refund
        assertEq(user.balance, userBalanceBefore + expectedRefund);

        // Node earnings
        assertEq(registry.getNodeInfo(nodeId).totalEarnings, nodeEarningsBefore + nodePayout);

        // Protocol fees
        assertEq(escrow.totalProtocolFees(), protocolFeesBefore + protocolFee);

        vm.stopPrank();
    }

    // ============ Force Settle Tests ============

    function testForceSettleSession() public {
        // User starts session
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        // Fast forward 1 hour
        vm.warp(block.timestamp + 1 hours);

        // Node force-settles
        vm.startPrank(nodeOperator);

        uint256 actualBytes = 3 * 1024 * 1024 * 1024; // 3 GB
        escrow.forceSettleSession(sessionId, actualBytes);

        // Check session settled
        DeVPNEscrowSimple.Session memory session = escrow.getSession(sessionId);
        assertEq(uint256(session.status), uint256(DeVPNEscrowSimple.SessionStatus.Settled));
        assertEq(session.bytesUsed, actualBytes);
        assertEq(session.settler, nodeOperator);

        vm.stopPrank();
    }

    function testForceSettleRevertsBeforeDelay() public {
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        // Try to force settle immediately
        vm.startPrank(nodeOperator);

        vm.expectRevert("Too early to force settle");
        escrow.forceSettleSession(sessionId, 1 * 1024 * 1024 * 1024);

        vm.stopPrank();
    }

    function testForceSettleRevertsNotNodeOwner() public {
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        vm.warp(block.timestamp + 1 hours);

        // Someone else tries to force settle
        vm.startPrank(user2);

        vm.expectRevert("Not node owner");
        escrow.forceSettleSession(sessionId, 1 * 1024 * 1024 * 1024);

        vm.stopPrank();
    }

    // ============ Expire Session Tests ============

    function testExpireSession() public {
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        uint256 userBalanceBefore = user.balance;

        // Fast forward 24 hours
        vm.warp(block.timestamp + 24 hours);

        // Anyone can expire
        vm.prank(user2);
        escrow.expireSession(sessionId);

        // Check session expired
        DeVPNEscrowSimple.Session memory session = escrow.getSession(sessionId);
        assertEq(uint256(session.status), uint256(DeVPNEscrowSimple.SessionStatus.Expired));

        // Check user got full refund
        assertEq(user.balance, userBalanceBefore + 5 ether);
    }

    function testExpireSessionRevertsNotExpired() public {
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        vm.expectRevert("Not expired yet");
        escrow.expireSession(sessionId);
    }

    // ============ Dispute Tests ============

    function testDisputeSession() public {
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        // User disputes
        vm.prank(user);
        escrow.disputeSession(sessionId, "Bandwidth overcharged");

        // Check disputed
        DeVPNEscrowSimple.Session memory session = escrow.getSession(sessionId);
        assertEq(uint256(session.status), uint256(DeVPNEscrowSimple.SessionStatus.Disputed));
        assertTrue(session.disputed);
    }

    function testResolveDisputeInFavorOfUser() public {
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        vm.prank(user);
        escrow.disputeSession(sessionId, "Node overcharged");

        uint256 userBalanceBefore = user.balance;

        // Owner resolves in favor of user
        vm.prank(owner);
        escrow.resolveDispute(sessionId, true, 0);

        // Check user got full refund
        assertEq(user.balance, userBalanceBefore + 5 ether);

        // Check session settled
        DeVPNEscrowSimple.Session memory session = escrow.getSession(sessionId);
        assertEq(uint256(session.status), uint256(DeVPNEscrowSimple.SessionStatus.Settled));
    }

    function testResolveDisputeInFavorOfNode() public {
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        vm.prank(user);
        escrow.disputeSession(sessionId, "Testing");

        // Owner resolves in favor of node with correct bytes
        vm.prank(owner);
        escrow.resolveDispute(sessionId, false, 2 * 1024 * 1024 * 1024); // 2 GB

        // Check session settled
        DeVPNEscrowSimple.Session memory session = escrow.getSession(sessionId);
        assertEq(uint256(session.status), uint256(DeVPNEscrowSimple.SessionStatus.Settled));
        assertEq(session.bytesUsed, 2 * 1024 * 1024 * 1024);
    }

    // ============ View Function Tests ============

    function testCanForceSettle() public {
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        // Check initially can't force settle
        (bool canForce, uint256 remaining) = escrow.canForceSettle(sessionId);
        assertFalse(canForce);
        assertEq(remaining, 1 hours);

        // Fast forward
        vm.warp(block.timestamp + 1 hours);

        // Check can now force settle
        (canForce, remaining) = escrow.canForceSettle(sessionId);
        assertTrue(canForce);
        assertEq(remaining, 0);
    }

    function testCanExpire() public {
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 5 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        // Check initially can't expire
        (bool canExp, uint256 remaining) = escrow.canExpire(sessionId);
        assertFalse(canExp);
        assertEq(remaining, 24 hours);

        // Fast forward
        vm.warp(block.timestamp + 24 hours);

        // Check can now expire
        (canExp, remaining) = escrow.canExpire(sessionId);
        assertTrue(canExp);
        assertEq(remaining, 0);
    }

    function testEstimateSessionCost() public view {
        (uint256 cost, uint256 fee, uint256 payout) =
            escrow.estimateSessionCost(
                nodeId,
                1 * 1024 * 1024 * 1024 // 1 GB
            );

        assertTrue(cost > 0);
        assertEq(fee, (cost * 500) / 10_000); // 5%
        assertEq(payout, cost - fee);
    }

    // ============ Admin Function Tests ============

    function testWithdrawProtocolFees() public {
        // Create and settle a session to generate fees
        vm.prank(user);
        uint256 sessionId = escrow.startSession{ value: 10 ether }(
            nodeId, "dXNlcnB1YmtleWZvcmNsaWVudDEyMzQ1Njc4OTAxMjM0"
        );

        vm.prank(user);
        escrow.endSessionAndSettle(sessionId, 1 * 1024 * 1024 * 1024);

        uint256 fees = escrow.totalProtocolFees();
        assertTrue(fees > 0);

        uint256 ownerBalanceBefore = owner.balance;

        // Withdraw fees
        vm.prank(owner);
        escrow.withdrawProtocolFees();

        // Check owner received fees
        assertEq(owner.balance, ownerBalanceBefore + fees);

        // Check fees cleared
        assertEq(escrow.totalProtocolFees(), 0);
    }

    function testWithdrawProtocolFeesRevertsNotOwner() public {
        vm.prank(user);

        vm.expectRevert("Not owner");
        escrow.withdrawProtocolFees();
    }
}
