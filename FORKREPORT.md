# Bento Robinhood Fork Report

Phase 1B update: Uniswap V4 adapter spike + route map.

RPC used by Foundry: `http://127.0.0.1:8547`
Upstream RPC target for local proxy runs: `https://rpc.mainnet.chain.robinhood.com`

## Canonical V4 infrastructure

| Component | Address | Verification |
|---|---:|---|
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | Verified `PoolManager`; known NVDA/ETH pool id resolves in StateView; UniversalRouter.poolManager points here. |
| UniversalRouter | `0x8876789976dEcBfCbBbe364623C63652db8C0904` | Verified `UniversalRouter`; constructor args include this PoolManager and Permit2. |
| StateView | `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` | Verified `StateView`; `poolManager()` returns canonical PoolManager; `getSlot0/getLiquidity` work for known pool ids. |
| V4Quoter used | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` | Verified v4-periphery `V4Quoter`; `poolManager()` returns canonical PoolManager; 2-output quote ABI. |
| Alt V4Quoters also pointing to same PoolManager | `0x628c00B016415Ef530552063faE4154B0CdEb0Ac`, `0x97627e46420bbc4bc5Df7e72D6Bb653345506b2f` | Verified but not selected for adapter tests. |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | From UniversalRouter constructor args. |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | Blockscout token search: Global Dollar. |

Official Uniswap deployment-registry spot check: the common GitHub deployment paths checked during the spike did not expose a Robinhood-chain entry; canonical selection above is therefore based on Blockscout metadata tags + verified constructor wiring + live pool/state/quote behavior.

## Raw fork swap proof

Adapter uses UniversalRouter command `0x10` (`V4_SWAP`) with actions `SWAP_EXACT_IN` / `SETTLE_ALL` / `TAKE_ALL`. Reverse ERC20->ETH uses Permit2 approval because UniversalRouter V4 payments call Permit2 when payer is the external caller.

| Proof | ETH in | Token out | ETH back | Round-trip cost |
|---|---:|---:|---:|---:|
| NVDA via ETH→USDG→NVDA adapter | 0.1 ETH | 0.915156809750460177 NVDA | 0.099309521188843941 ETH | 69 bps |

All-MAG7 adapter round trip at 0.01 ETH each also passed on fork; each path returned ~69 bps round-trip cost.

## V4 route map

Best shared ETH→USDG hop: pool `0x54f7883914619af9105355bf83ed678bcf9f63560218ac61c9963b9503d0ba32` fee `460`, tickSpacing `9`, liquidity `133842737497196473`. Quotes below are for exact `0.1 ETH` input via V4Quoter.

| Symbol | Best route | Stock pool id | Stock fee/tick | Liquidity | Quote for 0.1 ETH | Max single-stock mint (<1% impact) |
|---|---|---:|---:|---:|---:|---:|
| NVDA | ETH→USDG→NVDA | `0x3bb34a44f1b2b5f32c034c38a53065a521a47b199700fa9bd19d60985ff24bf1` | 3000/60 | 132774627776391128 | 0.915578574 NVDA | 7.055 ETH |
| AAPL | ETH→USDG→AAPL | `0xc748f4671a867db48b552f6b7650bf3255e05f80f00e3f7aad1b17ccb7898fdb` | 3000/60 | 24951759630691606 | 0.556996530 AAPL | 2.291 ETH |
| MSFT | ETH→USDG→MSFT | `0x9194a557b6a6bb2236b49ea7e2bbccec5d3eeb705aef00903be4b3de1d949579` | 3000/60 | 3515917557722893 | 0.466972232 MSFT | 0.377 ETH |
| GOOGL | ETH→USDG→GOOGL | `0xd4ecb79fdc521d7725d22b33ed43cb4e47aa96bfad76aa29577e3151f723ac5e` | 3000/60 | 36261934492732241 | 0.535837641 GOOGL | 3.186 ETH |
| AMZN | ETH→USDG→AMZN | `0xd32646872e6712af8cf778e34b6bbef1d2ae0bddd83764e1b07333518ad59333` | 3000/60 | 11013555773481526 | 0.750809300 AMZN | 0.909 ETH |
| META | ETH→USDG→META | `0x5875d407a42965b0e768c8925cea290e06fa50603ef34fc99eb92a1050e6ae36` | 3000/60 | 3396494512853288 | 0.289155371 META | 0.461 ETH |
| TSLA | ETH→USDG→TSLA | `0x8517f8071ae5b831b738052f12125e8e3d6c158b78728aa44ce3b25e5104d32e` | 3000/60 | 10458989648882694 | 0.486207244 TSLA | 1.018 ETH |

Conclusion: USDG multihop is best for all seven MAG7 names at 0.1 ETH in this fork pass. Keep the adapter route-configurable because direct pools exist and can become preferable as liquidity changes.

## Feeds / TRV / rebase resolution

| Feed | Proxy | Fork answer | Decimals |
|---|---:|---:|---:|
| NVDA | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` | 202.79625 | 8 |
| AAPL | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` | 334.07 | 8 |
| MSFT | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` | 393.5852 | 8 |
| GOOGL | `0xF6f373a037c30F0e5010d854385cA89185AE638b` | 346.615 | 8 |
| AMZN | `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C` | 247.005 | 8 |
| META | `0x7C38C00C30BEe9378381E7B6135d7283356D71b1` | 641.4115 | 8 |
| TSLA | `0x4A1166a659A55625345e9515b32adECea5547C38` | 381.468 | 8 |
| ETH/USD | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | 1863.2953 | 8 |

Stock source and fork reads settle the TRV question:

- `ERC20ScaledUIUpgradeable.balanceOfUI(account) = balanceOf(account) * uiMultiplier() / 1e18`.
- `totalSupplyUI() = totalSupply() * uiMultiplier() / 1e18`.
- Fork reads showed all current MAG7 `uiMultiplier()` values are `1e18`, so raw and UI amounts currently match.
- The Chainlink feed answer is the USD price per **UI share**. It does **not** separately include a future stock-token `uiMultiplier` in the raw ERC20 amount.

Exact NAV formula:

```text
uiBalance = stock.balanceOf(vault) * stock.uiMultiplier() / 1e18
componentUsd = uiBalance * feedAnswer / 10**feedDecimals / 10**stockDecimals
navUsdPerBox = sum(componentUsd) / boxToken.totalSupply()
```

Equivalent implementation-safe formula in 1e18 math:

```text
componentUsd1e18 = rawBalance * uiMultiplier / 1e18 * feedAnswer * 1e18 / 10**feedDecimals / 10**stockDecimals
```

Do not multiply by `uiMultiplier` if using `balanceOfUI()`. Do multiply raw `balanceOf()` by `uiMultiplier` for display NAV and any feed sanity comparison. Pool spot prices/quotes are in raw ERC20 units, so compare raw-token pool price against `feedAnswer * uiMultiplier / 1e18`.

## Legacy V2 finding retained

Sushi V2 direct WETH routes for MAG7 remain absent. The V2-only engine should not be deployed for MAG7 minting until adapter integration is scoped and implemented.

## Phase 1B engine adapter integration update

Implemented after the V4 spike:

- `BoxEngine` now wires the feed-vs-execution sanity bound during mint.
  - For each component with `feed != 0`, execution is compared in **raw token units** against `feedAnswer * uiMultiplier() / 1e18`, converted through ETH/USD.
  - Default `sanityBps = 300`.
  - Mint reverts with `SanityDeviation(token, actualRawPerEth, expectedRawPerEth)` when outside bound.
- Feed staleness is enforced on mint sanity checks through `maxFeedAge`, default `24 hours`, admin-settable with `MaxFeedAgeSet`.
  - Unit tests prove stale feeds revert mint.
  - `redeemForStocks` does not read feeds and remains unblocked by stale feeds.
  - Live fork note: Robinhood stock feeds were stale by more than 24h on the Sunday fork run; the gated full lifecycle fork test widens `maxFeedAge` to 72h to prove swap mechanics while preserving the production default at 24h.
- NAV/proof views added from the formula above:
  - `navUsdPerBox()` returns 1e18-scaled USD per full box token.
  - `backingDetailed()` returns raw balances, UI-adjusted balances, and component USD values.
  - Existing `backing()` remains the compact raw proof-of-reserves view for compatibility.
- Pending claims remain raw token amounts; no multiplier scaling is applied.
- Per-box per-tx mint caps added:
  - `perTxMintCapWei(boxId)` + `setPerTxMintCap(boxId, cap)`.
  - MAG7 deploy calldata defaults: `tvlCapWei = 15 ETH`, `perTxMintCap = 2 ETH`.
- Phase-1a fix confirmations now in tree:
  - Sanity bound is wired and tested.
  - `redeemFeeBoxes` now has keeper/admin gating and a `minEthOut` parameter.
  - `BoxRegistry` wiring fixed with `setRegistrar(engine)` and a unit test proving `engineOf(boxId)` registers.
  - `Deploy.s.sol` writes `out/createMag7.calldata.txt`, `out/setMag7PerTxMintCap.calldata.txt`, and one `out/setUSDGRoute-{i}.calldata.txt` per MAG7 token.
  - `Deploy.s.sol` uses canonical V4 UniversalRouter, V4Quoter, Permit2, USDG, real feed proxies, and USDG route sentinels for MAG7.

## Tests run

```text
forge test -vv
16 passed, 0 failed.

RUN_LIVE_FORK=true ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract 'RobinhoodV4(Adapter|EngineLifecycle)ForkTest' -vv
3 passed, 0 failed.

Adapter logs:
NVDA 0.1 ETH out: 0.915358697505146670 NVDA
NVDA round-trip ETH back: 0.099309516179117951 ETH
NVDA round-trip bps: 69
All 7 small adapter round trips passed at ~69 bps.

Full engine lifecycle logs:
MAG7 first mint box out: 9.288527070500000000
MAG7 second mint box out: 9.271347245131982866
MAG7 NAV USD per box: 99.492365195165846350
MAG7 redeemForETH out: 0.494033563353205376 ETH
MAG7 lifecycle net bps line item, excluding retained redeemed-for-stocks value: 5059 bps
buybackAndBurn skipped: no BENTO pool exists yet.
```

## Phase 1D hardening / launch-prep update

Implemented in the hardening pass:

- Adapter sentinel routes now validate at `createBox` and `setComponentRoute` time:
  - `path[0] == address(0)` requires component `feed != address(0)` and engine `ethUsdFeed != address(0)`.
  - Missing feed or missing ETH/USD reverts `BadRoute`.
- `FeedStale` is now frontend-displayable: `FeedStale(feed, updatedAt, age)`.
- `simulateMint(boxId, ethIn)` added for frontend `eth_call` simulation of adapter-routed mints using non-view adapter quoters.
- `Deploy.s.sol` now deploys the V4 adapter with the deployer, sets MAG7 USDG routes, writes route calldata files for future Safe/timelock route changes, then transfers adapter ownership to the timelock.
- `DeploySafe.s.sol` added as a standalone Safe deploy helper using canonical Robinhood SafeProxyFactory `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` and SafeL2 singleton `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`.
- Repo hygiene: `tmp_blockscout/` removed, `.gitignore` added, `forge fmt` run, `forge snapshot` added to CI.
- Static analysis: Slither run via `uvx`; findings triaged in `SECURITY-NOTES.md` with no silent dismissals.

Additional live fork results:

```text
RUN_LIVE_FORK=true ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract 'RobinhoodV4(Adapter|EngineLifecycle)ForkTest|DeploySafeForkTest' -vv
5 passed, 0 failed.

DeploySafe fork:
Predicted Safe: 0xBfD386cf7e1a167f1ccfb3e747c77f5925cB3243
Deployed Safe:  0xBfD386cf7e1a167f1ccfb3e747c77f5925cB3243

Clean immediate mint -> redeemForETH all-in round trip:
0.1 ETH in -> 0.098714619980093902 ETH out -> 128 bps
0.5 ETH in -> 0.493575500543615109 ETH out -> 128 bps
2.0 ETH in -> 1.974337362065177720 ETH out -> 128 bps
```

## No-go / scope reminders

- No BoxEngine mint/redeem refactor was done in this spike.
- No mainnet deployments were made.
- Fees and BentoToken were not touched.
