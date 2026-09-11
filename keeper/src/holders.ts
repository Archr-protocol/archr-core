import { parseAbiItem, type Address, type PublicClient } from "viem";
import { envInt } from "./config";

/// Who holds a token, derived from the chain rather than from an index.
///
/// Only the address SET is needed, never the balances: the distributor keeps
/// `sharesOf` on chain, and the push reads each holder's owed amount from it
/// before deciding whether to pay them. Maintaining a balance table off-chain
/// would mean replaying every ERC-20 Transfer of every launched token forever,
/// scaling with trading activity across the whole protocol, to answer a question
/// the chain can be asked directly.
///
/// So this asks the chain for the address set directly. It is cheap where it
/// lands: one token's lifetime Transfer logs, fetched only for tokens that have
/// already cleared the fee thresholds, once per tick at most. A token with
/// ~50,000 transfers is a handful of ranged queries; a token nobody trades is
/// never scanned at all.
///
/// Addresses that have since sold out stay in the set. That is harmless — they
/// read `withdrawable == 0` and the push filter drops them — and it is the
/// reason this can be an append-only set rather than a running balance.

const transferEvent = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");

/// Block span per getLogs. Endpoints cap BOTH the range and the matched-log
/// count, and the log cap is the one that bites on a busy token, so this starts
/// modest and halves on refusal rather than trying to be clever up front.
const CHUNK = envInt("HOLDER_SCAN_CHUNK", 10_000, 100, 1_000_000);

/// Never scan the whole chain: a token cannot have holders before it existed.
/// Callers pass the launch block; this is only the floor if they cannot.
const DEFAULT_FROM = envInt("HOLDER_SCAN_FROM", 0, 0, 2_000_000_000);

type Entry = { holders: Address[]; tick: number };
const cache = new Map<string, Entry>();

/// Addresses that hold but must never be paid: the pool, the protocol's own
/// contracts, and the burn address. Mirrors the indexer's exclusion set — the
/// distributor enforces this too, so this is an optimisation, not the guard.
function excluded(extra: Address[]): Set<string> {
  return new Set(
    [
      "0x0000000000000000000000000000000000000000",
      "0x000000000000000000000000000000000000dead",
      ...extra,
    ]
      .filter(Boolean)
      .map((a) => a.toLowerCase()),
  );
}

async function scan(
  client: PublicClient,
  token: Address,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<Set<string>> {
  const seen = new Set<string>();
  let chunk = BigInt(CHUNK);

  for (let start = fromBlock; start <= toBlock; ) {
    const end = start + chunk - 1n > toBlock ? toBlock : start + chunk - 1n;
    try {
      const logs = await client.getLogs({ address: token, event: transferEvent, fromBlock: start, toBlock: end });
      for (const l of logs) {
        const { from, to } = l.args as { from?: Address; to?: Address };
        if (from) seen.add(from.toLowerCase());
        if (to) seen.add(to.toLowerCase());
      }
      start = end + 1n;
    } catch (e) {
      // "logs matched by query exceeds limit" / "block range too large" / a
      // rate-limited window all say the same thing: ask for less.
      if (chunk <= 100n) throw e;
      chunk /= 2n;
    }
  }
  return seen;
}

/// The token's holder set, cached for the caller's tick.
///
/// `fromBlock` should be the launch block — the indexer knows it and passing it
/// turns a chain-wide scan into a short one. Returns lowercase addresses.
export async function holdersOf(
  client: PublicClient,
  token: Address,
  opts: { fromBlock?: bigint; exclude?: Address[]; tick: number },
): Promise<Address[]> {
  const key = token.toLowerCase();
  const hit = cache.get(key);
  if (hit && hit.tick === opts.tick) return hit.holders;

  const head = await client.getBlockNumber();
  const from = opts.fromBlock ?? BigInt(DEFAULT_FROM);
  const skip = excluded(opts.exclude ?? []);
  const seen = await scan(client, token, from, head);

  const holders = [...seen].filter((a) => !skip.has(a)) as Address[];
  cache.set(key, { holders, tick: opts.tick });
  return holders;
}

/// Test seam: forget everything cached.
export function resetHolderCache(): void {
  cache.clear();
}
