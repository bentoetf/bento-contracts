# Bento Protocol Contracts

Bento Protocol is a Robinhood Chain smart-contract system for on-chain stock-index tokens called **boxes**. A box is an ERC-20 that represents proportional exposure to a basket of tokenized stocks held in a dedicated vault.

This repository contains the Phase 1 contracts and operations scripts for the first box: **MAG7**, an equal-weight basket of NVDA, AAPL, MSFT, GOOGL, AMZN, META, and TSLA tokenized stocks.

> **Status:** Release candidate `v1.0.0-rc3`. These contracts are unaudited and should be deployed only with small launch caps and timelocked administration.

## What MAG7 does

MAG7 is a basket token with one `BoxVault` dedicated to the box. Users mint MAG7 by depositing ETH; the engine routes ETH into each component stock via the configured Uniswap V4 adapter route. Users can redeem MAG7 either:

- **for stocks:** receive the underlying tokenized stock components pro-rata; or
- **for ETH:** swap the components back to ETH through the configured routes.

Key mechanics:

- One vault per box; component assets are not shared across boxes.
- MAG7 weights are equal-ish: six components at `1428` bps and TSLA at `1432` bps.
- First mint targets a `$100` NAV-per-box genesis scale using a fresh ETH/USD feed.
- Later mints use proportional issuance from actual swap output and live backing.
- Mint and redeem-for-ETH support per-component slippage minimum arrays.
- Redeem-for-stocks is intentionally not pausable.
- If a stock token transfer is halted/blocked, redeem records a raw-token `pendingClaim` instead of bricking the whole box.

## Contracts

| Contract | Purpose |
|---|---|
| `BoxEngine` | Creates boxes, mints/redeems, enforces fees/caps/slippage/sanity checks, records paused-stock claims, exposes NAV/backing views. |
| `BoxToken` | ERC-20 + Permit token minted/burned only by the engine for each box. |
| `BoxVault` | Dedicated custody vault for one box. Component assets are unsweepable. |
| `BoxRegistry` | Maps box IDs to the engine version that serves them. |
| `BentoToken` | Fixed-supply BENTO ERC-20 + Permit with capped pair-only buy/sell tax controls. |
| `FeeCollector` | Receives box fees, redeems fee boxes, and buys back/burns BENTO through Sushi V2. |
| `UniswapV4Adapter` | Exact-input Uniswap V4 UniversalRouter adapter for stock routes. |
| `V2Adapter` | Simple V2 adapter used for mocks/tests and compatibility. |

## Fee structure

Phase 1 defaults:

| Fee | Default | Hard cap |
|---|---:|---:|
| Box mint fee | `30 bps` | `100 bps` |
| Box redeem fee | `30 bps` | `100 bps` |
| BENTO taxed-pair buy/sell tax | `300 bps` | `300 bps` |

Notes:

- Box fees go to `FeeCollector`; ETH fees are used for BENTO buyback-and-burn when a BENTO/ETH pool exists.
- Redeem fees accrue as box tokens to `FeeCollector`, then keepers can redeem those boxes to ETH.
- BENTO tax applies only to transfers to/from addresses flagged as taxed pairs. Plain wallet-to-wallet transfers are tax-free.
- Admin can lower or restore BENTO tax up to the hard cap, and can permanently disable it with `lockTaxForever()`.

## Security posture

**UNAUDITED.** This is a release candidate, not audited production software.

Protocol fees are intended to fund an independent security audit as a priority. Launch caps (`15 ETH` TVL, `2 ETH` per tx) will not be raised until an independent audit has been completed and published.

Controls and guardrails included:

- Timelocked admin model for production deployment.
- Small launch caps: MAG7 TVL cap `15 ETH`, per-transaction mint cap `2 ETH`.
- `ReentrancyGuard` on state-changing user flows.
- Per-component slippage minima for mint and redeem-for-ETH.
- Feed sanity checks for configured component feeds.
- Fresh-feed check for genesis mint pricing.
- `reservedClaims` accounting so paused-stock claims cannot be double-counted by later redeemers.
- Component tokens are programmatically unsweepable from vaults.
- Redeem paths are not pausable by design.

Read more:

- [RISKS.md](./RISKS.md)
- [SECURITY-NOTES.md](./SECURITY-NOTES.md)
- [SECURITY.md](./SECURITY.md)
- [DEPLOY.md](./DEPLOY.md)

## Build and test

### Requirements

- Foundry `forge 1.7.1` was used for RC3 validation.
- Solidity compiler `0.8.24` is configured in `foundry.toml`.

Install Foundry and select the validated version:

```bash
foundryup -v 1.7.1
forge --version
```

Install dependencies if submodules are not already checked out:

```bash
git submodule update --init --recursive
```

### Local checks

```bash
forge fmt --check
forge build
forge test -vv
forge snapshot
```

Expected RC3 + Phase 1G baseline:

```text
30 tests passed, 0 failed, 0 skipped
```

### Robinhood live fork tests

Fork tests are gated to avoid accidental network calls. To run the live fork acceptance set `RUN_LIVE_FORK=true` and provide an RPC URL:

```bash
RUN_LIVE_FORK=true \
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
forge test --match-contract 'Phase1GDeployForkTest|RobinhoodV4(Adapter|EngineLifecycle)ForkTest|DeploySafeForkTest' -vv
```

Expected current baseline:

```text
6 tests passed, 0 failed, 0 skipped
```

If a fork test fails with `FeedStale`, the stock feeds may not have refreshed recently. Production should keep conservative feed freshness unless governance intentionally changes it.

## Repository layout

```text
src/                  Core contracts and adapters
script/               Foundry deployment and smoke scripts
test/                 Unit tests, deploy-shape tests, gated Robinhood fork tests
scripts/              Utility scripts for local RPC/fork workflows
DEPLOY.md             Mainnet deploy and operations runbook
RISKS.md              Known limitations and launch risks
SECURITY-NOTES.md     Static-analysis triage and security notes
FORKREPORT.md         Robinhood fork discovery and lifecycle results
TEST-OUTPUT.md        Latest validation output summary
```

## Deployment

Start with [DEPLOY.md](./DEPLOY.md). The production path uses:

1. 2-of-3 Safe.
2. 24h `TimelockController`.
3. Immutable admin contracts deployed with `admin = timelock`.
4. Safe → Timelock setup execution.
5. Small caps and 0.01 ETH post-deploy smoke.

## License

This repository is licensed under the [MIT License](./LICENSE).

MIT was chosen for this contracts release candidate because it is simple, widely understood in the Ethereum/Foundry ecosystem, compatible with the OpenZeppelin/forge-std dependencies used here, and suitable for public peer review.
