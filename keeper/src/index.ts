import dotenv from "dotenv";
dotenv.config({ path: ".env.local" });
dotenv.config(); // fall back to .env for anything not set in .env.local
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  formatEther,
  http,
  parseEther,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { writeFileSync } from "node:fs";
import { assertConfigValid, DRY_RUN, envBigInt, envBool, envInt, HEARTBEAT_FILE } from "./config";
import { quoteTokenToQuote, type PoolKey } from "./dex";
import { gql } from "./indexer";
import { holdersOf } from "./holders";
import { stockConfigFromEnv, stockTick } from "./stock";
import { sweep, sweepConfigFromEnv } from "./sweep";

// archr keeper — three independent self-funding jobs, run per token:
//   1. collect: `crank` pulls fees out of the LP position into the distributor,
//               earning BOUNTY_BPS of everything that arrives — WETH and token.
//   2. process: `process` deploys what's pending (WETH rewards, buybacks,
//               reflections, burns), earning PROCESS_SKIM_BPS of what moves.
//   3. push:    `claimForMany` delivers accrued rewards straight to holders'
//               wallets, earning PUSH_SKIM_BPS. Holders never claim or connect a
//               wallet — rewards just arrive. Self-claiming stays free.
//
// The jobs are decoupled on purpose: each has its own accumulator, so each fires
// on its own schedule under one rule — value moved × rate ≥ gas × MARGIN. Work is
// never stranded, because the longer a pot sits the more profitable draining it
// becomes. Idle tokens cost nothing; busy tokens fund their own upkeep.
//
// Every gate is authoritative rather than modelled: `crank` and `process` return
// what they paid, so the keeper simulates the real call and floors on the real
// payout. The arithmetic floors below are only a cheap pre-filter, there to avoid
// simulating every token every tick against a rate-limited public RPC.
//
// Tokens come from the indexer. HOLDERS come from the chain (holders.ts) — the
// distributor computes exact reward amounts on-chain anyway, so an address list
// is all that was ever needed and the indexer no longer maintains one.

const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com"] } },
  // Multicall3 is deployed at the canonical address (verified on chain: 3,808
  // bytes). Declaring it is what lets `client.multicall` pack the per-holder
  // reward reads into one call instead of two round-trips per holder — the
  // difference between ~300 holders per tick and six figures.
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

const account = privateKeyToAccount(process.env.KEEPER_PRIVATE_KEY as `0x${string}`);

// The public RPC rate-limits in bursts ("Rate Limit Hit, limit will reset in 60
// seconds"). viem already classes 429 as retryable and honours Retry-After, but
// its default budget (3 retries from a 150ms base ≈ 1s) expires long before a
// 60s window closes, so the error escaped into the tick. viem backs off as
// (1 << count) * retryDelay from count=0, so 6 × 1s gives 1+2+4+8+16+32 = 63s —
// enough to ride out a full window inside the call even if the provider sends
// no Retry-After. Applies to every call on these clients, stock.ts's included.
const rpcOpts = { retryCount: 6, retryDelay: 1_000 } as const;
const publicClient = createPublicClient({ chain: robinhood, transport: http(undefined, rpcOpts) });
const walletClient = createWalletClient({ account, chain: robinhood, transport: http(undefined, rpcOpts) });

const DISTRIBUTOR = process.env.DISTRIBUTOR_ADDRESS as Address;
const LOCKER = process.env.LOCKER_ADDRESS as Address;
const INTERVAL = envInt("INTERVAL_MS", 60_000, 1_000, 3_600_000);
const PUSH_ENABLED = envBool("PUSH_ENABLED", true);
const PROCESS_ENABLED = envBool("PROCESS_ENABLED", true);
const PUSH_BATCH = envInt("PUSH_BATCH", 100, 1, 500);

// The incentive rates are READ FROM THE DEPLOYED DISTRIBUTOR at startup, not
// taken on trust from the environment. They are `uint16 public constant`, so one
// call each removes any drift between the deployed value and the environment.
// The env values below are the fallback if the read fails, and a mismatch
// between the two is logged loudly rather than silently preferred.
let BOUNTY_BPS = envBigInt("BOUNTY_BPS", 100n, 1n, 10_000n); // crank bounty
let SKIM_BPS = envBigInt("SKIM_BPS", 100n, 1n, 10_000n); // push skim
let PROCESS_SKIM_BPS = envBigInt("PROCESS_SKIM_BPS", 100n, 1n, 10_000n); // process skim
// The security parameter: the pending pot equilibrates at gas × MARGIN / skim,
// so this bounds what a same-transaction actor can extract from it.
const MARGIN = envBigInt("MARGIN", 3n, 1n, 1_000n);
// Measured 406k once the locker compounds the liquidity share, roughly double
// the collect without compounding. Re-measure if the locker changes — this sets
// the fee level at which collecting pays.
/// Native-cell collect. Left at 420,000: the only collect measured on chain so
/// far was a STOCK one (344,015), and the two paths differ. The stock figure now
/// lives under STOCK_COLLECT_GAS so tuning one cell no longer moves the other.
const COLLECT_GAS = envBigInt("COLLECT_GAS", 420_000n, 21_000n, 30_000_000n);
// The buyback path is the expensive one (~250k); EthPrinter-style direct payouts
// cost a third of that, so this floor is deliberately the conservative case.
const PROCESS_GAS = envBigInt("PROCESS_GAS", 250_000n, 21_000n, 30_000_000n);
const PUSH_GAS = envBigInt("PUSH_GAS", 60_000n, 1_000n, 30_000_000n); // marginal, per holder
const SWEEP_GAS = envBigInt("SWEEP_GAS", 180_000n, 21_000n, 30_000_000n); // measured: 161,492 on-chain 2026-08-11

// Minimum buyback allowance, in sqrt bps, worth spending a `process` call on.
// The distributor no longer has a fixed cooldown: allowance accrues every block
// at `sqrtMoveBpsPerBlock` and is capped at `maxSqrtMoveBps`, so there is no
// boundary to wait for — only a point below which the fill is too small to be
// worth the gas. Zero allowance means the budget could only re-queue.
//
// NOTE on cadence: the cap bounds ACCRUAL, so allowance stops growing once the
// bucket is full. A keeper polling less often than `maxSqrtMoveBps /
// sqrtMoveBpsPerBlock` blocks forfeits the difference and throttles buybacks
// below the rate the contract allows. Poll at or under the refill time.
const MIN_BUYBACK_ALLOWANCE_BPS = envBigInt("MIN_BUYBACK_ALLOWANCE_BPS", 1n, 0n, 10_000n);

/// Gas price is read every tick, so it's the call most exposed to a rate-limit
/// window. Floors move slowly, so falling back to the last known price degrades
/// to a slightly stale floor — far better than failing the whole tick over it.
let lastGasPrice: bigint | null = null;

async function gasPrice(): Promise<bigint> {
  try {
    lastGasPrice = await publicClient.getGasPrice();
    return lastGasPrice;
  } catch (e) {
    if (lastGasPrice === null) throw e; // nothing cached yet — no basis to guess
    console.warn(`gasPrice unavailable, reusing last known: ${(e as Error).message.split("\n")[0]}`);
    return lastGasPrice;
  }
}

/// Sends a transaction, or logs what it would have sent under DRY_RUN. Every
/// write in this file goes through here so the dry run is total: there is no
/// path that simulates correctly and then sends anyway.
async function send(request: unknown, label: string): Promise<"success" | "reverted" | "dry-run"> {
  if (DRY_RUN) {
    console.log(`[dry-run] would send ${label}`);
    return "dry-run";
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const hash = await walletClient.writeContract(request as any);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`${label} · ${receipt.status} · ${hash}`);
  return receipt.status;
}

/// Read the incentive rates off the deployed distributor. They are immutable
/// constants, so one read at startup is enough — and it means the floors can
/// never be wrong because an env var drifted from the contract.
const bpsAbi = [
  { type: "function", name: "BOUNTY_BPS", inputs: [], outputs: [{ type: "uint16" }], stateMutability: "view" },
  { type: "function", name: "PUSH_SKIM_BPS", inputs: [], outputs: [{ type: "uint16" }], stateMutability: "view" },
  { type: "function", name: "PROCESS_SKIM_BPS", inputs: [], outputs: [{ type: "uint16" }], stateMutability: "view" },
] as const;

async function syncRatesFromChain(): Promise<void> {
  const read = (name: "BOUNTY_BPS" | "PUSH_SKIM_BPS" | "PROCESS_SKIM_BPS") =>
    publicClient.readContract({ address: DISTRIBUTOR, abi: bpsAbi, functionName: name }) as Promise<number>;
  const [bounty, push, proc] = await Promise.all([read("BOUNTY_BPS"), read("PUSH_SKIM_BPS"), read("PROCESS_SKIM_BPS")]);
  const drift: string[] = [];
  if (BigInt(bounty) !== BOUNTY_BPS) drift.push(`BOUNTY_BPS env=${BOUNTY_BPS} chain=${bounty}`);
  if (BigInt(push) !== SKIM_BPS) drift.push(`SKIM_BPS env=${SKIM_BPS} chain=${push}`);
  if (BigInt(proc) !== PROCESS_SKIM_BPS) drift.push(`PROCESS_SKIM_BPS env=${PROCESS_SKIM_BPS} chain=${proc}`);
  if (drift.length > 0) {
    console.error(`WARN incentive-rate drift, using the CHAIN values: ${drift.join(" · ")}`);
  }
  BOUNTY_BPS = BigInt(bounty);
  SKIM_BPS = BigInt(push);
  PROCESS_SKIM_BPS = BigInt(proc);
}

/// What each job must earn, in wei, to be worth firing: MARGIN × its gas cost.
/// This is the real floor — `crank` and `process` report what they paid, so the
/// comparison is against realised income, not a model of it.
type Costs = { collect: bigint; process: bigint; push: bigint; sweep: bigint; gas: bigint };

async function costs(): Promise<Costs> {
  const gas = await gasPrice();
  return {
    collect: COLLECT_GAS * gas * MARGIN,
    process: PROCESS_GAS * gas * MARGIN,
    push: PUSH_GAS * gas * MARGIN,
    sweep: SWEEP_GAS * gas * MARGIN,
    gas,
  };
}

const distributorAbi = [
  {
    type: "function",
    name: "crank",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      { name: "wethBounty", type: "uint256" },
      { name: "tokenBounty", type: "uint256" },
    ],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "process",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      { name: "wethSkim", type: "uint256" },
      { name: "tokenSkim", type: "uint256" },
    ],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "claimForMany",
    inputs: [{ name: "token", type: "address" }, { name: "holders", type: "address[]" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  { type: "function", name: "withdrawableWeth", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "withdrawableToken", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "pendingWethOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "pendingTokenOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "lastBuybackBlockOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "buybackAllowanceBpsOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "canAccrue", inputs: [{ type: "address" }], outputs: [{ type: "bool" }], stateMutability: "view" },
  {
    type: "function",
    name: "poolInfo",
    inputs: [{ type: "address" }],
    outputs: [
      { name: "registered", type: "bool" },
      {
        name: "config",
        type: "tuple",
        components: [
          { name: "ethRewardsBps", type: "uint16" },
          { name: "buybackReflectBps", type: "uint16" },
          { name: "buybackBurnBps", type: "uint16" },
          { name: "tokenReflectBps", type: "uint16" },
        ],
      },
      {
        name: "poolKey",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
    ],
    stateMutability: "view",
  },
] as const;

const collectAbi = [
  {
    type: "function",
    name: "collect",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      { name: "quoteFees", type: "uint256" },
      { name: "tokenFees", type: "uint256" },
      // The auto-compounded share, already deducted from what reaches the
      // creator/holder split. Reported so the keeper can price the collect off
      // what it will actually be paid on, not off gross fees.
      { name: "quoteToLp", type: "uint256" },
      { name: "tokenToLp", type: "uint256" },
    ],
    stateMutability: "nonpayable",
  },
] as const;

const launchesAbi = [
  {
    type: "function",
    name: "launches",
    inputs: [{ type: "address" }],
    outputs: [
      { name: "creator", type: "address" },
      { name: "creatorBps", type: "uint16" },
      { name: "holdersBps", type: "uint16" },
      { name: "lpBps", type: "uint16" },
      { name: "tickUpper", type: "int24" },
      { name: "tokenId", type: "uint256" },
      { name: "distributor", type: "address" },
      {
        name: "poolKey",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
    ],
    stateMutability: "view",
  },
] as const;

type KeeperToken = { address: Address; mode: string; blockNumber?: string };

const TOKEN_PAGE = 1000;
/// Hard stop so a misbehaving cursor cannot spin a tick forever.
const MAX_TOKEN_PAGES = 50;

async function getTokens(): Promise<KeeperToken[]> {
  if (process.env.TOKENS) {
    return process.env.TOKENS.split(",")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((address) => ({ address: address as Address, mode: "" }));
  }
  // Reflection tiers plus 1%-tier burn-dial tokens ("creatorBurn") — both are
  // registered on the distributor, so both are crankable for the bounty.
  //
  // `cell: "native"` is load-bearing. Without it this returns stock-cell tokens
  // too, and every job below then runs the NATIVE locker/distributor against
  // them: `collect` reverts `UnknownToken` on every token, every tick, and
  // `launches()` quietly returns a zeroed struct rather than reverting, so the
  // pool key handed to `sweep` is all zeros. The stock cell is serviced
  // separately by `stockTick`, against its own contracts.
  //
  // Paginated because the indexer caps an
  // unqualified list at 50 rows and reports no truncation, so a short list is
  // indistinguishable from a small protocol. Anything past the cap would simply
  // never be serviced, in whatever order the indexer happened to return.
  const out: KeeperToken[] = [];
  let after: string | null = null;

  for (let page = 0; page < MAX_TOKEN_PAGES; page++) {
    const cursor: string = after ? `, after: "${after}"` : "";
    const data = await gql<{
      tokens?: { items?: KeeperToken[]; pageInfo?: { hasNextPage: boolean; endCursor: string | null } };
    }>(
      `{ tokens(where: { cell: "native", OR: [{ reflections: true }, { mode: "creatorBurn" }] }, limit: ${TOKEN_PAGE}${cursor})` +
        ` { items { address mode blockNumber } pageInfo { hasNextPage endCursor } } }`,
    );
    // `gql` returns null when the indexer errored, [] when it genuinely has no
    // tokens. Collapsing the two was the worst failure mode in this file: a dead
    // indexer produced an empty token list, a tick that looped over nothing, and
    // NO log line at all — a keeper doing nothing looked exactly like a keeper
    // with nothing to do. Keeper liveness is a security property; say it out loud.
    if (data === null) {
      if (page === 0) throw new Error("indexer unreachable or returned an error — cannot enumerate tokens");
      console.warn(`token pagination stopped early at ${out.length} — some tokens are unserviced this tick`);
      return out;
    }

    const tokens = data.tokens;
    out.push(...(tokens?.items ?? []));
    if (!tokens?.pageInfo?.hasNextPage || !tokens.pageInfo.endCursor) {
      if (out.length === 0) console.warn("indexer returned zero tokens — nothing to service this tick");
      return out;
    }
    after = tokens.pageInfo.endCursor;
  }

  console.warn(`token pagination hit the page limit at ${out.length} — some tokens are unserviced this tick`);
  return out;
}

/// Per-token launch record. Immutable after launch, so read once and keep it.
/// `holdersBps` is the STORED share (0–8000), the fraction of WETH fees the
/// locker actually routes to the distributor — and therefore the base the crank
/// bounty is a cut of. `poolKey` is the pool's own key, taken from the same
/// record: it is the only correct source (the quote is native ETH, not WETH,
/// and the gate address differs per deploy), so nothing here reconstructs it.
/// `canAccrue` for every token this tick, from one multicall.
///
/// Request count is what decides how many tokens a 60s tick can service at
/// all: at ~19 req/s shared, a per-token read plus a collect simulation puts
/// the ceiling in the low hundreds. Batching the cheap half means only the
/// tokens that can actually accrue reach the expensive half.
let accruableThisTick = new Map<string, boolean>();

async function loadAccruable(tokens: KeeperToken[]): Promise<void> {
  accruableThisTick = new Map();
  if (tokens.length === 0) return;
  try {
    const res = await publicClient.multicall({
      contracts: tokens.map(
        (t) =>
          ({ address: DISTRIBUTOR, abi: distributorAbi, functionName: "canAccrue", args: [t.address] }) as const,
      ),
      allowFailure: true,
      batchSize: 8192,
    });
    tokens.forEach((t, i) => {
      const r = res[i];
      // A failed read must not silently skip the token — fall through to the
      // per-token path, which is what ran before this optimisation existed.
      accruableThisTick.set(t.address.toLowerCase(), r?.status === "success" ? (r.result as boolean) : true);
    });
  } catch {
    // Multicall unavailable or refused: leave the map empty and let every token
    // take the individual read, exactly as it did before.
  }
}

const launchCache = new Map<string, { holdersBps: bigint; poolKey: PoolKey }>();

async function launchOf(token: Address) {
  const hit = launchCache.get(token.toLowerCase());
  if (hit) return hit;
  const rec = (await publicClient.readContract({
    address: LOCKER,
    abi: launchesAbi,
    functionName: "launches",
    args: [token],
  })) as readonly [Address, number, number, number, number, bigint, Address, PoolKey];
  const info = { holdersBps: BigInt(rec[2]), poolKey: rec[7] };
  launchCache.set(token.toLowerCase(), info);
  return info;
}

/// Reward config, likewise immutable. Only `ethRewardsBps` matters here: when it
/// is 0 the whole pending WETH pot is buyback budget, so the buyback cooldown
/// alone decides whether a `process` call can move anything.
const configCache = new Map<string, { ethRewardsBps: number }>();

async function configOf(token: Address) {
  const hit = configCache.get(token.toLowerCase());
  if (hit) return hit;
  const info = (await publicClient.readContract({
    address: DISTRIBUTOR,
    abi: distributorAbi,
    functionName: "poolInfo",
    args: [token],
  })) as readonly [boolean, { ethRewardsBps: number }, unknown];
  const cfg = { ethRewardsBps: Number(info[1].ethRewardsBps) };
  configCache.set(token.toLowerCase(), cfg);
  return cfg;
}

// --- token-side valuation -------------------------------------------------
//
// Token-denominated income (bounties and skims on tokens, plus token-side
// holder payouts) needs an ETH price to be floored economically rather than
// with an arbitrary dust threshold. One quoter call per token per tick prices a
// reference lot; everything else is scaled off that. Approximation is fine —
// this only decides whether an action is worth firing, never an on-chain amount.

const REFERENCE_LOT = parseEther("1000000"); // 0.1% of supply: deep enough to price, small enough to fill
const tokenPriceCache = new Map<string, { wethPerLot: bigint; tick: number }>();
let tickSeq = 0;

/// Wei of ETH that `amount` of `token` is worth, or null if it can't be priced.
async function valueInEth(token: Address, poolKey: PoolKey, amount: bigint): Promise<bigint | null> {
  if (amount === 0n) return 0n;
  const key = token.toLowerCase();
  let hit = tokenPriceCache.get(key);
  if (!hit || hit.tick !== tickSeq) {
    const quoted = await quoteTokenToQuote(publicClient, account, poolKey, REFERENCE_LOT);
    if (quoted === null || quoted === 0n) return null;
    hit = { wethPerLot: quoted, tick: tickSeq };
    tokenPriceCache.set(key, hit);
  }
  return (amount * hit.wethPerLot) / REFERENCE_LOT;
}

/// True if `amount` of the token is worth at least `floorWei`. Unpriceable
/// tokens are skipped rather than acted on blind — the conservative direction.
async function tokenWorth(token: Address, poolKey: PoolKey, amount: bigint, floorWei: bigint): Promise<boolean> {
  const value = await valueInEth(token, poolKey, amount);
  return value !== null && value >= floorWei;
}

// --- job 1: collect -------------------------------------------------------

/// Pull fees out of the LP position into the distributor. Returns true when it
/// actually cranked, so the caller knows fresh value landed.
async function collectOne(t: KeeperToken, c: Costs): Promise<boolean> {
  const { holdersBps, poolKey } = await launchOf(t.address);

  // The locker declines to pull while the distributor has too few shares to
  // divide by (IDistributor.canAccrue), so a collect here would return zeros and
  // pay no bounty. Skip the simulation entirely, and say so: fees are accruing
  // safely in the locked position, but the backlog released when a real holder
  // finally appears is proportional to how long this lasted, which is worth
  // knowing about before it happens rather than after.
  const batched = accruableThisTick.get(t.address.toLowerCase());
  const accruable =
    batched ??
    ((await publicClient.readContract({
      address: DISTRIBUTOR,
      abi: distributorAbi,
      functionName: "canAccrue",
      args: [t.address],
    })) as boolean);
  if (!accruable) {
    console.log(`collect deferred ${t.address}: too few holder shares to distribute — fees stay in the position`);
    return false;
  }

  // Simulate collect (eth_call — state discarded) to read what is claimable.
  const { result } = await publicClient.simulateContract({
    address: LOCKER,
    abi: collectAbi,
    functionName: "collect",
    args: [t.address],
    account,
  });
  // Net of the liquidity share: that part never reaches the split the bounty is
  // taken from, so pricing the job on gross fees would overstate the payout.
  const [grossQuote, grossToken, quoteToLp, tokenToLp] = result;
  const quoteFees = grossQuote - quoteToLp;
  const tokenFees = grossToken - tokenToLp;

  // Cheap pre-filter. The bounty is BOUNTY_BPS of the HOLDERS' share, not of
  // total fees, so the floor divides by that fraction — without it a token at
  // holdersBps 3333 cranks at exactly break-even and anything lower at a loss.
  // At holdersBps 0 no WETH ever arrives; such a token is fundable only from
  // the token side, so fall through to it rather than skipping outright.
  const wethWorth =
    holdersBps > 0n && (quoteFees * holdersBps * BOUNTY_BPS) / 100_000_000n >= c.collect;
  const tokenWorthIt =
    !wethWorth && (await tokenWorth(t.address, poolKey, (tokenFees * BOUNTY_BPS) / 10_000n, c.collect));
  if (!wethWorth && !tokenWorthIt) return false;

  // Authoritative gate: the contract tells us what it would pay us.
  const sim = await publicClient.simulateContract({
    address: DISTRIBUTOR,
    abi: distributorAbi,
    functionName: "crank",
    args: [t.address],
    account,
  });
  const [wethBounty, tokenBounty] = sim.result;
  if (wethBounty < c.collect && !(await tokenWorth(t.address, poolKey, tokenBounty, c.collect))) {
    return false;
  }

  const status = await send(
    sim.request,
    `cranked ${t.address} · fees=${formatEther(quoteFees)} ETH · bounty=${formatEther(wethBounty)} ETH` +
      ` + ${formatEther(tokenBounty)} token`,
  );
  return status === "success";
}

// --- job 2: process -------------------------------------------------------

/// Deploy what is already pending — buybacks, reflections, burns, WETH rewards.
/// Independent of fee accrual on purpose: the backlog is largest right after
/// heavy volume, exactly when new fees stop clearing the collect floor. Returns
/// true when it moved something, so the caller knows there is value to push.
async function processOne(t: KeeperToken, c: Costs, blockNumber: bigint): Promise<boolean> {
  const { poolKey } = await launchOf(t.address);
  const [pendingWeth, pendingToken] = await Promise.all([
    publicClient.readContract({ address: DISTRIBUTOR, abi: distributorAbi, functionName: "pendingWethOf", args: [t.address] }) as Promise<bigint>,
    publicClient.readContract({ address: DISTRIBUTOR, abi: distributorAbi, functionName: "pendingTokenOf", args: [t.address] }) as Promise<bigint>,
  ]);
  if (pendingWeth === 0n && pendingToken === 0n) return false;

  // Pre-filter on the skim the pot could pay.
  const wethWorth = (pendingWeth * PROCESS_SKIM_BPS) / 10_000n >= c.process;
  const tokenWorthIt =
    !wethWorth && (await tokenWorth(t.address, poolKey, (pendingToken * PROCESS_SKIM_BPS) / 10_000n, c.process));
  if (!wethWorth && !tokenWorthIt) return false;

  // A pot that is pure buyback budget can only be re-queued while the cooldown
  // holds, and a re-queue pays nothing. Skip the simulation entirely.
  if (pendingToken === 0n) {
    const { ethRewardsBps } = await configOf(t.address);
    if (ethRewardsBps === 0) {
      const allowance = (await publicClient.readContract({
        address: DISTRIBUTOR,
        abi: distributorAbi,
        functionName: "buybackAllowanceBpsOf",
        args: [t.address],
      })) as bigint;
      if (allowance < MIN_BUYBACK_ALLOWANCE_BPS) return false;
    }
  }

  const sim = await publicClient.simulateContract({
    address: DISTRIBUTOR,
    abi: distributorAbi,
    functionName: "process",
    args: [t.address],
    account,
  });
  const [wethSkim, tokenSkim] = sim.result;
  if (wethSkim < c.process && !(await tokenWorth(t.address, poolKey, tokenSkim, c.process))) return false;

  const status = await send(
    sim.request,
    `processed ${t.address} · skim=${formatEther(wethSkim)} ETH + ${formatEther(tokenSkim)} token`,
  );
  return status === "success";
}

// --- job 3: push ----------------------------------------------------------

/// Push accrued rewards to holders whose payout pays for its own gas.
async function pushOne(t: KeeperToken, c: Costs): Promise<void> {
  // Holders come from the chain, not from an index — see holders.ts. Scanning
  // from the launch block keeps it to a short range.
  const holders = await holdersOf(publicClient, t.address, {
    fromBlock: t.blockNumber ? BigInt(t.blockNumber) : undefined,
    // The pool, the protocol's own contracts and the burn address hold tokens
    // but must never be paid. The distributor enforces this too; skipping them
    // here just avoids reading owed amounts we know are zero.
    exclude: [
      LOCKER,
      DISTRIBUTOR,
      process.env.LAUNCHPAD_ADDRESS,
      process.env.POOL_MANAGER_ADDRESS,
      process.env.GATE_ADDRESS,
    ].filter(Boolean) as Address[],
    tick: tickSeq,
  });
  if (holders.length === 0) return;
  const { poolKey } = await launchOf(t.address);

  // A holder is worth pushing when the skim on their payout covers gas by
  // MARGIN — i.e. payout ≥ PUSH_GAS·gas·MARGIN·1e4/SKIM_BPS.
  const minPushWeth = (c.push * 10_000n) / SKIM_BPS;

  // One multicall for every holder's WETH + token withdrawable, rather than two
  // eth_calls each. At 10,000 holders that is the difference between ~40
  // requests a tick and 20,000 — and this RPC answers JSON-RPC batches with a
  // flat 429, so viem's transport-level batching is not an alternative.
  //
  // allowFailure keeps one bad read from voiding the whole batch: a holder whose
  // call reverts is treated as owing nothing, which is what the old per-holder
  // `.catch(() => 0n)` did.
  const calls = holders.flatMap((h) => [
    { address: DISTRIBUTOR, abi: distributorAbi, functionName: "withdrawableWeth", args: [t.address, h] } as const,
    { address: DISTRIBUTOR, abi: distributorAbi, functionName: "withdrawableToken", args: [t.address, h] } as const,
  ]);
  const results = await publicClient.multicall({
    // 8192-byte calldata chunks rather than viem's 1024 default: measured
    // 5,000 holders (10,000 reads) in 2.8s this way, comfortably inside a tick.
    contracts: calls,
    allowFailure: true,
    batchSize: 8192,
  });
  const reads = holders.map((h, i) => {
    const w = results[i * 2];
    const tk = results[i * 2 + 1];
    return {
      h,
      wWeth: w?.status === "success" ? (w.result as bigint) : 0n,
      wTok: tk?.status === "success" ? (tk.result as bigint) : 0n,
    };
  });

  // Token-side payouts are valued in ETH against the same floor, so the
  // threshold is economic rather than an arbitrary dust constant.
  const worth: Address[] = [];
  for (const r of reads) {
    if (r.wWeth >= minPushWeth) worth.push(r.h);
    else if (r.wTok > 0n && (await tokenWorth(t.address, poolKey, r.wTok, minPushWeth))) worth.push(r.h);
  }
  if (worth.length === 0) return;

  for (let i = 0; i < worth.length; i += PUSH_BATCH) {
    const batch = worth.slice(i, i + PUSH_BATCH);
    await send(
      {
        address: DISTRIBUTOR,
        abi: distributorAbi,
        functionName: "claimForMany",
        args: [t.address, batch],
        account,
        chain: walletClient.chain,
      },
      `distributed ${t.address} · ${batch.length} holders`,
    );
  }
}

// FORCE_PUSH runs a distribution sweep every tick regardless of whether a crank
// fired — a periodic backlog catch-up (e.g. after keeper downtime). Normally push
// only follows a fresh crank; the economic filter keeps an empty sweep cheap.
const FORCE_PUSH = envBool("FORCE_PUSH", false);
const SWEEP_CFG = sweepConfigFromEnv();
const STOCK_CFG = stockConfigFromEnv(); // null unless STOCK_DISTRIBUTOR+STOCK_LOCKER set

async function tick(): Promise<void> {
  tickSeq++; // invalidates the per-tick token price cache
  const c = await costs();
  const [tokens, blockNumber] = await Promise.all([getTokens(), publicClient.getBlockNumber()]);

  await loadAccruable(tokens);

  for (const t of tokens) {
    try {
      const cranked = await collectOne(t, c);
      // A push follows either job: `process` is what turns a pot into holder
      // balances, so gating the push on the crank alone would leave freshly
      // distributed rewards sitting unclaimed until the next collect.
      const processed = PROCESS_ENABLED ? await processOne(t, c, blockNumber) : false;
      // Burn-only pools have no holder accounting — nothing to push, ever.
      if ((cranked || processed || FORCE_PUSH) && PUSH_ENABLED && t.mode !== "creatorBurn") await pushOne(t, c);
    } catch (e) {
      console.error(`skip ${t.address}: ${(e as Error).message.split("\n")[0]}`);
    }
  }
  // Convert accumulated token-side skims → WETH, keeping the rest as inventory.
  // Inert unless SWEEP_ENABLED and SWAP_ROUTER are set.
  const sweepable = await Promise.all(
    tokens.map(async (t) => ({ token: t.address, poolKey: (await launchOf(t.address)).poolKey })),
  );
  await sweep(sweepable, { publicClient, walletClient, account, cfg: SWEEP_CFG, minValueWei: c.sweep });
  // Stock cell (quote-denominated bounties) — inert unless configured.
  if (STOCK_CFG) await stockTick({ publicClient, walletClient, account, cfg: STOCK_CFG });

  heartbeat();
}

/// Touch the liveness file. Only a COMPLETED tick counts: a tick that threw
/// leaves the timestamp stale, which is exactly what the healthcheck should see.
/// Best-effort — a keeper must never die because it could not write a log.
function heartbeat(): void {
  try {
    writeFileSync(HEARTBEAT_FILE, `${Date.now()}\n`);
  } catch (e) {
    console.warn(`heartbeat write failed: ${(e as Error).message.split("\n")[0]}`);
  }
}

async function main() {
  // Configuration first, and fatally: a bad MARGIN or INTERVAL_MS is a security
  // or availability problem, not something to limp along with.
  assertConfigValid();
  if (DRY_RUN) console.log("DRY_RUN — simulating everything, sending nothing");

  // Best-effort banner: it's only diagnostics, so a rate-limited RPC at boot
  // must not stop the keeper reaching its loop (where failures are tolerated).
  // Without this, a 429 during startup exits(1) and Docker restarts straight
  // back into the same window — the crash-loop we actually observed.
  try {
    await syncRatesFromChain();
    const tokens = await getTokens();
    const c = await costs();
    console.log(
      `keeper up · account ${account.address} · ${tokens.length} tokens · push ${PUSH_ENABLED ? "on" : "off"}` +
        ` · process ${PROCESS_ENABLED ? "on" : "off"} · stock cell ${STOCK_CFG ? "on" : "off"}`,
    );
    // Print what PRODUCES the floors, not just the floors: MARGIN is the
    // security parameter, so it has to be visible at runtime.
    console.log(
      `rates (from chain) bounty=${BOUNTY_BPS} push=${SKIM_BPS} process=${PROCESS_SKIM_BPS} bps` +
        ` · MARGIN=${MARGIN} · interval=${INTERVAL}ms · pushBatch=${PUSH_BATCH}`,
    );
    console.log(
      `floors @ live gas (income must clear MARGIN×gas) · collect ≥ ${formatEther(c.collect)} ETH` +
        ` · process ≥ ${formatEther(c.process)} ETH · push holder ≥ ${formatEther((c.push * 10_000n) / SKIM_BPS)} ETH`,
    );
  } catch (e) {
    console.error(`keeper up · account ${account.address} · startup probe failed, entering loop anyway: ${(e as Error).message.split("\n")[0]}`);
  }
  // RUN_ONCE is a one-shot for scripts/CI — there a failure SHOULD be fatal, so
  // it stays outside the tolerant loop below.
  if (process.env.RUN_ONCE) {
    await tick();
    return;
  }
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      await tick();
    } catch (e) {
      // A tick failing is expected on a flaky public RPC. Log and wait for the
      // next interval: exiting here merely delegates the retry to Docker's
      // restart policy, which loses the interval, drops the gas-price cache,
      // and shows up as a crash-loop.
      console.error(`tick failed, retrying next interval: ${(e as Error).message.split("\n")[0]}`);
    }
    await new Promise((r) => setTimeout(r, INTERVAL));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
