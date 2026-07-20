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
