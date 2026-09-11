import { type Address } from "viem";
import { FETCH_TIMEOUT_MS } from "./config";

// Thin indexer client shared by the WETH cell (index.ts) and the stock cell
// (stock.ts). The indexer is best-effort everywhere it's used — the distributors
// compute exact amounts on-chain, so a stale holder/token list is harmless.

/// Returns null on ANY failure. Callers must treat null as "I do not know",
/// never as "the answer is empty" — see `getTokens` in index.ts for why that
/// distinction is the difference between a loud outage and a silent one.
export async function gql<T>(query: string): Promise<T | null> {
  const url = process.env.INDEXER_URL;
  if (!url) return null;
  try {
    // Without a timeout a black-holed indexer stalls the tick until undici's
    // 300s default fires. Ticks are serial, so that is minutes of no service.
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) {
      console.warn(`indexer HTTP ${res.status}`);
      return null;
    }
    const json = (await res.json()) as { data?: T; errors?: unknown[] };
    if (json.errors?.length) {
      console.warn(`indexer GraphQL error: ${JSON.stringify(json.errors[0]).slice(0, 200)}`);
      return null;
    }
    return json.data ?? null;
  } catch (e) {
    console.warn(`indexer request failed: ${(e as Error).message.split("\n")[0]}`);
    return null;
  }
}
