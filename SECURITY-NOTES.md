# SECURITY-NOTES

Static-analysis pass for Bento Phase 1D hardening.

## Tooling

```text
uvx --from slither-analyzer slither . --exclude-dependencies --filter-paths 'test/|script/' --json slither-report.json
slither_exit=255 because findings were reported.
```

Raw artifacts retained locally:

- `slither-output.txt`
- `slither-report.json`

## Findings triage

| Slither detector | Status | Triage |
|---|---|---|
| `reentrancy-eth` | Fixed | `FeeCollector.buybackAndBurn` now writes `lastBuybackAt` before the external Sushi router call. Function remains `nonReentrant`. |
| `reentrancy-balance` | False-positive / accepted with guard | Public mint entrypoints are `nonReentrant`; `BoxToken.mint` is engine-only and non-callback ERC20; router/adapter calls are required for zap minting. Remaining stale-balance warning is from intentional balance-delta accounting after swaps. |
| `reentrancy-no-eth` | False-positive / accepted with guard | Redeem and claim public entrypoints are `nonReentrant`. Pending-claim writes after caught transfer failures are intentional so paused components do not brick redemption. |
| `reentrancy-events` | False-positive | Events emitted after registry/vault calls do not protect state. `createBox` state is written before optional registry registration; `rescueToken` is admin-only and component assets are unsweepable in `BoxVault`. |
| `arbitrary-send-eth` | False-positive / intended behavior | `FeeCollector.buybackAndBurn` sends ETH only to configured Sushi router and BENTO output to `DEAD`; `UniswapV4Adapter.swapTokenToETH` sends ETH to caller-supplied recipient by interface design. Added zero-recipient check and `nonReentrant` to adapter swaps. |
| `low-level-calls` | Accepted | Native ETH sends use `.call` to support contract recipients. Return values are checked and revert on failure. |
| `timestamp` | Accepted | Feed staleness and buyback rate-limit windows necessarily use `block.timestamp`; small validator skew does not change security assumptions. |
| `divide-before-multiply` | Accepted | Affects display/quote/sanity math precision. All formulas use 1e18 normalization and conservative bps comparisons; not value extraction. |
| `incorrect-equality` | False-positive | Zero-amount/feed checks are guard clauses, not price/authorization equality assumptions. |
| `uninitialized-local` | False-positive | Solidity initializes local `uint256` accumulators to zero. |
| `unused-return` | Accepted | Router/adapter return values are intentionally ignored where vault balance deltas are the source of truth. Feed tuple fields not used are intentionally discarded. |
| `missing-zero-check` | Partially accepted | Some addresses are intentionally allowed to be zero in local tests or optional config (`registry`, `feeCollector`, `bento`, `ethUsdFeed`). New Phase 1D validation forbids adapter routes unless `feed != 0` and `ethUsdFeed != 0`. Adapter swap recipients now reject zero. |
| `calls-loop` | Accepted | Basket operations necessarily loop over bounded component arrays; MAG7 has 7 components and launch caps bound gas/value risk. |
| `pragma` | False-positive | Project contracts pin `^0.8.24`; additional pragmas come from OpenZeppelin dependencies. |
| `cyclomatic-complexity` | Accepted | `_mintBox` complexity comes from V2 vs adapter route support plus sanity/cap checks. Refactor deferred to avoid behavior changes in hardening pass. |
| `missing-inheritance` | False-positive | Interfaces are lightweight internal call-shape interfaces; concrete contracts intentionally do not inherit them. |
| `naming-convention` | False-positive | `WETH()` matches external router interface naming. |
| `cache-array-length` | Low / accepted | Discount-tier loop is expected to be tiny/admin configured; optimization not security-relevant. |
| `immutable-states` | Accepted | `FeeCollector.bento` remains mutable for deployment wiring/config flexibility; admin is timelocked in production deployment. |

## Manual hardening notes

- `createBox` and `setComponentRoute` reject adapter sentinel routes unless the component has a stock/USD feed and the engine has ETH/USD configured.
- `FeedStale` now includes `age` for frontend display: `FeedStale(feed, updatedAt, age)`.
- `UniswapV4Adapter` route ownership flow is deployer-set routes first, then `transferOwnership(timelock)`.
- `DeploySafe.s.sol` is standalone and only deploys a 2-of-3 Safe; it is not part of protocol deployment.

## Phase 1E Slither delta

Command re-run after BENTO taxed-pair token work:

```text
uvx --from slither-analyzer slither . --exclude-dependencies --filter-paths 'test/|script/' --json slither-report.json
slither_exit=255 because findings were reported.
```

Detector categories were unchanged from the Phase 1D triage. The only new BENTO-specific line was:

```text
BentoToken._update(address,address,uint256).fee is a local variable never initialized
```

Triage: false-positive. Solidity initializes local `uint256 fee` to zero; the code only assigns a nonzero value when both transfer sides are nonzero, a configured taxed pair is involved, neither side is exempt, and `taxBps != 0`. Mint/burn and wallet-to-wallet transfers intentionally leave `fee == 0`.

Manual Phase 1E notes:

- BENTO remains fixed-supply only: constructor mints `1_000_000_000e18` once to deployer; there is no external mint/pause/owner selector.
- Buy/sell tax is pair-scoped only (`taxedPair[from] || taxedPair[to]`), max hardcapped at `MAX_TAX_BPS = 300`, and can be permanently disabled through `lockTaxForever()`.
- Tax is taken in BENTO via the standard `_update` path and sent to `devWallet`; there is no reflection, rebase, or swap-on-transfer logic.
- FeeCollector/DEAD exemption was unit-tested so protocol buyback-and-burn receives untaxed BENTO even when the BENTO/ETH pair is marked taxed.

## Phase 1 RC2 Slither/test delta

Applied the user-supplied `bento-rc2-patched-files.zip` over:

- `src/BoxEngine.sol`
- `src/FeeCollector.sol`
- `test/BoxEngine.t.sol`

Security-relevant RC2 changes:

- `reservedClaims[boxId][token]` tracks vault balances already owed to pending paused-component claimants.
- Redeem/NAV/quote paths use `_availableBalance(boxId, token, vault) = balanceOf(vault) - reservedClaims[boxId][token]` so later redeemers cannot double-count tokens left in the vault for earlier pending claims.
- `claimPending` decrements `reservedClaims` before transfer and restores it on failed claim payment.
- `FeeCollector.buybackAndBurn` is now `onlyKeeper`, matching `redeemFeeBoxes` keeper-gating.
- Added `testPendingClaimsDoNotDoubleCountForLaterRedeemers()` regression.

Verification after RC2:

```text
forge fmt --check && forge build && forge test -vv && forge snapshot
25 tests passed, 0 failed, 0 skipped

RUN_LIVE_FORK=true ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract 'RobinhoodV4(Adapter|EngineLifecycle)ForkTest|DeploySafeForkTest' -vv
5 tests passed, 0 failed, 0 skipped
```

Slither was rerun after RC2. Detector categories were unchanged from prior triage. New/shifted reserved-claim arithmetic is covered by the regression proving total promised paused claims remain covered by vault balance and are fully payable after unpause.

## Phase 1F Slippage Hardening delta

Implemented per-component slippage protection without fee/BENTO/FeeCollector changes:

- Added per-component minimum overloads:
  - `mint(boxId, minBoxOut, recipient, minComponentOut)`
  - `mint(boxId, minBoxOut, minComponentOut)`
  - `redeemForETH(boxId, boxIn, minEthOut, minComponentEthOut, to)`
- Existing mint/redeem overloads remain and pass empty minimum arrays, preserving backward-compatible zero-min behavior.
- Mint now validates the min array length, passes each component minimum into V2/adapter swap calls, and verifies observed vault balance delta is at least the requested component minimum.
- `redeemForETH` now validates per-leg ETH minimum array length, passes each minimum into `vaultSwapTokenForETH`, and reverts `Slippage` on a bad minimumed leg instead of silently recording a claim for slippage failure.
- `vaultSwapTokenForETH` now returns the leg ETH output and passes nonzero `minOut` to V2 router/adapter swaps.
- Genesis mint pricing now uses `_feed1e18Fresh(ethUsdFeed)` so first mint cannot price from a stale ETH/USD answer.

New regression tests:

- `testMintPerComponentMinOutRevertsBadLegAndLength()`
- `testRedeemForETHPerComponentMinOutRevertsBadLegAndLength()`
- `testBackwardCompatibleMintAndRedeemOverloadsStillWork()`
- `testGenesisMintUsesFreshEthUsdFeed()`

Verification after Phase 1F:

```text
forge fmt --check && forge build && forge test -vv && forge snapshot
29 tests passed, 0 failed, 0 skipped

RUN_LIVE_FORK=true ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract 'RobinhoodV4(Adapter|EngineLifecycle)ForkTest|DeploySafeForkTest' -vv
5 tests passed, 0 failed, 0 skipped
```

Slither was rerun after Phase 1F. Detector categories remained unchanged from prior triage. No new min-array/slippage-specific detector category appeared.

## Phase 1G Deploy Runbook delta

Ops-only additions; no production contract logic was changed:

- Added `script/Phase1GDeploy.s.sol` to deploy/reuse base stack addresses, configure deployer-owned adapter routes, transfer adapter ownership to timelock, assert immutable admin/config values, log addresses, and write Safe→Timelock calldata files under `out/phase1g-*.calldata.txt`.
- Added `script/Phase1GSmoke.s.sol` to perform post-deploy 0.01 ETH mint → immediate redeemForETH using per-component min arrays and assert round trip under 200 bps.
- Added `test/Phase1GDeployFork.t.sol` to dry-run the full timelock deploy/config/readback/smoke flow on a Robinhood live fork.
- Added `DEPLOY.md` with immutable-admin constraints, Safe/Timelock sequence, verification reads, smoke procedure, pause/rollback, cap lowering, and paused-stock claims process.

Security note: `BoxEngine.admin`, `FeeCollector.admin`, and `BentoToken.admin` are immutable, so the runbook deploys those contracts with `admin = timelock` from construction and performs setup actions through Safe→Timelock. It does not assume a non-existent post-deploy admin transfer.

Verification after Phase 1G:

```text
forge fmt --check && forge build && forge test -vv && forge snapshot
30 tests passed, 0 failed, 0 skipped

RUN_LIVE_FORK=true ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract 'Phase1GDeployForkTest|RobinhoodV4(Adapter|EngineLifecycle)ForkTest|DeploySafeForkTest' -vv
6 tests passed, 0 failed, 0 skipped
```

Slither was rerun after Phase 1G. Detector categories remained unchanged from prior triage; script/test additions are excluded by the standard `--filter-paths 'test/|script/'` run.
