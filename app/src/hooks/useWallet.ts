import { useState, useEffect, useCallback, useRef } from "react";
import { BrowserProvider, Contract, formatEther, JsonRpcProvider } from "ethers";
import EthereumProvider from "@walletconnect/ethereum-provider";
import {
  NODE_REGISTRY_ABI,
  NODE_REGISTRY_ADDRESS,
  ESCROW_ABI,
  ESCROW_ADDRESS,
  NETWORK_CONFIG,
} from "../utils/contract";

// Direct RPC provider for Coston2 (bypasses wallet)
const coston2Provider = new JsonRpcProvider(NETWORK_CONFIG.rpcUrls[0]);

// Read-only contracts for fetching data (doesn't need signer)
const readOnlyRegistry = new Contract(NODE_REGISTRY_ADDRESS, NODE_REGISTRY_ABI, coston2Provider);
const readOnlyEscrow = new Contract(ESCROW_ADDRESS, ESCROW_ABI, coston2Provider);

declare global {
  interface Window {
    ethereum?: {
      request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
      on: (event: string, callback: (...args: unknown[]) => void) => void;
      removeListener: (event: string, callback: (...args: unknown[]) => void) => void;
      isMetaMask?: boolean;
    };
  }
}

export interface WalletState {
  isConnected: boolean;
  address: string | null;
  balance: string;
  chainId: number | null;
  isCorrectNetwork: boolean;
  connectionType: "metamask" | "walletconnect" | null;
}

// WalletConnect Project ID - Get your own at https://cloud.walletconnect.com
const WALLETCONNECT_PROJECT_ID = "3a8170812b534d0ff9d794f19a901d64";

export function useWallet() {
  const [wallet, setWallet] = useState<WalletState>({
    isConnected: false,
    address: null,
    balance: "0",
    chainId: null,
    isCorrectNetwork: false,
    connectionType: null,
  });
  const [provider, setProvider] = useState<BrowserProvider | null>(null);
  const [registryContract, setRegistryContract] = useState<Contract | null>(null);
  const [escrowContract, setEscrowContract] = useState<Contract | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showWalletOptions, setShowWalletOptions] = useState(false);

  const wcProviderRef = useRef<EthereumProvider | null>(null);
  const balanceIntervalRef = useRef<NodeJS.Timeout | null>(null);

  const updateBalance = useCallback(async (address: string, _browserProvider?: BrowserProvider) => {
    try {
      const balance = await coston2Provider.getBalance(address);
      console.log("Balance from Coston2 RPC:", formatEther(balance));
      setWallet((prev) => ({
        ...prev,
        balance: formatEther(balance),
      }));
    } catch (err) {
      console.error("Error fetching balance:", err);
    }
  }, []);

  const startBalanceRefresh = useCallback((address: string, browserProvider: BrowserProvider) => {
    if (balanceIntervalRef.current) {
      clearInterval(balanceIntervalRef.current);
    }
    balanceIntervalRef.current = setInterval(() => {
      updateBalance(address, browserProvider);
    }, 10000);
  }, [updateBalance]);

  const stopBalanceRefresh = useCallback(() => {
    if (balanceIntervalRef.current) {
      clearInterval(balanceIntervalRef.current);
      balanceIntervalRef.current = null;
    }
  }, []);

  // Connect with MetaMask
  const connectMetaMask = useCallback(async () => {
    if (!window.ethereum) {
      setError("MetaMask not found. Try WalletConnect instead.");
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      const accounts = (await window.ethereum.request({
        method: "eth_requestAccounts",
      })) as string[];

      if (accounts.length === 0) {
        throw new Error("No accounts found");
      }

      const address = accounts[0];
      const chainIdHex = (await window.ethereum.request({
        method: "eth_chainId",
      })) as string;
      const chainId = parseInt(chainIdHex, 16);

      const browserProvider = new BrowserProvider(window.ethereum);
      setProvider(browserProvider);

      const signer = await browserProvider.getSigner();

      // Create both contracts with signer
      const registry = new Contract(NODE_REGISTRY_ADDRESS, NODE_REGISTRY_ABI, signer);
      const escrow = new Contract(ESCROW_ADDRESS, ESCROW_ABI, signer);
      setRegistryContract(registry);
      setEscrowContract(escrow);

      const balance = await coston2Provider.getBalance(address);
      console.log("Initial balance from Coston2:", formatEther(balance));

      setWallet({
        isConnected: true,
        address,
        balance: formatEther(balance),
        chainId,
        isCorrectNetwork: chainId === NETWORK_CONFIG.chainId,
        connectionType: "metamask",
      });

      startBalanceRefresh(address, browserProvider);
      localStorage.setItem("devpn_wallet_type", "metamask");
      setShowWalletOptions(false);
    } catch (err) {
      console.error("Error connecting MetaMask:", err);
      setError(err instanceof Error ? err.message : "Failed to connect MetaMask");
    } finally {
      setIsLoading(false);
    }
  }, [startBalanceRefresh]);

  // Connect with WalletConnect
  const connectWalletConnect = useCallback(async () => {
    setIsLoading(true);
    setError(null);

    try {
      const wcProvider = await EthereumProvider.init({
        projectId: WALLETCONNECT_PROJECT_ID,
        chains: [NETWORK_CONFIG.chainId],
        optionalChains: [1, 14, 114],
        showQrModal: true,
        metadata: {
          name: "DeVPN",
          description: "Decentralized VPN on Flare Network",
          url: "https://devpn.app",
          icons: ["https://devpn.app/icon.png"],
        },
        rpcMap: {
          [NETWORK_CONFIG.chainId]: NETWORK_CONFIG.rpcUrls[0],
          14: "https://flare-api.flare.network/ext/C/rpc",
          114: "https://coston2-api.flare.network/ext/C/rpc",
        },
      });

      wcProviderRef.current = wcProvider;

      const accounts = await wcProvider.enable();

      if (!accounts || accounts.length === 0) {
        throw new Error("No accounts found. Please approve the connection in your wallet.");
      }

      const address = accounts[0];

      let chainId = wcProvider.chainId;
      console.log("WalletConnect chainId from provider:", chainId);

      if (!chainId || chainId === 0) {
        try {
          const chainIdHex = await wcProvider.request({ method: "eth_chainId" }) as string;
          chainId = parseInt(chainIdHex, 16);
          console.log("WalletConnect chainId from request:", chainId);
        } catch (e) {
          console.error("Failed to get chainId:", e);
        }
      }

      const browserProvider = new BrowserProvider(wcProvider);
      setProvider(browserProvider);

      try {
        const network = await browserProvider.getNetwork();
        console.log("Network from browserProvider:", network.chainId);
        if (network.chainId) {
          chainId = Number(network.chainId);
        }
      } catch (e) {
        console.error("Failed to get network:", e);
      }

      const signer = await browserProvider.getSigner();

      // Create both contracts with signer
      const registry = new Contract(NODE_REGISTRY_ADDRESS, NODE_REGISTRY_ABI, signer);
      const escrow = new Contract(ESCROW_ADDRESS, ESCROW_ABI, signer);
      setRegistryContract(registry);
      setEscrowContract(escrow);

      const balance = await coston2Provider.getBalance(address);

      console.log("Final chainId:", chainId, "Expected:", NETWORK_CONFIG.chainId);
      console.log("isCorrectNetwork:", chainId === NETWORK_CONFIG.chainId);
      console.log("Balance from Coston2:", formatEther(balance));

      const isCorrect = chainId === NETWORK_CONFIG.chainId || chainId === 114;

      setWallet({
        isConnected: true,
        address,
        balance: formatEther(balance),
        chainId: isCorrect ? 114 : chainId,
        isCorrectNetwork: isCorrect,
        connectionType: "walletconnect",
      });

      startBalanceRefresh(address, browserProvider);
      localStorage.setItem("devpn_wallet_type", "walletconnect");

      wcProvider.on("accountsChanged", (accounts: string[]) => {
        if (accounts.length === 0) {
          disconnect();
        } else {
          setWallet((prev) => ({ ...prev, address: accounts[0] }));
        }
      });

      wcProvider.on("chainChanged", (chainIdRaw: string | number) => {
        const chainId = typeof chainIdRaw === 'string'
          ? parseInt(chainIdRaw, chainIdRaw.startsWith('0x') ? 16 : 10)
          : chainIdRaw;
        setWallet((prev) => ({
          ...prev,
          chainId,
          isCorrectNetwork: chainId === NETWORK_CONFIG.chainId,
        }));
      });

      wcProvider.on("disconnect", () => {
        disconnect();
      });

      setShowWalletOptions(false);
    } catch (err) {
      console.error("Error connecting WalletConnect:", err);
      setError(err instanceof Error ? err.message : "Failed to connect WalletConnect");
    } finally {
      setIsLoading(false);
    }
  }, []);

  const disconnect = useCallback(async () => {
    stopBalanceRefresh();

    if (wcProviderRef.current) {
      try {
        await wcProviderRef.current.disconnect();
      } catch (err) {
        console.error("Error disconnecting WalletConnect:", err);
      }
      wcProviderRef.current = null;
    }

    localStorage.removeItem("devpn_wallet_type");

    setWallet({
      isConnected: false,
      address: null,
      balance: "0",
      chainId: null,
      isCorrectNetwork: false,
      connectionType: null,
    });
    setProvider(null);
    setRegistryContract(null);
    setEscrowContract(null);
  }, [stopBalanceRefresh]);

  const switchNetwork = useCallback(async () => {
    const ethereumProvider = wallet.connectionType === "walletconnect"
      ? wcProviderRef.current
      : window.ethereum;

    if (!ethereumProvider) {
      setError("No wallet connected");
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      await ethereumProvider.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: `0x${NETWORK_CONFIG.chainId.toString(16)}` }],
      });

      setWallet((prev) => ({
        ...prev,
        chainId: NETWORK_CONFIG.chainId,
        isCorrectNetwork: true,
      }));

      if (wallet.connectionType === "metamask") {
        await connectMetaMask();
      }
    } catch (switchError: unknown) {
      const errorCode = (switchError as { code?: number }).code;

      if (errorCode === 4902) {
        try {
          await ethereumProvider.request({
            method: "wallet_addEthereumChain",
            params: [
              {
                chainId: `0x${NETWORK_CONFIG.chainId.toString(16)}`,
                chainName: NETWORK_CONFIG.chainName,
                rpcUrls: NETWORK_CONFIG.rpcUrls,
                nativeCurrency: NETWORK_CONFIG.nativeCurrency,
                blockExplorerUrls: NETWORK_CONFIG.blockExplorerUrls,
              },
            ],
          });

          setWallet((prev) => ({
            ...prev,
            chainId: NETWORK_CONFIG.chainId,
            isCorrectNetwork: true,
          }));

          if (wallet.connectionType === "metamask") {
            await connectMetaMask();
          }
        } catch (addError) {
          console.error("Error adding network:", addError);
          setError("Failed to add Coston2 network. Please add it manually in your wallet.");
        }
      } else if (errorCode === 4001) {
        setError("Network switch was rejected. Please switch to Coston2 manually.");
      } else {
        console.error("Error switching network:", switchError);
        setError("Failed to switch network. Please switch to Coston2 manually in your wallet.");
      }
    } finally {
      setIsLoading(false);
    }
  }, [wallet.connectionType, connectMetaMask]);

  // Listen for MetaMask account and chain changes
  useEffect(() => {
    if (!window.ethereum || wallet.connectionType !== "metamask") return;

    const handleAccountsChanged = async (accounts: unknown) => {
      const accountsArray = accounts as string[];
      if (accountsArray.length === 0) {
        disconnect();
      } else if (wallet.isConnected && provider) {
        const newAddress = accountsArray[0];
        await updateBalance(newAddress, provider);
        setWallet((prev) => ({
          ...prev,
          address: newAddress,
        }));
      }
    };

    const handleChainChanged = async (chainIdHex: unknown) => {
      const chainId = parseInt(chainIdHex as string, 16);
      console.log("Chain changed to:", chainId);

      if (wallet.isConnected) {
        console.log("Reconnecting after chain change...");
        await connectMetaMask();
      } else {
        setWallet((prev) => ({
          ...prev,
          chainId,
          isCorrectNetwork: chainId === NETWORK_CONFIG.chainId,
        }));
      }
    };

    window.ethereum.on("accountsChanged", handleAccountsChanged);
    window.ethereum.on("chainChanged", handleChainChanged);

    return () => {
      window.ethereum?.removeListener("accountsChanged", handleAccountsChanged);
      window.ethereum?.removeListener("chainChanged", handleChainChanged);
    };
  }, [wallet.isConnected, wallet.connectionType, provider, disconnect, updateBalance]);

  // Auto-reconnect on mount
  useEffect(() => {
    const autoReconnect = async () => {
      const savedType = localStorage.getItem("devpn_wallet_type");

      if (savedType === "metamask" && window.ethereum) {
        try {
          const accounts = (await window.ethereum.request({
            method: "eth_accounts",
          })) as string[];

          if (accounts.length > 0) {
            await connectMetaMask();
          }
        } catch (err) {
          console.error("Auto-reconnect failed:", err);
        }
      }
      setIsLoading(false);
    };

    autoReconnect();

    return () => {
      stopBalanceRefresh();
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const connect = useCallback(() => {
    setShowWalletOptions(true);
  }, []);

  return {
    wallet,
    provider,
    registryContract,
    escrowContract,
    // Backwards compatibility
    contract: registryContract,
    readOnlyRegistry,
    readOnlyEscrow,
    isLoading,
    error,
    connect,
    connectMetaMask,
    connectWalletConnect,
    disconnect,
    switchNetwork,
    showWalletOptions,
    setShowWalletOptions,
    clearError: () => setError(null),
  };
}

// Export read-only contracts for direct use
export { readOnlyRegistry, readOnlyEscrow };
