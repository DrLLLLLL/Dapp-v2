// 文件路径: src/lib/useBlockchain.ts

import { useState, useEffect, useCallback } from 'react';
import { blockchainService, WalletInfo, ProductInfo, TransactionResult } from './blockchainService';
import { parseBlockchainError, saveLastConnectedAddress, clearLastConnectedAddress } from './blockchainUtils';

// ============================================================================
// Hook: useWallet - 钱包连接管理
// ============================================================================

export function useWallet() {
  const [wallet, setWallet] = useState<WalletInfo | null>(null);
  const [isConnecting, setIsConnecting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const connect = useCallback(async () => {
    setIsConnecting(true);
    setError(null);
    
    try {
      const walletInfo = await blockchainService.connectWallet();
      setWallet(walletInfo);
      saveLastConnectedAddress(walletInfo.address);
      return walletInfo;
    } catch (err: any) {
      const errorMsg = parseBlockchainError(err);
      setError(errorMsg);
      throw err;
    } finally {
      setIsConnecting(false);
    }
  }, []);

  const disconnect = useCallback(() => {
    // Service 没有 disconnect 方法，直接清空本地状态
    setWallet(null);
    clearLastConnectedAddress();
    // 如果需要在 Service 层也清空，可以在 Service 加一个 reset 方法，但通常不需要
  }, []);

  const isConnected = wallet !== null;

  return {
    wallet,
    isConnected,
    isConnecting,
    error,
    connect,
    disconnect,
  };
}

// ============================================================================
// Hook: useProduct - 产品信息管理
// ============================================================================

export function useProduct(tokenId: number | string | null) {
  const [productInfo, setProductInfo] = useState<ProductInfo | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadProduct = useCallback(async () => {
    if (!tokenId) return;

    setIsLoading(true);
    setError(null);

    try {
      const info = await blockchainService.getProductInfo(tokenId);
      setProductInfo(info);
      return info;
    } catch (err: any) {
      const errorMsg = parseBlockchainError(err);
      setError(errorMsg);
      throw err;
    } finally {
      setIsLoading(false);
    }
  }, [tokenId]);

  useEffect(() => {
    if (tokenId && blockchainService.isConnected()) {
      loadProduct();
    }
  }, [tokenId, loadProduct]);

  return {
    productInfo,
    isLoading,
    error,
    reload: loadProduct,
  };
}

// ============================================================================
// Hook: useProductHistory - 产品历史记录
// ============================================================================

export function useProductHistory(tokenId: number | string | null) {
  const [history, setHistory] = useState<any[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadHistory = useCallback(async () => {
    if (!tokenId) return;

    setIsLoading(true);
    setError(null);

    try {
      const events = await blockchainService.getProductHistory(tokenId);
      setHistory(events);
      return events;
    } catch (err: any) {
      const errorMsg = parseBlockchainError(err);
      setError(errorMsg);
      throw err;
    } finally {
      setIsLoading(false);
    }
  }, [tokenId]);

  useEffect(() => {
    if (tokenId && blockchainService.isConnected()) {
      loadHistory();
    }
  }, [tokenId, loadHistory]);

  return {
    history,
    isLoading,
    error,
    reload: loadHistory,
  };
}

// ============================================================================
// Hook: useWarranty - 保修状态管理
// ============================================================================

export function useWarranty(tokenId: number | string | null) {
  const [isValid, setIsValid] = useState(false);
  const [expiration, setExpiration] = useState<Date | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const checkWarranty = useCallback(async () => {
    if (!tokenId) return;

    setIsLoading(true);
    setError(null);

    try {
      // 改为从 getProductInfo 获取，因为 Service 移除了独立方法
      const info = await blockchainService.getProductInfo(tokenId);
      const expDate = new Date(Number(info.warrantyExpiration) * 1000);
      const isValidNow = expDate > new Date();
      
      setIsValid(isValidNow);
      setExpiration(expDate);
      
      return { isValid: isValidNow, expiration: expDate };
    } catch (err: any) {
      const errorMsg = parseBlockchainError(err);
      setError(errorMsg);
      throw err;
    } finally {
      setIsLoading(false);
    }
  }, [tokenId]);

  useEffect(() => {
    if (tokenId && blockchainService.isConnected()) {
      checkWarranty();
    }
  }, [tokenId, checkWarranty]);

  return {
    isValid,
    expiration,
    isLoading,
    error,
    reload: checkWarranty,
  };
}

// ============================================================================
// Hook: useTransaction - 交易状态管理
// ============================================================================

export function useTransaction() {
  const [isProcessing, setIsProcessing] = useState(false);
  const [result, setResult] = useState<TransactionResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  const execute = useCallback(async (
    operation: () => Promise<TransactionResult>,
    onSuccess?: (result: TransactionResult) => void,
    onError?: (error: string) => void
  ) => {
    setIsProcessing(true);
    setError(null);
    setResult(null);

    try {
      const txResult = await operation();
      setResult(txResult);

      if (txResult.success) {
        onSuccess?.(txResult);
      } else {
        const errorMsg = txResult.error || '交易失败';
        setError(errorMsg);
        onError?.(errorMsg);
      }

      return txResult;
    } catch (err: any) {
      const errorMsg = parseBlockchainError(err);
      setError(errorMsg);
      onError?.(errorMsg);
      throw err;
    } finally {
      setIsProcessing(false);
    }
  }, []);

  const reset = useCallback(() => {
    setIsProcessing(false);
    setResult(null);
    setError(null);
  }, []);

  return {
    isProcessing,
    result,
    error,
    execute,
    reset,
  };
}

// ============================================================================
// Hook: useWarrantyClaim - 保修申请操作
// ============================================================================

export function useWarrantyClaim() {
  const { execute, isProcessing, error } = useTransaction();

  const submitClaim = useCallback(
    async (
      tokenId: number | string,
      issueDescription: string,
      onSuccess?: () => void
    ) => {
      return execute(
        () => blockchainService.submitWarrantyClaim(tokenId, issueDescription),
        () => onSuccess?.(),
        (err) => console.error('提交保修申请失败:', err)
      );
    },
    [execute]
  );

  return {
    submitClaim,
    isSubmitting: isProcessing,
    error,
  };
}

// ============================================================================
// Hook: useProductTransfer - 产品转移操作
// ============================================================================

export function useProductTransfer() {
  const { execute, isProcessing, error } = useTransaction();

  const transferProduct = useCallback(
    async (
      fromAddress: string,
      toAddress: string,
      tokenId: number | string,
      onSuccess?: () => void
    ) => {
      return execute(
        () => blockchainService.transferProduct(fromAddress, toAddress, tokenId),
        () => onSuccess?.(),
        (err) => console.error('转移产品失败:', err)
      );
    },
    [execute]
  );

  return {
    transferProduct,
    isTransferring: isProcessing,
    error,
  };
}