import {
  formatUnits,
  keccak256,
  parseEther,
  toHex,
  type Account,
  type Address,
  type PublicClient,
  type WalletClient,
} from "viem";
import { envBigInt, envBool, envInt } from "./config";
import { ethWeiToQuoteRaw, quoteRawToEthWei } from "./economics";
import { V4, quoteExactInputSingle, type PoolKey } from "./dex";
import { gql } from "./indexer";
import { holdersOf } from "./holders";
import { priceUsd } from "./prices";

// Stock cell — the same three independent jobs as the WETH cell (index.ts),
// against StockDistributor/StockLocker, with four differences:
//   1. Bounty + skim pay in each token's QUOTE currency (a Robinhood stock
//      token, e.g. NVDA) instead of WETH. Gas is still ETH, so the worth-it
//      floors are derived in ETH exactly like index.ts and converted to quote
//      units via USD (DexScreener, see prices.ts).
//   2. Robinhood can pause stock tokens (compliance halts). A paused quote makes
//      a stock BUYBACK revert, so `process` can revert outright. That's expected
//      production behavior, not an error state: we simulate first, log, back the
//      token off for a few ticks, and keep going. Quote PAYOUTS never revert —
//      the distributor skips unpayable quote legs (crank bounty forfeits, push
//      and process skims re-queue) and reports what it actually paid, so the
//      simulate-and-gate below prices a halt correctly for free.
//   3. Token-side value is priced against the STOCK pool key: token → quote on
//      the pool, then quote → ETH via USD. Like the native cell, the key comes
//      from the locker's Launch record, never rebuilt from constants.
//   4. sweep.ts does NOT cover this cell — it builds native-ETH pool keys. Token-
//      side skims earned here stay as inventory in the keeper wallet until the
//      operator decides a policy (hold, or extend the sweep with stock keys).
//      The floors still value that income correctly; it just isn't liquid ETH.
//
// Interface deltas vs the native distributor (everything else identical):
//   withdrawableWeth → withdrawableQuote · pendingWethOf → pendingQuoteOf
//   quoteOf(token) → the token's quote currency address

export type StockConfig = {
  distributor: Address;
  locker: Address;
  backoffTicks: number;
};

/// Enabled only when both addresses are set — otherwise the stock cell is fully
/// inert and the keeper runs exactly as before.
export function stockConfigFromEnv(): StockConfig | null {
  const distributor = process.env.STOCK_DISTRIBUTOR as Address | undefined;
  const locker = process.env.STOCK_LOCKER as Address | undefined;
  if (!distributor || !locker) return null;
  return {
    distributor,
    locker,
    backoffTicks: envInt("STOCK_BACKOFF_TICKS", 5, 0, 1_000),
  };
}

// Shared knobs (same envs/defaults as index.ts — one gas model for both cells).
const MARGIN = envBigInt("MARGIN", 3n, 1n, 1_000n);
// Measured 540k once the locker compounds the liquidity share — higher than the
// ETH cell's 406k because both sides are ERC-20 and each needs a permit2
// approval. Re-measure if the locker changes.
/// A stock-cell collect on chain measured 344,015 gas, moving quote-side fees
/// only (tokenFees was 0); one that also moves the token side does more work.
///
/// 400,000 errs slightly low deliberately. The floor is
/// COLLECT_GAS x gasPrice x MARGIN, so with MARGIN=3 the job still pays as long
/// as actual gas stays under 3x this, i.e. 1.2M — while setting it far above the
/// measured figure declines collects that would have made money.
///
/// Its own env name rather than COLLECT_GAS, which index.ts reads with a
/// different default, so the two cells tune independently.
const COLLECT_GAS = envBigInt("STOCK_COLLECT_GAS", 400_000n, 21_000n, 30_000_000n);
const PROCESS_GAS = envBigInt("PROCESS_GAS", 250_000n, 21_000n, 30_000_000n);
const PUSH_GAS = envBigInt("PUSH_GAS", 60_000n, 1_000n, 30_000_000n);
const PUSH_ENABLED = envBool("PUSH_ENABLED", true);
const PROCESS_ENABLED = envBool("PROCESS_ENABLED", true);
const PUSH_BATCH = envInt("PUSH_BATCH", 100, 1, 500);
// See the note in index.ts: allowance accrues per block and is capped, so this
// is a "too small to bother" floor rather than a cooldown boundary, and the
// poll cadence must stay at or under the bucket's refill time.
const MIN_BUYBACK_ALLOWANCE_BPS = envBigInt("MIN_BUYBACK_ALLOWANCE_BPS", 1n, 0n, 10_000n);

const stockDistributorAbi = [
  {
    type: "function",
    name: "crank",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      { name: "quoteBounty", type: "uint256" },
      { name: "tokenBounty", type: "uint256" },
    ],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "process",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      { name: "quoteSkim", type: "uint256" },
      { name: "tokenSkim", type: "uint256" },
    ],
    stateMutability: "nonpayable",
  },
  { type: "function", name: "claimForMany", inputs: [{ name: "token", type: "address" }, { name: "holders", type: "address[]" }], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "withdrawableQuote", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "withdrawableToken", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "pendingQuoteOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "pendingTokenOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "lastBuybackBlockOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "buybackAllowanceBpsOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "quoteOf", inputs: [{ type: "address" }], outputs: [{ type: "address" }], stateMutability: "view" },
  { type: "function", name: "BOUNTY_BPS", inputs: [], outputs: [{ type: "uint16" }], stateMutability: "view" },
  { type: "function", name: "PUSH_SKIM_BPS", inputs: [], outputs: [{ type: "uint16" }], stateMutability: "view" },
  { type: "function", name: "PROCESS_SKIM_BPS", inputs: [], outputs: [{ type: "uint16" }], stateMutability: "view" },
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
      // creator/holder split — price the collect on the net, not the gross.
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
const decimalsAbi = [
  { type: "function", name: "decimals", inputs: [], outputs: [{ type: "uint8" }], stateMutability: "view" },
] as const;

/// Stock tokens: static STOCK_TOKENS list wins; otherwise ask the indexer for
/// cell-tagged tokens.
///
/// Note that an indexer error and "no stock tokens" are indistinguishable here —
/// `gql` returns null on failure and this collapses both to []. `stockTick` then
/// returns without logging anything, so a broken indexer looks exactly like a
/// protocol with no stock launches. The native path deliberately does NOT do
/// this (see `getTokens`); it is tolerated here only because the stock cell has
/// no liveness guarantee of its own yet.
async function getStockTokens(): Promise<{ address: Address; mode: string; blockNumber?: string }[]> {
  if (process.env.STOCK_TOKENS) {
    return process.env.STOCK_TOKENS.split(",")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((address) => ({ address: address as Address, mode: "" }));
  }
  // Only distributor-registered stock tokens are crankable: reflection tiers
  // plus 1%-tier burn-dial tokens ("creatorBurn"). Plain 1% tokens are not.
  const data = await gql<{ tokens?: { items?: { address: Address; mode: string }[] } }>(
    '{ tokens(where: { cell: "stock", OR: [{ reflections: true }, { mode: "creatorBurn" }] }) { items { address mode blockNumber } } }',
  );
  return data?.tokens?.items ?? [];
}

type Deps = { publicClient: PublicClient; walletClient: WalletClient; account: Account; cfg: StockConfig };

/// Per-token metadata, all immutable after launch. `holdersBps` is the STORED
/// share the locker routes to the distributor — the base the crank bounty cuts.
/// `poolKey` is the launch record's key VERBATIM, currencies included.
type Meta = {
  quote: Address;
  decimals: number;
  holdersBps: bigint;
  poolKey: PoolKey;
  ethRewardsBps: number;
};
const metaCache = new Map<string, Meta>();

async function getMeta(pub: PublicClient, cfg: StockConfig, token: Address): Promise<Meta> {
  const hit = metaCache.get(token.toLowerCase());
  if (hit) return hit;
  const [launch, pool] = await Promise.all([
    pub.readContract({ address: cfg.locker, abi: launchesAbi, functionName: "launches", args: [token] }) as Promise<
      readonly [Address, number, number, number, number, bigint, Address, PoolKey]
    >,
    pub.readContract({ address: cfg.distributor, abi: stockDistributorAbi, functionName: "poolInfo", args: [token] }) as Promise<
      readonly [boolean, { ethRewardsBps: number }, { currency0: Address }]
    >,
  ]);
  // The key is taken WHOLE from the launch record, currencies included — the
  // same thing index.ts does. Rebuilding currency0/currency1 from `poolInfo`
  // plus the token address would be correct only because StockLaunchpad reverts
  // with TokenSortsBelowQuote unless the token sorts above the quote, and a key
  // resting on an invariant in another contract quotes a pool that may not
  // exist — which fails silently, as a skip rather than an error. See dex.ts.
  const poolKey = launch[7];
  const quote = poolKey.currency0;
  const decimals = Number(
    await pub.readContract({ address: quote, abi: decimalsAbi, functionName: "decimals" }).catch(() => 18),
  );
  const meta: Meta = {
    quote,
    decimals,
    holdersBps: BigInt(launch[2]),
    poolKey,
    ethRewardsBps: Number(pool[1].ethRewardsBps),
  };
  metaCache.set(token.toLowerCase(), meta);
  return meta;
}

// On-chain incentive rates — read once from the deployed distributor so the
// floor math can never drift from the contract (v2 stock cell is 1%/1%/1%; the
// hardcoded fallbacks match that if the read fails).
let bpsCache: { bounty: bigint; skim: bigint; process: bigint } | null = null;
async function getBps(pub: PublicClient, distributor: Address) {
  if (bpsCache) return bpsCache;
  const [bounty, skim, proc] = await Promise.all([
    pub.readContract({ address: distributor, abi: stockDistributorAbi, functionName: "BOUNTY_BPS" }).catch(() => 100),
    pub.readContract({ address: distributor, abi: stockDistributorAbi, functionName: "PUSH_SKIM_BPS" }).catch(() => 100),
    pub.readContract({ address: distributor, abi: stockDistributorAbi, functionName: "PROCESS_SKIM_BPS" }).catch(() => 100),
  ]);
  bpsCache = { bounty: BigInt(bounty as number), skim: BigInt(skim as number), process: BigInt(proc as number) };
  return bpsCache;
}

// The ETH-wei <-> raw-quote conversions this file's floors are built on now live
// in `economics.ts`, so both cells convert the same way and the arithmetic can
// be checked without a chain in front of it. Floats
// are fine in them: they only gate whether a job is worth firing, never an
// on-chain amount.

// Compliance-halt backoff: token → ticks left to skip.
const backoff = new Map<string, number>();

const transferProbeAbi = [
  {
    type: "function",
    name: "transfer",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

/// Tokens already alarmed on, so a standing block logs once rather than every
/// tick. Cleared as soon as the probe comes back clean.
const blockedLockers = new Set<string>();

/// Distinguishes the two reasons a stock quote can stop moving, which need very
/// different responses:
///
///   - a PAUSE is global and transient (a compliance halt). Everything recovers
///     on its own; the normal backoff handles it and it is not worth waking
///     anyone for.
///   - a BLOCKLIST on the locker is targeted and indefinite. It freezes fee
///     collection for every token on that quote — including the token leg,
///     because `_pullFees` resolves both currency deltas in one call and cannot
///     take one without the other. Nothing in the contracts can fix it (they are
///     immutable, and no choice of recipient address helps); the remedy is to
///     talk to the issuer. That needs a human, so it gets an alarm.
///
/// The probe is a differential eth_call: ask the quote to move 1 unit from the
/// pool manager (which always holds pool reserves, so the balance check passes)
/// to the locker, and the same to a control. Both failing means the token is
/// halted for everyone; only the locker failing means the locker specifically is
/// blocked. The control is a fresh address derived per tick — nothing can have
/// pre-blocked an address nobody has ever seen, which is what makes it a valid
/// control rather than a second thing that might itself be blocked.
async function probeLockerBlocked(ctx: Ctx, token: Address): Promise<void> {
  const { publicClient, cfg } = ctx.deps;
  const control = `0x${keccak256(toHex(`${token}:${ctx.blockNumber}`)).slice(-40)}` as Address;
  const probe = (to: Address) =>
    publicClient
      .simulateContract({
        address: ctx.meta.quote,
        abi: transferProbeAbi,
        functionName: "transfer",
        args: [to, 1n],
        account: V4.poolManager,
      })
      .then(() => true)
      .catch(() => false);

  const [lockerOk, controlOk] = await Promise.all([probe(cfg.locker), probe(control)]);

  const key = token.toLowerCase();
  if (!lockerOk && controlOk) {
    if (!blockedLockers.has(key)) {
      blockedLockers.add(key);
      // Greppable, deliberately loud: this is the one stock-cell failure mode
      // that does not clear itself.
      console.error(
        `ALARM stock-locker-blocklisted · quote=${ctx.meta.quote} · locker=${cfg.locker} · token=${token}` +
          ` · fee collection is frozen for EVERY token on this quote, both legs.` +
          ` Fees keep accruing in the position and trading is unaffected;` +
          ` nothing on-chain can clear this — contact the issuer.`,
      );
    }
  } else if (blockedLockers.delete(key)) {
    console.log(`stock-locker-blocklisted cleared · quote=${ctx.meta.quote} · token=${token}`);
  }
}

/// Per-tick token→quote price, on the STOCK pool key (delta 3). One quoter call
/// per token per tick prices a reference lot; everything else scales off it.
const REFERENCE_LOT = parseEther("1000000");
const tokenPriceCache = new Map<string, { quotePerLot: bigint; tick: number }>();
let tickSeq = 0;

/// What `amount` of the launched token is worth in ETH wei, priced token →
/// quote on its own pool and then quote → ETH via USD. Null when unpriceable,
/// which callers treat as "skip", never as "free".
async function tokenValueEth(
  pub: PublicClient,
  account: Account,
  token: Address,
  meta: Meta,
  amount: bigint,
  ethUsd: number,
  quoteUsd: number,
): Promise<bigint | null> {
  if (amount === 0n) return 0n;
  const key = token.toLowerCase();
  let hit = tokenPriceCache.get(key);
  if (!hit || hit.tick !== tickSeq) {
    const quoted = await quoteExactInputSingle(
      pub,
      account,
      meta.poolKey,
      false, // selling the launched token (currency1) for its quote (currency0)
      REFERENCE_LOT,
    );
    if (quoted === null || quoted === 0n) return null;
    hit = { quotePerLot: quoted, tick: tickSeq };
    tokenPriceCache.set(key, hit);
  }
  const quoteRaw = (amount * hit.quotePerLot) / REFERENCE_LOT;
  return quoteRawToEthWei(quoteRaw, ethUsd, quoteUsd, meta.decimals);
}

type Ctx = {
  deps: Deps;
  meta: Meta;
  ethUsd: number;
  quoteUsd: number;
  /// Worth-it floors in ETH wei — MARGIN × the gas each job burns.
  collectEth: bigint;
  processEth: bigint;
  pushEth: bigint;
  rates: { bounty: bigint; skim: bigint; process: bigint };
  blockNumber: bigint;
};

/// True if `tokenAmount` of the launched token clears an ETH-denominated floor.
async function tokenClears(ctx: Ctx, token: Address, tokenAmount: bigint, floorEth: bigint): Promise<boolean> {
  const value = await tokenValueEth(
    ctx.deps.publicClient, ctx.deps.account, token, ctx.meta, tokenAmount, ctx.ethUsd, ctx.quoteUsd,
  );
  return value !== null && value >= floorEth;
}

// --- job 1: collect -------------------------------------------------------

async function collectOne(ctx: Ctx, token: Address): Promise<boolean> {
  const { publicClient, walletClient, account, cfg } = ctx.deps;
  const minFeeQuote = ethWeiToQuoteRaw(ctx.collectEth, ctx.ethUsd, ctx.quoteUsd, ctx.meta.decimals);

  // Simulate collect (eth_call — state discarded) to read what is claimable.
  const { result } = await publicClient.simulateContract({
    address: cfg.locker,
    abi: collectAbi,
    functionName: "collect",
    args: [token],
    account,
  });
  // Net of the liquidity share: that part never reaches the split the bounty is
  // taken from, so pricing on gross fees would overstate the payout.
  const [grossQuote, grossToken, quoteToLp, tokenToLp] = result;
  const quoteFees = grossQuote - quoteToLp;
  const tokenFees = grossToken - tokenToLp;

  // The bounty is a cut of the HOLDERS' share, not of total fees — divide the
  // floor by that fraction or a low-share token cranks at a loss. At holdersBps
  // 0 no quote arrives at all; fall through to the token side, which is exactly
  // what funds those tokens.
  const quoteWorth =
    ctx.meta.holdersBps > 0n && (quoteFees * ctx.meta.holdersBps * ctx.rates.bounty) / 100_000_000n >= minFeeQuote;
  const tokenWorth =
    !quoteWorth && (await tokenClears(ctx, token, (tokenFees * ctx.rates.bounty) / 10_000n, ctx.collectEth));
  if (!quoteWorth && !tokenWorth) return false;

  // Simulate the crank before sending: the contract reports what it would pay,
  // which prices a paused quote (bounty forfeited → 0) correctly and for free.
  const sim = await publicClient.simulateContract({
    address: cfg.distributor,
    abi: stockDistributorAbi,
    functionName: "crank",
    args: [token],
    account,
  });
  const [quoteBounty, tokenBounty] = sim.result;
  const bountyEth = quoteRawToEthWei(quoteBounty, ctx.ethUsd, ctx.quoteUsd, ctx.meta.decimals);
  if (bountyEth < ctx.collectEth && !(await tokenClears(ctx, token, tokenBounty, ctx.collectEth))) return false;

  const hash = await walletClient.writeContract(sim.request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(
    `stock cranked ${token} · fees=${formatUnits(quoteFees, ctx.meta.decimals)} quote` +
      ` · bounty=${formatUnits(quoteBounty, ctx.meta.decimals)} quote · ${receipt.status} · ${hash}`,
  );
  if (receipt.status !== "success") throw new Error("crank reverted on-chain");
  return true;
}

// --- job 2: process -------------------------------------------------------

/// Returns true when it moved something, so the caller knows there is value to push.
async function processOne(ctx: Ctx, token: Address): Promise<boolean> {
  const { publicClient, walletClient, account, cfg } = ctx.deps;
  const [pendingQuote, pendingToken] = await Promise.all([
    publicClient.readContract({ address: cfg.distributor, abi: stockDistributorAbi, functionName: "pendingQuoteOf", args: [token] }) as Promise<bigint>,
    publicClient.readContract({ address: cfg.distributor, abi: stockDistributorAbi, functionName: "pendingTokenOf", args: [token] }) as Promise<bigint>,
  ]);
  if (pendingQuote === 0n && pendingToken === 0n) return false;

  const pendingSkimEth = quoteRawToEthWei(
    (pendingQuote * ctx.rates.process) / 10_000n, ctx.ethUsd, ctx.quoteUsd, ctx.meta.decimals,
  );
  const quoteWorth = pendingSkimEth >= ctx.processEth;
  const tokenWorth =
    !quoteWorth && (await tokenClears(ctx, token, (pendingToken * ctx.rates.process) / 10_000n, ctx.processEth));
  if (!quoteWorth && !tokenWorth) return false;

  // A pot that is pure buyback budget can only be re-queued while the cooldown
  // holds, and a re-queue pays nothing.
  if (pendingToken === 0n && ctx.meta.ethRewardsBps === 0) {
    const allowance = (await publicClient.readContract({
      address: cfg.distributor,
      abi: stockDistributorAbi,
      functionName: "buybackAllowanceBpsOf",
      args: [token],
    })) as bigint;
    if (allowance < MIN_BUYBACK_ALLOWANCE_BPS) return false;
  }

  // Simulate first: on the stock cell a buyback settles by transferring the
  // quote, so a paused quote makes this revert outright rather than pay zero.
  // The throw is caught by stockTick, which backs the token off.
  const sim = await publicClient.simulateContract({
    address: cfg.distributor,
    abi: stockDistributorAbi,
    functionName: "process",
    args: [token],
    account,
  });
  const [quoteSkim, tokenSkim] = sim.result;
  const skimEth = quoteRawToEthWei(quoteSkim, ctx.ethUsd, ctx.quoteUsd, ctx.meta.decimals);
  if (skimEth < ctx.processEth && !(await tokenClears(ctx, token, tokenSkim, ctx.processEth))) return false;

  const hash = await walletClient.writeContract(sim.request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(
    `stock processed ${token} · skim=${formatUnits(quoteSkim, ctx.meta.decimals)} quote · ${receipt.status} · ${hash}`,
  );
  if (receipt.status !== "success") throw new Error("process reverted on-chain");
  return true;
}

// --- job 3: push ----------------------------------------------------------

async function pushOne(ctx: Ctx, token: Address, launchBlock?: bigint): Promise<void> {
  const { publicClient, walletClient, account, cfg } = ctx.deps;
  // Holders come from the chain, not from an index — see holders.ts.
  const holders = await holdersOf(publicClient, token, {
    fromBlock: launchBlock,
    // The launchpad and pool manager hold the token during a launch and a swap,
    // so they show up in Transfer logs. The distributor refuses to pay them
    // anyway; excluding them here just saves reading an owed amount that is
    // always zero.
    exclude: [
      cfg.locker,
      cfg.distributor,
      process.env.STOCK_LAUNCHPAD_ADDRESS,
      process.env.POOL_MANAGER_ADDRESS ?? "0x8366a39CC670B4001A1121B8F6A443A643e40951",
      process.env.STOCK_GATE_ADDRESS,
    ].filter(Boolean) as Address[],
    tick: tickSeq,
  });
  if (holders.length === 0) return;

  // A holder is worth pushing when the skim on their payout covers gas by
  // MARGIN — i.e. payout ≥ PUSH_GAS·gas·MARGIN·1e4/PUSH_SKIM_BPS.
  const minPushEth = (ctx.pushEth * 10_000n) / ctx.rates.skim;
  const minPushQuote = ethWeiToQuoteRaw(minPushEth, ctx.ethUsd, ctx.quoteUsd, ctx.meta.decimals);

  // One multicall for every holder's quote + token withdrawable. Multicall3 IS
  // deployed on this chain at the canonical address; an older comment here said
  // it was not, and sent anyone reading it toward buying RPC capacity instead of
  // batching. Transport-level batching is not the alternative either — this RPC
  // answers JSON-RPC batches with a flat 429.
  const calls = holders.flatMap((h) => [
    { address: cfg.distributor, abi: stockDistributorAbi, functionName: "withdrawableQuote", args: [token, h] } as const,
    { address: cfg.distributor, abi: stockDistributorAbi, functionName: "withdrawableToken", args: [token, h] } as const,
  ]);
  const results = await publicClient.multicall({
    // 8192-byte calldata chunks rather than viem's 1024 default: measured
    // 5,000 holders (10,000 reads) in 2.8s this way, comfortably inside a tick.
    contracts: calls,
    allowFailure: true,
    batchSize: 8192,
  });
  const reads = holders.map((h, i) => {
    const q = results[i * 2];
    const tk = results[i * 2 + 1];
    return {
      h,
      wQuote: q?.status === "success" ? (q.result as bigint) : 0n,
      wTok: tk?.status === "success" ? (tk.result as bigint) : 0n,
    };
  });

  const worth: Address[] = [];
  for (const r of reads) {
    if (r.wQuote >= minPushQuote) worth.push(r.h);
    else if (r.wTok > 0n && (await tokenClears(ctx, token, r.wTok, minPushEth))) worth.push(r.h);
  }
  if (worth.length === 0) return;

  for (let i = 0; i < worth.length; i += PUSH_BATCH) {
    const batch = worth.slice(i, i + PUSH_BATCH);
    const hash = await walletClient.writeContract({
      address: cfg.distributor,
      abi: stockDistributorAbi,
      functionName: "claimForMany",
      args: [token, batch],
      account,
      chain: walletClient.chain,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`stock distributed ${token} · ${batch.length} holders · ${receipt.status} · ${hash}`);
    if (receipt.status !== "success") throw new Error("claimForMany reverted on-chain");
  }
}

const FORCE_PUSH = envBool("FORCE_PUSH", false);

export async function stockTick(deps: Deps): Promise<void> {
  const { publicClient, cfg } = deps;
  const tokens = await getStockTokens();
  if (tokens.length === 0) return;
  tickSeq++; // invalidates the per-tick token price cache

  const rates = await getBps(publicClient, cfg.distributor);
  const [gasPrice, blockNumber] = await Promise.all([publicClient.getGasPrice(), publicClient.getBlockNumber()]);
  // Same self-funding floors as index.ts, in ETH: income ≥ MARGIN × gas.
  const collectEth = COLLECT_GAS * gasPrice * MARGIN;
  const processEth = PROCESS_GAS * gasPrice * MARGIN;
  const pushEth = PUSH_GAS * gasPrice * MARGIN;
  const ethUsd = await priceUsd(V4.weth);

  for (const { address: token, mode, blockNumber: launchBlock } of tokens) {
    const left = backoff.get(token.toLowerCase()) ?? 0;
    if (left > 0) {
      backoff.set(token.toLowerCase(), left - 1);
      console.log(`stock backoff ${token} · ${left} tick(s) left`);
      continue;
    }
    try {
      const meta = await getMeta(publicClient, cfg, token);
      const quoteUsd = await priceUsd(meta.quote);
      if (!ethUsd || !quoteUsd) {
        // No USD price → can't tell if the income covers gas. Skip this tick
        // (conservative) rather than act blind.
        console.log(`stock skip ${token}: no USD price (eth=${ethUsd ?? "?"} quote=${quoteUsd ?? "?"})`);
        continue;
      }
      const ctx: Ctx = { deps, meta, ethUsd, quoteUsd, collectEth, processEth, pushEth, rates, blockNumber };

      const cranked = await collectOne(ctx, token);
      // A push follows either job: `process` is what turns a pot into holder
      // balances, so gating the push on the crank alone would leave freshly
      // distributed rewards sitting unclaimed until the next collect.
      const processed = PROCESS_ENABLED ? await processOne(ctx, token) : false;
      // Burn-only pools have no holder accounting — nothing to push, ever.
      if ((cranked || processed || FORCE_PUSH) && PUSH_ENABLED && mode !== "creatorBurn") await pushOne(ctx, token, launchBlock ? BigInt(launchBlock) : undefined);
    } catch (e) {
      // Reverts here are usually a paused quote token (Robinhood compliance
      // halt) blocking a buyback — expected in production. Back off and retry
      // in a few ticks rather than burning a simulation every tick.
      backoff.set(token.toLowerCase(), cfg.backoffTicks);
      console.error(
        `stock skip ${token} (backoff ${cfg.backoffTicks} ticks): ${(e as Error).message.split("\n")[0]}`,
      );
      // ...but separate the halt we ride out from the block we cannot. Failing
      // the probe itself must never mask the original error.
      try {
        const meta = await getMeta(publicClient, cfg, token);
        await probeLockerBlocked(
          { deps, meta, ethUsd: 0, quoteUsd: 0, collectEth, processEth, pushEth, rates, blockNumber },
          token,
        );
      } catch {
        /* probe is best-effort diagnostics */
      }
    }
  }
}
