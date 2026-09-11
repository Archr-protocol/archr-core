# archr keeper

Turns accrued trading fees into reflections in holders' wallets.

The keeper polls a set of tokens and runs three independent jobs against each.
Every job is permissionless and pays a share of what it moves, so running one is
self-funding rather than a favour to the protocol.

| job | what it moves | pays |
|---|---|---|
| `crank(token)` | LP fees → distributor | 1% of everything that arrives, in ETH **and** token |
| `process(token)` | pending balances → rewards, buybacks, burns | 1% of what actually moves |
| `claimForMany(token, holders)` | accrued rewards → holders' wallets | 1% of each payout |

Nothing here holds a privileged role. The same calls are open to anyone, so the
protocol keeps working whether or not any particular keeper is running — and
several can run at once without coordinating.

Each job has its own accumulator and fires on its own schedule under one rule:
**income must clear `MARGIN` × gas**. Idle tokens cost nothing, busy tokens fund
their own upkeep, and no work is ever stranded — the longer a pot sits unserviced
the more profitable draining it becomes.

## Requirements

- **Node 22 or newer.** (`node -v`. Node 20 works; the Docker image pins 22.)
- **An RPC endpoint** for Robinhood Chain (chain id `4663`). The public endpoint
  at `https://rpc.mainnet.chain.robinhood.com` is the default and sustains
  roughly 2–3 requests per second, which is enough for a small token set.
- **A funded wallet.** A dedicated key, not one you use for anything else — it
  signs unattended. Gas on Robinhood Chain is cheap; a few hundredths of an ETH
  is a long runway.
- **A source of tokens to service** — see [Token discovery](#token-discovery).

## Install

```sh
git clone https://github.com/Archr-protocol/archr-core
cd archr-core/keeper
npm install
cp .env.example .env
```

Then open `.env` and set `KEEPER_PRIVATE_KEY`. Everything else is pre-filled with
the addresses of the live deployment and sensible defaults; `.env.example`
documents every value and its accepted range.

A missing or malformed key fails at startup with
`invalid private key, expected hex or 32 bytes` — it must be a full 32-byte hex
string with the `0x` prefix.

## Try it without spending anything

`DRY_RUN=true` simulates every job and sends no transactions; each write becomes
a log line instead. With `RUN_ONCE=1` the keeper performs a single pass and
exits. Together they walk the entire decision path against live contracts
without a funded key:

```sh
DRY_RUN=true RUN_ONCE=1 npm run once
```

A healthy pass looks like this:

```
keeper up · account 0x… · 1 tokens · push on · process on · stock cell on
rates (from chain) bounty=100 push=100 process=100 bps · MARGIN=3 · interval=60000ms · pushBatch=100
floors @ live gas (income must clear MARGIN×gas) · collect ≥ 0.000142128 ETH · process ≥ 0.0000846 ETH · push holder ≥ 0.0020304 ETH
```

Tokens with nothing worth doing are skipped silently, so a pass that prints the
banner and stops there is working correctly — it means no pot currently clears
its floor. Run it against the live chain before changing any floor.

Two things behave differently in a dry run:

- **Downstream jobs do not fire.** `process` and the push follow a *successful*
  crank; nothing was sent, so they are correctly skipped. Set `FORCE_PUSH=true`
  to exercise the push path anyway.
- **Token-side pricing needs the v4 quoter.** Against a bare local node there is
  no quoter to call, so token-denominated income is skipped rather than priced.
  Fork a real chain to exercise that half.

## Run it

```sh
npm start
```

That loops every `INTERVAL_MS` (default 60s) until stopped. Each completed pass
touches `HEARTBEAT_FILE` (default `/tmp/keeper-heartbeat`).

### Docker

```sh
docker build -t archr-keeper .
docker run -d --restart unless-stopped --env-file .env --name archr-keeper archr-keeper
```

The image ships a `HEALTHCHECK` that reads the heartbeat's age and reports
unhealthy once it exceeds `HEARTBEAT_MAX_AGE_MS` (default 180s, ~3× the default
interval). Adjust both together if you change the interval.

## Token discovery

The keeper needs a list of tokens to service, and takes it from one of two
places.

**From an indexer.** Set `INDEXER_URL` to a GraphQL endpoint that serves the
protocol's token rows. The default points at archr.fun's public read proxy:

```
INDEXER_URL=https://archr.fun/api/indexer
```

This is the simplest option and the one most operators want. It is a courtesy
endpoint on someone else's infrastructure — if you are running a keeper you care
about, run your own indexer against the launchpad's `Launched` events and point
`INDEXER_URL` at that instead.

If the indexer cannot be reached the pass aborts loudly with
`indexer unreachable or returned an error — cannot enumerate tokens`. That is
deliberate: an empty token list and a dead indexer must not look alike, because
a keeper doing nothing would otherwise be indistinguishable from a keeper with
nothing to do.

**From a static list.** `TOKENS` takes precedence over the indexer and needs no
external service at all:

```
TOKENS=0x…,0x…
```

If you use a static list, **also set `HOLDER_SCAN_FROM` to the earliest launch
block among those tokens.** The keeper derives holders by scanning a token's
`Transfer` logs, and normally gets each token's launch block from the indexer to
keep that scan short. A static list carries no launch block, so the scan starts
at `HOLDER_SCAN_FROM` — which defaults to `0` and will crawl the entire chain in
`HOLDER_SCAN_CHUNK`-sized steps.

## Addresses

The contract addresses in `.env.example` must match the deployment your token
list is drawn from. Pointing them at a different deployment of the same
contracts does not fail cleanly: the launchpad returns a zeroed launch record
rather than reverting, and `collect` then reverts on every token, every pass:

```
skip 0x…: The contract function "collect" reverted
```

If you see that on every token, check `LOCKER_ADDRESS`, `DISTRIBUTOR_ADDRESS`
and `LAUNCHPAD_ADDRESS` against the table in the [repository
README](../README.md) first.

`BOUNTY_BPS`, `SKIM_BPS` and `PROCESS_SKIM_BPS` are read from chain at startup
and the chain value always wins; the values in `.env` are only a fallback if that
read fails, and a mismatch is logged.

## Running more than one

Redundancy is worth having: the pending reward pot grows for as long as no keeper
is servicing it, so an outage is not just missed yield.

**Each instance needs its own key.** Two instances sharing `KEEPER_PRIVATE_KEY`
draw the same nonce and submit conflicting transactions; the loser gets
`replacement underpriced` and then blocks waiting for a receipt that never
comes. With separate keys they simply race — the first drains a pot, the second
finds nothing worth doing and moves on, costing one wasted simulation. Give each
its own gas float.

Alert on the heartbeat. A keeper that stops is otherwise silent.

## Stock cell

`src/stock.ts` runs the same three jobs against `StockDistributor` and
`StockLocker`, where bounties and skims are paid in each token's stock quote
rather than in ether. It turns on only when both `STOCK_DISTRIBUTOR` and
`STOCK_LOCKER` are set.

Two differences matter operationally. A paused or halted stock quote is routine
rather than an error: payouts skip and re-queue, while a buyback settles in the
quote currency and so reverts, which the keeper detects by simulating first and
then backs that token off for `STOCK_BACKOFF_TICKS` passes. And the sweep does
not cover this cell — skims earned there accumulate as token inventory in the
keeper wallet.

Because the two cells have no common currency, their floors are compared through
USD prices. If no price is available the collect is skipped rather than guessed
at; the fees stay in a position nobody can withdraw from and the next pass
retries.

## Sweeping skims to ETH

Off by default. `SWEEP_ENABLED=true` converts `SWAP_PCT` of each accrued token
skim into ETH through the token's own pool, subject to `MAX_SLIPPAGE_BPS`.
Everything it touches stays in the keeper wallet. It covers the native cell
only, since it builds native-ETH pool keys.

`SWEEP_DRY_RUN` defaults to true even when the sweep is enabled, so the first
run quotes and logs without swapping. Read that output before turning it off.

## Configuration reference

`.env.example` is the reference — every value is listed there with its units,
default and accepted range, grouped by what it affects. All of them are bounds
checked at startup, and the keeper refuses to boot on a bad one rather than
hot-looping or dying later with an opaque trace:

```
keeper: 1 invalid configuration value(s):
  - …
Refusing to start. See keeper/.env.example for the accepted ranges.
```

There is deliberately no override for the worth-it floors. Forcing a job below
its floor means paying more in gas than the job earns, on every pass, for every
token.

## Troubleshooting

| symptom | cause |
|---|---|
| `invalid private key, expected hex or 32 bytes` | `KEEPER_PRIVATE_KEY` unset or not a `0x`-prefixed 32-byte hex string |
| `indexer unreachable or returned an error` | `INDEXER_URL` wrong or unreachable, and no `TOKENS` list set |
| `indexer returned zero tokens` | reached the indexer, but it has no matching rows |
| `collect` reverts on every token | contract addresses are from a different deployment |
| passes complete but nothing ever fires | normal when no pot clears its floor — confirm with the floors line in the banner |
| a pass hangs for minutes | full-chain holder scan; set `HOLDER_SCAN_FROM` when using a static `TOKENS` list |
| heartbeat goes stale | a pass threw; the file is only touched on completion |
