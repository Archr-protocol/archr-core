import { type Address, type PublicClient, type WalletClient, type Account, formatEther } from "viem";
import { envBool, envInt, DRY_RUN } from "./config";
import { quoteTokenToQuote, swapTokenForQuote, type PoolKey } from "./dex";

// Token-skim sweep: on token-reward modes (Classic/Deflationary/Balanced) the
// keeper's skims arrive as the token itself (keepers are never fee-exempt — an
// exemption would be a fee-avoidance vector). This module periodically converts
// a configurable share of each accumulated token balance back into the pool's
// quote currency through the v4 Universal Router. Whatever is not swapped stays
// put as inventory — a curated bag of the winners the operator services.
//
// Nothing here moves value out of the keeper wallet. What the keeper earns for
// running the jobs is the keeper's, and the protocol treasury is funded from a
// different source entirely: the lockers hold it as an immutable address and pay
// it their own share of every collect. The two revenue streams never cross, so
// no configuration of this module can route one into the other.
//
// On the native cell the quote is ETH, so the proceeds land as the gas the
// keeper spends. Pool keys come from the caller (the locker's Launch record),
// never rebuilt from constants — see dex.ts.
//
// Per-operator policy (all off-chain, no contract change):
//   SWEEP_ENABLED    — master switch (default off)
//   SWEEP_DRY_RUN    — quote + log only, never execute (DEFAULT true — safety)
//   SWAP_PCT         — % of each token balance to swap → ETH (rest held)
//   MAX_SLIPPAGE_BPS — minOut = quote·(1 − bps/1e4); a bad fill reverts, no loss
//
// The worth-it floor is economic, not a raw-unit dust constant: a balance is
// swept only when the v4 quote says it is worth more than SWEEP_GAS × gas ×
// MARGIN (passed in as `minValueWei`), so it tracks gas and price by itself.
//
// Live-tested on Robinhood mainnet: 100 TENDIES sold through the UR for
// 0.000000130079215058 ETH, exactly the quoted amount, in 161,492 gas.
//
// Pool keys come from the caller, read from the locker — never rebuilt from
// constants. A key assembled from a guessed currency ordering or a stale gate
// address describes a pool that does not exist, the quoter reverts on every
// call, and the sweep then skips every balance as "no quote" without ever
// reporting an error. See dex.ts.

export type SweepConfig = {
  enabled: boolean;
  dryRun: boolean;
  swapPct: number;
  slippageBps: number;
};

export function sweepConfigFromEnv(): SweepConfig {
  return {
    enabled: envBool("SWEEP_ENABLED", false),
    // The global DRY_RUN implies this one: a dry run must be total.
    dryRun: DRY_RUN || envBool("SWEEP_DRY_RUN", true),
    swapPct: envInt("SWAP_PCT", 0, 0, 100),
    // Bounded: an unchecked value above 10_000 made `10_000 - bps` negative and
    // threw inside the uint128 encode, surfacing only as a per-token skip.
    slippageBps: envInt("MAX_SLIPPAGE_BPS", 100, 0, 9_999),
  };
}

const balAbi = [
  { type: "function", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
] as const;

type Deps = {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Account;
  cfg: SweepConfig;
  /// Worth-it floor in wei: SWEEP_GAS × gasPrice × MARGIN, from the caller.
  minValueWei: bigint;
};

export type Sweepable = { token: Address; poolKey: PoolKey };

export async function sweep(tokens: Sweepable[], deps: Deps): Promise<void> {
  const { publicClient, walletClient, account, cfg, minValueWei } = deps;
  if (!cfg.enabled) return;

  for (const { token, poolKey } of tokens) {
    try {
      // Recomputed per token, not once before the loop: this loop awaits swap
      // receipts, so a single timestamp taken up front goes stale and both the
      // Universal Router deadline (nowSec + 600) and the Permit2 expiry are
      // measured from it. On a multi-token sweep that is a revert waiting to
      // happen.
      const nowSec = Math.floor(Date.now() / 1000);
      const bal = (await publicClient.readContract({
        address: token, abi: balAbi, functionName: "balanceOf", args: [account.address],
      })) as bigint;
      if (bal === 0n) continue;

      // Price the whole balance first: below the floor neither leg is worth its
      // gas, and skipping here also saves the per-leg round-trips.
      const balValue = await quoteTokenToQuote(publicClient, account, poolKey, bal);
      if (balValue === null) {
        console.error(`sweep skip ${token}: no quote`);
        continue;
      }
      if (balValue < minValueWei) continue;

      // The rest of the balance is simply left where it is.
      const swapAmt = (bal * BigInt(Math.round(cfg.swapPct))) / 100n;

      if (swapAmt > 0n) {
        const quote = await quoteTokenToQuote(publicClient, account, poolKey, swapAmt);
        if (quote === null || quote === 0n) {
          console.error(`sweep skip ${token}: no quote`);
          continue;
        }
        const minOut = (quote * BigInt(10_000 - cfg.slippageBps)) / 10_000n;
        if (cfg.dryRun) {
          console.log(`[dry-run] sweep ${token} · ${formatEther(swapAmt)} → ~${formatEther(quote)} ETH (min ${formatEther(minOut)})`);
        } else {
          const hash = await swapTokenForQuote(publicClient, walletClient, account, poolKey, swapAmt, minOut, nowSec);
          console.log(`swept ${token} · ${formatEther(swapAmt)} → ≥${formatEther(minOut)} ETH · ${hash}`);
        }
      }
    } catch (e) {
      console.error(`sweep skip ${token}: ${(e as Error).message.split("\n")[0]}`);
    }
  }
}
