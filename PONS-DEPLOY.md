# PONS-DEPLOY.md — Bento launch with pons.family BENTO

Supersedes parts of DEPLOY.md for the pons-launch path. BENTO is launched on
pons.family (active factory 0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB, 70/30
creator split) instead of deploying BentoToken. No tax mechanics exist; creator
revenue = pons fee share. Box mint/redeem fees still fund buyback-and-burn.

## Order of operations (single day)

1. **Pons launch (creator).** Launch BENTO on pons. Creator initial buy on the
   launch block = team supply allocation. Record the token address (CA).
2. **Verify CA (reviewer).** Plain ERC20, 18 decimals, 1e9 supply, no owner,
   bytecode matches other pons-factory tokens. The deploy script re-checks
   decimals/supply on-chain and reverts otherwise.
3. **Deploy** with the pons CA:

```bash
export RPC_URL=https://rpc.mainnet.chain.robinhood.com
export PRIVATE_KEY=***
export SAFE_ADDRESS=0x...
export BENTO_ADDRESS=0x...   # pons CA
# TIMELOCK_INITIAL_DELAY defaults to 0 (bootstrap mode)

forge script script/PonsDeploy.s.sol:PonsDeploy --rpc-url "$RPC_URL" -vvvv          # dry run
forge script script/PonsDeploy.s.sol:PonsDeploy --rpc-url "$RPC_URL" --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ -vvvv
```

4. **Safe ops, immediately (delay 0), strictly in order:**
   1. `out/pons-01-feeCollector-setEngine.calldata.txt`
   2. `out/pons-02-engine-createMag7.calldata.txt`
   3. `out/pons-03-engine-setMag7PerTxCap.calldata.txt`
   4. `out/pons-04-LAST-timelock-updateDelay-24h.calldata.txt` — **must be last**
5. **Gate before any public launch:** `cast call $TIMELOCK 'getMinDelay()(uint256)'`
   must return `86400`. Docs must state the delay was raised to 24h at launch.
6. **Smoke:** 0.01 ETH mint + immediate redeemForETH, expect ~130 bps round trip.
7. **Web:** paste addresses into Vercel env, redeploy.

## Buyback bridge pool (post-launch, non-blocking)

Pons pools are Uniswap V3; FeeCollector buyback routes Sushi V2 [WETH, BENTO].
Buyback no-ops until a Sushi V2 BENTO/WETH pair exists. Seed a small pair
(0.05–0.1 ETH + equal-value BENTO at the live pons price); arbitrage keeps it
aligned. Fees accumulate in the collector until then; nothing is lost.

## What changed vs DEPLOY.md

- No BentoToken deploy; BENTO_ADDRESS is required input.
- No tax ops (setTaxExempt / setTaxedPair) — the pons token has no tax.
- 7 timelock ops become 3 + the final updateDelay(24h).
- DEV_WALLET / LP_SEEDING_WALLET env vars are no longer used by the script.
- Timelock bootstrap: initial delay 0, raised to 24h as the final op.

Fork test: `forge test --match-contract PonsDeployForkTest` (uses a real
pons-factory token as the BENTO stand-in; asserts bootstrap, delay raise,
post-raise ops require 24h, and a mint/redeem smoke under 300 bps).

## Post-deploy: USDG zapper (optional, non-blocking)

After the core is live, deploy `src/periphery/USDGZapper.sol` so users can mint
boxes directly from USDG (6 decimals) without holding ETH:

```bash
forge create src/periphery/USDGZapper.sol:USDGZapper --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ \
  --constructor-args 0x8876789976dEcBfCbBbe364623C63652db8C0904 0x000000000022D473030F116dDEE9F6B43aC78BA3 \
  $BOX_ENGINE_ADDRESS 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 460 9
```

Standalone and immutable: no admin, no owner, no timelock ops. Swaps USDG to
ETH through the V4 ETH/USDG 460/9 pool and calls `engine.mint` in one tx.
Fork test: `forge test --match-contract USDGZapperForkTest` (100 USDG in,
~0.9933 MAG7 out, ~67 bps all-in). Frontend gets NEXT_PUBLIC_USDG_ZAPPER_ADDRESS
once deployed.

## Post-launch playbook (week 1-3)

### Sushi V2 BENTO/WETH bridge pool (enables burns)
Seed once, any time after launch: BENTO + ETH at the live pons pool price
(0.05-0.1 ETH side is enough; buyback flow is a trickle and arb keeps price
aligned). Compute exact amounts from the pons pool at seeding time.

### MAG7/USDG spot pool (one-click buy + chart)
Optional marketing pool: LP MAG7 against USDG on any DEX. Mint/redeem arb pins
pool price to NAV (above NAV: mint ~60bps and sell; below: buy and redeem), so
IL is low relative to volatile pairs. Small seed (~$500-1k each side) is fine.

### BoxNavOracle + Morpho market (boxes as collateral)
`src/periphery/BoxNavOracle.sol` is a Chainlink AggregatorV3-compatible feed
reporting box NAV in USD (8 decimals), computed live from the engine. Deploy
with `--constructor-args $BOX_ENGINE_ADDRESS 1` (boxId). Reverts when any
component feed is stale (safe failure mode for lending). Fork test:
`forge test --match-contract BoxNavOracleForkTest`.

Arrow Finance runs a Morpho deployment on Robinhood chain (0 markets as of
2026-07-20). Morpho market creation is permissionless: collateral MAG7, loan
USDG, oracle BoxNavOracle, conservative LLTV (62.5% suggested for a basket of
equities). Do not promote borrowing size pre-audit.

### AI box (box #2) — liquidity reality check (probed 2026-07-20)
Feeds exist for all AI names (NVDA, AMD, TSM, MU, PLTR, ORCL, CRWV, all live
and fresh). Pools are the constraint: only NVDA (USDG fee=3000), AMD and MU
(USDG fee=10000) have functional V4 USDG liquidity. TSM/PLTR/ORCL/CRWV pools
are dust or mispriced vs feed (SanityDeviation reverts, which is the engine
doing its job). Options:
- Ship "AI3" now: NVDA/AMD/MU equal-weight, works today (fork test
  `AIBoxForkTest`: mint+redeem round trip ~220bps at 0.02 ETH size).
- Wait for depth on the other names and ship AI7 later.
- Route additions and createBox go through the timelock post-launch (24h
  delay), so announce-then-ship.
Re-probe pools with `forge test --match-contract AIPoolProbeForkTest -vv`
before deciding.
