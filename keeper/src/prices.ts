import { type Address } from "viem";
import { envInt, FETCH_TIMEOUT_MS } from "./config";

// USD pricing via DexScreener (keyless). Only used for economic floors on the
// stock cell: bounty/skim there pay in the token's QUOTE currency (a Robinhood
// stock token) while gas is ETH, so both sides are routed through USD to keep
// the worth-it comparison honest. ETH/USD comes from the same endpoint via the
// canonical WETH address. Staleness only skews the off-chain floor, never any
// on-chain amount (the distributor computes those exactly) — so a short cache
// and a stale-fallback are safe.

const PRICE_TTL_MS = envInt("PRICE_TTL_MS", 60_000, 1_000, 3_600_000);
/// How stale a fallback price may be before it is refused outright. Without a
/// bound, a permanently dead DexScreener means the keeper prices stock jobs off
/// a days-old number forever — the wrong default for tokens that can be halted.
const PRICE_MAX_STALE_MS = envInt("PRICE_MAX_STALE_MS", 3_600_000, 60_000, 86_400_000);
/// DexScreener's /tokens/{address} endpoint is cross-chain: the same address on
/// another chain comes back in the same list. Verified 2026-08-13 that the
/// Robinhood WETH address returns 30 pairs and all of them are chainId
/// "robinhood", so this filter changes nothing today — it is here so a future
/// address collision cannot silently reprice the whole stock cell.
const CHAIN_ID = process.env.DEXSCREENER_CHAIN_ID ?? "robinhood";

type DsPair = {
  chainId?: string;
  baseToken?: { address?: string };
  quoteToken?: { address?: string };
  liquidity?: { usd?: number };
  priceUsd?: string;
  priceNative?: string;
};

const cache = new Map<string, { price: number; at: number }>();

const deepest = (pairs: DsPair[]) =>
  pairs.sort((a, b) => (b.liquidity?.usd ?? 0) - (a.liquidity?.usd ?? 0))[0];

/// USD price of `token` from its deepest DexScreener pair. Prefers pairs where
/// `token` is the base (priceUsd is base-denominated); if it only ever appears
/// as the quote (true for WETH on Robinhood — every launchpad pool quotes in
/// it), derive its price from the deepest such pair as priceUsd / priceNative
/// (base's USD price over base's price in `token`). Cached for PRICE_TTL_MS;
/// falls back to the last known price on API failure, else null.
export async function priceUsd(token: Address): Promise<number | null> {
  const key = token.toLowerCase();
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < PRICE_TTL_MS) return hit.price;
  // A price older than PRICE_MAX_STALE_MS is refused rather than reused: the
  // caller then skips the token, which is the conservative direction.
  const fallback = () => {
    if (!hit) return null;
    if (Date.now() - hit.at > PRICE_MAX_STALE_MS) {
      console.warn(`price for ${token} is stale beyond ${PRICE_MAX_STALE_MS}ms — refusing to use it`);
      return null;
    }
    return hit.price;
  };
  try {
    const res = await fetch(`https://api.dexscreener.com/latest/dex/tokens/${token}`, {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) return fallback();
    const json = (await res.json()) as { pairs?: DsPair[] | null };
    const pairs = (json.pairs ?? []).filter((p) => p.chainId === CHAIN_ID);

    let price: number | undefined;
    const base = deepest(pairs.filter((p) => p.baseToken?.address?.toLowerCase() === key && Number(p.priceUsd) > 0));
    if (base) {
      price = Number(base.priceUsd);
    } else {
      const quote = deepest(
        pairs.filter((p) => p.quoteToken?.address?.toLowerCase() === key && Number(p.priceUsd) > 0 && Number(p.priceNative) > 0),
      );
      if (quote) price = Number(quote.priceUsd) / Number(quote.priceNative);
    }
    if (price === undefined || !isFinite(price) || price <= 0) return fallback();
    cache.set(key, { price, at: Date.now() });
    return price;
  } catch {
    return fallback();
  }
}
