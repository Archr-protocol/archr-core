import { type Address } from "viem";

// Validated configuration. Every knob the keeper reads comes through here.
//
// This exists because `MARGIN` is a security parameter, not an ops preference:
// the pending pot equilibrates at `gas × margin / skim`, so a number in this
// file bounds what an attacker can extract. Parsing these with a bare
// `Number()` / `BigInt()` and no bounds at all fails in three specific ways:
//
//   INTERVAL_MS=60s   -> Number() is NaN -> setTimeout(NaN) fires at 0ms, so the
//                        keeper hot-loops, hammering the RPC and burning gas.
//   MARGIN=3.5        -> BigInt() throws at MODULE EVALUATION, outside main()
//                        and outside every try/catch, so the process dies with
//                        an opaque trace and Docker restart-loops it.
//   PUSH_BATCH=abc    -> i += NaN exits the loop after sending claimForMany with
//                        an EMPTY array: gas burnt, every push silently dropped.
//
// All three are typos, not attacks, and all three are silent or cryptic. The
// rule here is: parse once, bound-check, and refuse to boot on a bad value with
// a message that names the variable.

const problems: string[] = [];

function fail(name: string, raw: string, why: string): void {
  problems.push(`${name}=${JSON.stringify(raw)} — ${why}`);
}

/// An integer in [min, max]. Rejects NaN, floats, and out-of-range.
export function envInt(name: string, def: number, min: number, max: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return def;
  const n = Number(raw);
  if (!Number.isFinite(n)) fail(name, raw, "not a number");
  else if (!Number.isInteger(n)) fail(name, raw, "must be a whole number");
  else if (n < min || n > max) fail(name, raw, `must be between ${min} and ${max}`);
  else return n;
  return def;
}

/// A non-negative integer as a bigint, in [min, max].
export function envBigInt(name: string, def: bigint, min: bigint, max: bigint): bigint {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return def;
  if (!/^\d+$/.test(raw.trim())) {
    fail(name, raw, "must be a whole number (no decimals, no units)");
    return def;
  }
  const n = BigInt(raw.trim());
  if (n < min || n > max) {
    fail(name, raw, `must be between ${min} and ${max}`);
    return def;
  }
  return n;
}

/// A boolean. Accepts only "true"/"false" so a typo cannot silently mean false.
export function envBool(name: string, def: boolean): boolean {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return def;
  const v = raw.trim().toLowerCase();
  if (v === "true" || v === "1") return true;
  if (v === "false" || v === "0") return false;
  fail(name, raw, 'must be "true" or "false"');
  return def;
}

/// A 0x-prefixed 20-byte address.
export function envAddress(name: string, required: boolean): Address | undefined {
  const raw = process.env[name];
  if (raw === undefined || raw === "") {
    if (required) problems.push(`${name} is required but not set`);
    return undefined;
  }
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw.trim())) {
    fail(name, raw, "not a 20-byte 0x address");
    return undefined;
  }
  return raw.trim() as Address;
}

/// Throws with every problem at once, so a misconfigured deploy is fixed in one
/// pass rather than one restart per typo. Call after all reads.
///
/// Deduped: the shared knobs (MARGIN, PUSH_BATCH, the gas figures) are read by
/// both cells, so a single typo would otherwise be reported twice.
export function assertConfigValid(): void {
  const unique = [...new Set(problems)];
  if (unique.length === 0) return;
  throw new Error(
    `keeper: ${unique.length} invalid configuration value(s):\n  - ${unique.join("\n  - ")}\n` +
      `Refusing to start. See keeper/.env.example for the accepted ranges.`,
  );
}

/// Simulate everything, send nothing. Every `writeContract` becomes a log line.
///
/// This is the flag that makes the keeper reviewable: without it the
/// floor-and-gate logic can only be exercised with a funded key against live
/// contracts. With it, a fork plus RUN_ONCE=1 walks every decision path and
/// moves nothing.
export const DRY_RUN = envBool("DRY_RUN", false);

/// Seconds a `fetch` may hang before it is abandoned. Node's undici defaults to
/// 300s headers + 300s body; ticks are serial, so one black-holed dependency
/// stalls the whole loop for minutes.
export const FETCH_TIMEOUT_MS = envInt("FETCH_TIMEOUT_MS", 10_000, 1_000, 120_000);

/// Where the liveness heartbeat is written. Each completed tick touches this
/// file; the Docker HEALTHCHECK reads its age. Keeper liveness is a security
/// property — the pending pot grows for as long as no keeper is running — so a
/// wedged keeper has to be distinguishable from a working one.
export const HEARTBEAT_FILE = process.env.HEARTBEAT_FILE ?? "/tmp/keeper-heartbeat";
