import {
  encodeAbiParameters,
  maxUint256,
  type Account,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";

// Uniswap v4 on Robinhood Chain (4663) — official addresses (env-overridable).
// NOTE: `weth` is only the ERC-20 the distributor pays holder rewards in. It is
// NOT a pool currency: archr pools are quoted in NATIVE ETH (currency0 = 0x0).
export const V4 = {
  poolManager: (process.env.POOL_MANAGER_ADDRESS ?? "0x8366a39CC670B4001A1121B8F6A443A643e40951") as Address,
  universalRouter: (process.env.UNIVERSAL_ROUTER ?? "0x8876789976decbfcbbbe364623c63652db8c0904") as Address,
  permit2: (process.env.PERMIT2 ?? "0x000000000022D473030F116dDEE9F6B43aC78BA3") as Address,
  quoter: (process.env.QUOTER ?? "0x8dc178efb8111bb0973dd9d722ebeff267c98f94") as Address,
  weth: (process.env.WETH_ADDRESS ?? "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73") as Address,
};

// A pool key is never reconstructed from constants here. Every launch stores its
// own in the locker's `Launch` record, and that is the only correct source: the
// quote currency is native ETH (not WETH) and the gate address differs per
// deploy. Rebuilding it from guesses produced a key for a pool that does not
// exist, which made the quoter revert on every call — verified on-chain against
// TENDIES 2026-08-11, and the reason the sweep had never swapped anything.
//
// currency0 = the quote (native ETH, or a stock token on the stock cell),
// currency1 = the launched token. Selling the token is currency1 → currency0,
// i.e. zeroForOne = false.
export type PoolKey = {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
};

const poolKeyComponents = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
] as const;

const quoterAbi = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "poolKey", type: "tuple", components: poolKeyComponents },
          { name: "zeroForOne", type: "bool" },
          { name: "exactAmount", type: "uint128" },
          { name: "hookData", type: "bytes" },
        ],
      },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const;

/// Expected output for an exact-in single-hop swap on ANY v4 pool (post-fee,
/// incl. price impact). Simulated (eth_call) — returns null on failure. The
/// caller always supplies the pool's real key (from the locker's Launch
/// record), so this works for native-ETH and stock-quoted pools alike.
export async function quoteExactInputSingle(
  client: PublicClient,
  account: Account,
  poolKey: PoolKey,
  zeroForOne: boolean,
  amountIn: bigint,
): Promise<bigint | null> {
  try {
    const { result } = await client.simulateContract({
      address: V4.quoter,
      abi: quoterAbi,
      functionName: "quoteExactInputSingle",
      args: [{ poolKey, zeroForOne, exactAmount: amountIn, hookData: "0x" }],
      account,
    });
    return (result as readonly [bigint, bigint])[0];
  } catch {
    return null;
  }
}

/// Expected quote-currency out for selling `amountIn` of the launched token.
export async function quoteTokenToQuote(
  client: PublicClient,
  account: Account,
  poolKey: PoolKey,
  amountIn: bigint,
): Promise<bigint | null> {
  return quoteExactInputSingle(client, account, poolKey, false, amountIn);
}

const erc20AllowanceAbi = [
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
] as const;

const permit2Abi = [
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }, { type: "address" }], outputs: [{ name: "amount", type: "uint160" }, { name: "expiration", type: "uint48" }, { name: "nonce", type: "uint48" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ name: "token", type: "address" }, { name: "spender", type: "address" }, { name: "amount", type: "uint160" }, { name: "expiration", type: "uint48" }], outputs: [] },
] as const;

/// Ensure the Universal Router can pull `amountIn` of `token` via Permit2:
/// (1) ERC20 approve token → Permit2 (max, once); (2) Permit2 approve token → UR.
export async function ensurePermit2(
  pub: PublicClient,
  wallet: WalletClient,
  account: Account,
  token: Address,
  amountIn: bigint,
  nowSec: number,
): Promise<void> {
  const erc20ToPermit2 = (await pub.readContract({
    address: token,
    abi: erc20AllowanceAbi,
    functionName: "allowance",
    args: [account.address, V4.permit2],
  })) as bigint;
  if (erc20ToPermit2 < amountIn) {
    const hash = await wallet.writeContract({
      address: token, abi: erc20AllowanceAbi, functionName: "approve",
      args: [V4.permit2, maxUint256], account, chain: wallet.chain,
    });
    await pub.waitForTransactionReceipt({ hash });
  }

  const [amount, expiration] = (await pub.readContract({
    address: V4.permit2, abi: permit2Abi, functionName: "allowance",
    args: [account.address, token, V4.universalRouter],
  })) as readonly [bigint, number, number];
  if (amount < amountIn || expiration < nowSec + 60) {
    const MAX_UINT160 = (1n << 160n) - 1n;
    const exp = nowSec + 3600;
    const hash = await wallet.writeContract({
      address: V4.permit2, abi: permit2Abi, functionName: "approve",
      args: [token, V4.universalRouter, MAX_UINT160, exp], account, chain: wallet.chain,
    });
    await pub.waitForTransactionReceipt({ hash });
  }
}

const urAbi = [
  { type: "function", name: "execute", stateMutability: "payable", inputs: [{ name: "commands", type: "bytes" }, { name: "inputs", type: "bytes[]" }, { name: "deadline", type: "uint256" }], outputs: [] },
] as const;

// Universal Router command + v4 action ids.
const CMD_V4_SWAP = "0x10" as Hex;
const A_SWAP_EXACT_IN_SINGLE = 0x06;
const A_SETTLE_ALL = 0x0c;
const A_TAKE_ALL = 0x0f;

/// Build the V4_SWAP calldata for an exact-in sell of the launched token into
/// its pool's quote currency.
export function encodeSellTokenForQuote(poolKey: PoolKey, amountIn: bigint, minOut: bigint): Hex {
  const actions = (`0x${[A_SWAP_EXACT_IN_SINGLE, A_SETTLE_ALL, A_TAKE_ALL].map((a) => a.toString(16).padStart(2, "0")).join("")}`) as Hex;

  const swapParams = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "poolKey", type: "tuple", components: poolKeyComponents },
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint128" },
          { name: "amountOutMinimum", type: "uint128" },
          { name: "hookData", type: "bytes" },
        ],
      },
    ],
    [{ poolKey, zeroForOne: false, amountIn, amountOutMinimum: minOut, hookData: "0x" }],
  );
  // SETTLE the token we owe (currency1), TAKE the quote we're owed (currency0).
  const settleParams = encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }],
    [poolKey.currency1, amountIn],
  );
  const takeParams = encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }],
    [poolKey.currency0, minOut],
  );

  return encodeAbiParameters(
    [{ type: "bytes" }, { type: "bytes[]" }],
    [actions, [swapParams, settleParams, takeParams]],
  );
}

/// Execute the token→quote sell through the Universal Router.
export async function swapTokenForQuote(
  pub: PublicClient,
  wallet: WalletClient,
  account: Account,
  poolKey: PoolKey,
  amountIn: bigint,
  minOut: bigint,
  nowSec: number,
): Promise<Hex> {
  await ensurePermit2(pub, wallet, account, poolKey.currency1, amountIn, nowSec);
  const input = encodeSellTokenForQuote(poolKey, amountIn, minOut);
  const hash = await wallet.writeContract({
    address: V4.universalRouter,
    abi: urAbi,
    functionName: "execute",
    args: [CMD_V4_SWAP, [input], BigInt(nowSec + 600)],
    account,
    chain: wallet.chain,
  });
  await pub.waitForTransactionReceipt({ hash });
  return hash;
}
