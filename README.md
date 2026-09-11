# archr

The contracts running [archr.fun](https://archr.fun) in production, and the
off-chain keeper that services them. archr is a reflections launchpad on
Robinhood Chain, built on Uniswap v4.

Every launch creates a token, opens a gated pool, and locks the whole supply
single-sided and permanently. Trading fees are collected by anyone who calls
`collect()` and split between the creator, the token's holders, and the
treasury.

This repository holds only what is deployed and live. Deployment scripts,
tooling and the front end are not part of it.

## Contracts

A Foundry workspace on the Uniswap `v4-template` base (v4-core / v4-periphery /
OpenZeppelin, via the `uniswap-hooks` library).

- `src/ArchrToken.sol` — launch token: fixed supply, a per-wallet cap on inbound
  transfers over a fixed opening block window with a constructor-set exempt
  list, and a distributor checkpoint callback. One is deployed per launch, by
  the launchpad, via CREATE2.
- `src/LiquidityGate.sol` — a `beforeAddLiquidity`-only gate hook that keeps the
  Locker as the sole LP. Swap-inert, so pools stay routable without occupying an
  allowlist slot.
- `src/ArchrLocker.sol` — permanent LP custodian. A permissionless `collect()`
  splits every fee leg creator / holders / treasury and routes the holder share
  to the Distributor on reflection tiers, or 70/30 creator/treasury on the 1%
  tier.
- `src/ArchrDistributor.sol` — the singleton reflection engine: a dual-currency
  dividend accumulator, a per-transfer checkpoint callback, `claim()`, and
  buyback execution through each token's own pool for the reward presets.
- `src/ArchrLaunchpad.sol` — the factory. `launch()` (1% tier) and
  `launchReflection()` (3/5/8% plus a reward preset) each create a token, open a
  gated pool, lock 100% of supply single-sided, and optionally execute a first
  buy — in one call.
- `src/periphery/SelfServiceRouter.sol` — lets a holder drive the reward path
  for their own position without a keeper.
- `src/stock/` — a parallel cell running the same design against stock-token
  quotes rather than native ETH.

## Deployments

Robinhood Chain (`4663`). Verify any of these with `eth_getCode` against the
addresses below — the public RPC rejects requests without a browser-like
User-Agent.

| contract | address |
|---|---|
| ArchrLaunchpad | `0x266c5e7e1C3E8B2645dED3eCFEc2447d681E198d` |
| ArchrLocker | `0x50f44F34021726A7F947Cf9a308CB4df882A77aB` |
| ArchrDistributor | `0x80dC93B74Dd35f46fE80F3ecb615e6B7FD05AE20` |
| LiquidityGate | `0x2521d9638F734119E940Ec7056c073275D202A00` |
| SelfServiceRouter | `0xFf145015ff6bb9765AB7b8Ee82d94F013D32DcF5` |
| StockLaunchpad | `0x780571700a8ccbA2074Fc08b768ddA63E06125aD` |
| StockLocker | `0x673852e3E9a855b0d54e7C3239737aA73845E1Fa` |
| StockDistributor | `0x00B16CBE742BB7Ae1999d2b8e88D050eadE24040` |
| LiquidityGate (stock) | `0x7599de487076dc57F3a0c78919542702b0102A00` |
| SelfServiceRouter (stock) | `0x000c9Adf5E01287ce44171B38F7AF61E52819449` |

## Keeper

`keeper/` is the off-chain worker that turns accrued fees into reflections in
holders' wallets. It polls a set of tokens and runs three independent jobs
against each — moving LP fees to the distributor, converting pending balances
into rewards, buybacks or burns, and pushing accrued rewards out to holders.

Every job is permissionless and pays a share of what it moves, so each fires on
its own schedule under one rule: income must exceed a multiple of gas. Idle
tokens cost nothing and busy tokens fund their own upkeep.

Nothing here holds a privileged role. `collect()`, `claim()` and `claimForMany()`
are open to anyone, so the protocol keeps working whether or not a keeper is
running — anyone can run one, and the on-chain incentives make it self-funding.

```sh
cd keeper
npm install
cp .env.example .env     # then set KEEPER_PRIVATE_KEY
DRY_RUN=true RUN_ONCE=1 npm run once   # simulate everything, send nothing
npm start
```

Configuration is environment-driven — every value is documented in
`keeper/.env.example`. See [keeper/README.md](keeper/README.md) for install,
operation and troubleshooting.

## License

MIT. See [LICENSE](LICENSE).
