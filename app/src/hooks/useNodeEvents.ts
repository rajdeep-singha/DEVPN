import { useEffect, useRef, useCallback } from "react";
import { ethers } from "ethers";
import { Session, SessionStatus } from "../utils/contract";
import { addSession, removeSession, updateBandwidthStats, getSessionBytes, isTauri } from "../utils/tauri";

// Session timeout: 24 hours in seconds
const SESSION_TIMEOUT = 24 * 60 * 60;

interface UseNodeEventsProps {
  nodeId: string | null; // bytes32 as hex string
  escrowContract: ethers.Contract | null;
  onSessionStart?: (session: Session) => void;
  onSessionEnd?: (sessionId: bigint, bytesUsed: bigint) => void;
  onSessionSettled?: (sessionId: bigint, nodePayout: bigint, userRefund: bigint) => void;
  onError?: (error: Error) => void;
}

export function useNodeEvents({
  nodeId,
  escrowContract,
  onSessionStart,
  onSessionEnd,
  onSessionSettled,
  onError,
}: UseNodeEventsProps) {
  const pollingRef = useRef<NodeJS.Timeout | null>(null);
  const lastBlockRef = useRef<number>(0);
  const activeSessionsRef = useRef<Map<string, Session>>(new Map());
  const settlingRef = useRef<Set<string>>(new Set()); // Prevent double-settling

  // Settle a session on the blockchain
  const settleSession = useCallback(
    async (session: Session, bytesUsed: bigint) => {
      if (!escrowContract) return;

      const sessionKey = session.id.toString();

      // Prevent double-settling
      if (settlingRef.current.has(sessionKey)) {
        console.log("Session already being settled:", sessionKey);
        return;
      }

      settlingRef.current.add(sessionKey);

      try {
        console.log(`Settling session ${sessionKey} with ${bytesUsed} bytes`);

        // Call submitUsageAndSettle on the escrow contract
        const tx = await escrowContract.submitUsageAndSettle(session.id, bytesUsed);
        console.log("Settlement tx sent:", tx.hash);

        const receipt = await tx.wait();
        console.log("Settlement confirmed:", receipt.hash);

        // Parse settlement event to get payout details
        const settledEvent = receipt.logs.find((log: ethers.Log) => {
          try {
            const parsed = escrowContract.interface.parseLog(log);
            return parsed?.name === "SessionSettled";
          } catch {
            return false;
          }
        });

        if (settledEvent) {
          const parsed = escrowContract.interface.parseLog(settledEvent);
          if (parsed) {
            const nodePayout = parsed.args.nodePayout;
            const userRefund = parsed.args.userRefund;
            console.log(`Settlement complete: Node paid ${nodePayout}, User refunded ${userRefund}`);
            onSessionSettled?.(session.id, nodePayout, userRefund);
          }
        }
      } catch (err) {
        console.error("Failed to settle session:", err);
        onError?.(err instanceof Error ? err : new Error("Failed to settle session"));
      } finally {
        settlingRef.current.delete(sessionKey);
      }
    },
    [escrowContract, onSessionSettled, onError]
  );

  // Handle new session - add WireGuard peer
  const handleSessionStarted = useCallback(
    async (session: Session) => {
      console.log("New session started:", session.id.toString());

      try {
        if (isTauri()) {
          // Add peer to WireGuard via Tauri backend
          const assignedIp = await addSession(
            Number(session.id),
            session.user,
            session.userPublicKey,
            session.deposit.toString()
          );
          console.log("Assigned IP to peer:", assignedIp);
        }

        // Track active session
        activeSessionsRef.current.set(session.userPublicKey, session);

        onSessionStart?.(session);
      } catch (err) {
        console.error("Failed to handle session start:", err);
        onError?.(err instanceof Error ? err : new Error("Failed to add peer"));
      }
    },
    [onSessionStart, onError]
  );

  // Handle session end - remove WireGuard peer
  const handleSessionEnded = useCallback(
    async (session: Session) => {
      console.log("Session ended:", session.id.toString());

      try {
        let bytesUsed = 0n;

        if (isTauri()) {
          // Get final bytes count from WireGuard
          try {
            const bytes = await getSessionBytes(session.userPublicKey);
            bytesUsed = BigInt(bytes);
          } catch {
            // If we can't get bytes, use what's in the session
            bytesUsed = session.bytesUsed;
          }

          // Remove peer from WireGuard via Tauri backend
          await removeSession(session.userPublicKey);
          console.log("Removed peer, bytes used:", bytesUsed.toString());
        }

        // Remove from tracking
        activeSessionsRef.current.delete(session.userPublicKey);

        onSessionEnd?.(session.id, bytesUsed);

        // With the new simplified escrow, clients use endSessionAndSettle()
        // which does both actions atomically, so sessions go directly to Settled.
        // Node operators can still force settle after 1 hour if needed.
      } catch (err) {
        console.error("Failed to handle session end:", err);
        onError?.(err instanceof Error ? err : new Error("Failed to remove peer"));
      }
    },
    [onSessionEnd, onError]
  );

  // Check for timed-out sessions and force settle them
  const checkTimeouts = useCallback(async () => {
    if (!escrowContract || !nodeId) return;

    const now = Math.floor(Date.now() / 1000);

    for (const [pubKey, session] of activeSessionsRef.current) {
      const sessionAge = now - Number(session.startTime);

      if (sessionAge > SESSION_TIMEOUT) {
        console.log(`Session ${session.id} timed out (${sessionAge}s old), force settling...`);

        try {
          // Get bytes used before removing
          let bytesUsed = 0n;
          if (isTauri()) {
            try {
              const bytes = await getSessionBytes(pubKey);
              bytesUsed = BigInt(bytes);
            } catch {
              bytesUsed = session.bytesUsed;
            }
          }

          // Force settle via contract
          const tx = await escrowContract.forceSettleExpired(session.id);
          await tx.wait();
          console.log("Force settled session:", session.id.toString());

          // Remove peer and clean up
          if (isTauri()) {
            await removeSession(pubKey);
          }
          activeSessionsRef.current.delete(pubKey);

          onSessionEnd?.(session.id, bytesUsed);
        } catch (err) {
          console.error("Failed to force settle session:", err);
        }
      }
    }
  }, [escrowContract, nodeId, onSessionEnd]);

  // Poll for new sessions and check for ended ones
  const pollForSessions = useCallback(async () => {
    if (!escrowContract || !nodeId) return;

    try {
      // Get current block
      const provider = escrowContract.runner?.provider;
      if (!provider) return;

      const currentBlock = await provider.getBlockNumber();

      // On first run, just set the block number
      if (lastBlockRef.current === 0) {
        lastBlockRef.current = currentBlock;
        return;
      }

      // Get sessions for our node (nodeId is bytes32)
      const sessions: Session[] = await escrowContract.getNodeSessionDetails(nodeId);

      // Check for new active sessions
      for (const session of sessions) {
        if (Number(session.status) === SessionStatus.Active) {
          // Check if we already know about this session
          if (!activeSessionsRef.current.has(session.userPublicKey)) {
            await handleSessionStarted(session);
          }
        }
      }

      // Check for settled sessions that need cleanup
      for (const [pubKey] of activeSessionsRef.current) {
        const currentSession = sessions.find((s) => s.userPublicKey === pubKey);

        if (currentSession) {
          // Session settled - clean up local state
          if (Number(currentSession.status) === SessionStatus.Settled) {
            if (isTauri()) {
              await removeSession(pubKey);
            }
            activeSessionsRef.current.delete(pubKey);
          }
        }
      }

      lastBlockRef.current = currentBlock;
    } catch (err) {
      console.error("Error polling for sessions:", err);
    }
  }, [escrowContract, nodeId, handleSessionStarted, handleSessionEnded]);

  // Update bandwidth stats periodically
  const updateStats = useCallback(async () => {
    if (!isTauri()) return;

    try {
      const stats = await updateBandwidthStats();
      if (stats.length > 0) {
        console.log("Bandwidth stats updated:", stats);
      }
    } catch (err) {
      console.error("Failed to update bandwidth stats:", err);
    }
  }, []);

  // Start polling when node is active
  useEffect(() => {
    if (!nodeId || !escrowContract) return;

    console.log("Starting event polling for node:", nodeId);

    // Poll every 5 seconds for sessions
    pollingRef.current = setInterval(() => {
      pollForSessions();
      updateStats();
    }, 5000);

    // Check for timeouts every minute
    const timeoutInterval = setInterval(checkTimeouts, 60000);

    // Initial poll
    pollForSessions();

    return () => {
      if (pollingRef.current) {
        clearInterval(pollingRef.current);
        pollingRef.current = null;
      }
      clearInterval(timeoutInterval);
    };
  }, [nodeId, escrowContract, pollForSessions, updateStats, checkTimeouts]);

  return {
    activeSessions: activeSessionsRef.current,
    settleSession,
  };
}
