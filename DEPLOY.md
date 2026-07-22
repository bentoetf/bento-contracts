# DEPLOY.md — Bento Phase 1G Robinhood Mainnet Runbook

Phase 1G is operations-only. No Solidity contract logic changes are required for this runbook.

## Go / no-go checklist

Do **not** deploy real value until all are true:

- [ ] `v1.0.0-rc3` source hash matches the reviewed artifact.
- [ ] 2-of-3 Safe is deployed and all owners have tested signing.
- [ ] 24h `TimelockController` address is known or will be deployed by `Phase1GDeploy`.
- [ ] At least one experienced Solidity reviewer has reviewed RC3.
- [ ] Deployer wallet has enough ETH for deployment gas and the 0.01 ETH smoke.
- [ ] Dev wallet and LP seeding wallet are final.
- [ ] BENTO/ETH pool seeding plan is final; buyback will skip/fail until the pool exists.
- [ ] Launch caps remain small: MAG7 per-tx mint cap `2 ETH`, MAG7 TVL cap `15 ETH`.
- [ ] Current Chainlink feed freshness is acceptable. If stock feeds are stale outside market hours, wait for refresh rather than widening production `maxFeedAge` casually.

## Immutable-admin deployment constraint

`BoxEngine.admin`, `FeeCollector.admin`, and `BentoToken.admin` are immutable constructor values. Therefore the safe deployment path is:

1. Deploy the Timelock first.
2. Deploy immutable-admin contracts with `admin = timelock`.
3. Execute admin actions through Safe → Timelock after the delay.

There is no “deploy with EOA then transfer admin later” path without changing contracts. `BoxRegistry.owner` is also immutable, but its only owner action is one-time `setRegistrar(engine)`. The deploy script sets the registrar immediately; after that, registry owner has no remaining registry mutation path.

## Environment

```bash
export PATH="$HOME/.foundry/bin:$PATH"
export RPC_URL=https://rpc.mainnet.chain.robinhood.com
export PRIVATE_KEY=...                 # deployer EOA; never commit
export SAFE_ADDRESS=0x...              # 2-of-3 Safe
export DEV_WALLET=0x...                # BENTO buy/sell tax recipient
export LP_SEEDING_WALLET=0x...         # wallet that seeds/locks/burns launch LP
```

Optional idempotency/resume vars if something was already deployed:

```bash
export TIMELOCK_ADDRESS=0x...
export BENTO_ADDRESS=0x...
export FEE_COLLECTOR_ADDRESS=0x...
export BOX_REGISTRY_ADDRESS=0x...
export V4_ADAPTER_ADDRESS=0x...
export BOX_ENGINE_ADDRESS=0x...
export ETH_USD_FEED=0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9
```

## Canonical Robinhood addresses used

| Item | Address |
|---|---|
| Chain ID | `4663` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Sushi V2 router | `0x9A55D3d0c0f09859c7869510f53eD0a30B340766` |
| Uniswap V4 UniversalRouter | `0x8876789976dEcBfCbBbe364623C63652db8C0904` |
| Uniswap V4 Quoter | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| ETH/USD feed | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` |

MAG7 stocks and feeds:

| Component | Token | Feed |
|---|---|---|
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` |
| AAPL | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` |
| MSFT | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` |
| GOOGL | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` | `0xF6f373a037c30F0e5010d854385cA89185AE638b` |
| AMZN | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` | `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C` |
| META | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` | `0x7C38C00C30BEe9378381E7B6135d7283356D71b1` |
| TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | `0x4A1166a659A55625345e9515b32adECea5547C38` |

MAG7 weights: six components at `1428` bps, TSLA at `1432` bps.

## Step 0 — local verification

```bash
forge fmt --check
forge build
forge test -vv
forge snapshot
```

Expected RC3 baseline after Phase 1G test addition:

```text
30 tests passed, 0 failed, 0 skipped
```

## Step 1 — deploy base stack and write timelock calldata

Dry-run/simulate first:

```bash
forge script script/Phase1GDeploy.s.sol:Phase1GDeploy \
  --rpc-url "$RPC_URL" \
  --sender "$(cast wallet address --private-key "$PRIVATE_KEY")" \
  -vvvv
```

Broadcast only after dry-run looks correct:

```bash
forge script script/Phase1GDeploy.s.sol:Phase1GDeploy \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api/ \
  -vvvv
```

The script deploys or reuses env-provided addresses for:

1. `TimelockController(24h, proposer=Safe, executor=Safe, admin=Safe)`
2. `BentoToken(deployer, timelock, devWallet)`
3. `FeeCollector(timelock, 0, bento, SushiRouter, [WETH, BENTO])`
4. `BoxRegistry(deployer)` and one-time `setRegistrar(engine)`
5. `UniswapV4Adapter(UniversalRouter, Quoter, Permit2, USDG, deployer)`
6. `BoxEngine(timelock, registry, collector, bento, ETH/USD)`
7. Adapter MAG7 USDG routes, then `adapter.transferOwnership(timelock)`

It logs every deployed address and writes Safe→Timelock calldata under `out/phase1g-*.calldata.txt`.

## Step 2 — Safe → Timelock operations

Submit each calldata file through the Safe to the Timelock with `delay = 24 hours`, then execute after the delay.

Required operations, in order:

1. `FeeCollector.setEngine(engine)`
2. `BentoToken.setTaxExempt(engine, true)`
3. `BentoToken.setTaxExempt(feeCollector, true)`
4. `BentoToken.setTaxExempt(DEAD, true)`
5. `BentoToken.setTaxExempt(lpSeedingWallet, true)`
6. `BoxEngine.createBox(MAG7 Bento Box, MAG7, components, 30, 30, 15 ether, "")`
7. `BoxEngine.setPerTxMintCap(1, 2 ether)`

After `createBox`, read:

```bash
cast call $BOX_ENGINE_ADDRESS 'boxes(uint256)(address,address,uint16,uint16,uint128,bool,bool,string)' 1 --rpc-url "$RPC_URL"
```

Then replace the placeholder address in:

```text
out/phase1g-template-bento-exemptVault-PLACEHOLDER.calldata.txt
```

with the returned vault address and execute `BentoToken.setTaxExempt(vault, true)` through the timelock.

After BENTO/ETH LP is created, replace the placeholder address in:

```text
out/phase1g-template-bento-setTaxedPair-PLACEHOLDER.calldata.txt
```

with the actual BENTO/ETH pair/pool and execute `BentoToken.setTaxedPair(pair, true)` through the timelock.

## Step 3 — on-chain verification pass

Read and verify:

```bash
cast call $BENTO_ADDRESS 'admin()(address)' --rpc-url "$RPC_URL"
cast call $BENTO_ADDRESS 'taxBps()(uint16)' --rpc-url "$RPC_URL"
cast call $BENTO_ADDRESS 'MAX_TAX_BPS()(uint16)' --rpc-url "$RPC_URL"
cast call $BENTO_ADDRESS 'devWallet()(address)' --rpc-url "$RPC_URL"
cast call $FEE_COLLECTOR_ADDRESS 'admin()(address)' --rpc-url "$RPC_URL"
cast call $FEE_COLLECTOR_ADDRESS 'engine()(address)' --rpc-url "$RPC_URL"
cast call $BOX_ENGINE_ADDRESS 'admin()(address)' --rpc-url "$RPC_URL"
cast call $BOX_ENGINE_ADDRESS 'feeCollector()(address)' --rpc-url "$RPC_URL"
cast call $BOX_ENGINE_ADDRESS 'bento()(address)' --rpc-url "$RPC_URL"
cast call $BOX_ENGINE_ADDRESS 'ethUsdFeed()(address)' --rpc-url "$RPC_URL"
cast call $BOX_ENGINE_ADDRESS 'perTxMintCapWei(uint256)(uint128)' 1 --rpc-url "$RPC_URL"
cast call $BOX_REGISTRY_ADDRESS 'engineOf(uint256)(address)' 1 --rpc-url "$RPC_URL"
cast call $BOX_ENGINE_ADDRESS 'boxes(uint256)(address,address,uint16,uint16,uint128,bool,bool,string)' 1 --rpc-url "$RPC_URL"
```

Expected:

- BENTO/FeeCollector/Engine admin = Timelock.
- BENTO tax = `300`, max tax = `300`.
- Box exists = `true`.
- Mint fee = `30`, redeem fee = `30`.
- TVL cap = `15000000000000000000`.
- Per-tx mint cap = `2000000000000000000`.
- Registry `engineOf(1) = BoxEngine`.
- Component routes use adapter sentinel path `[address(0), stock]` and each stock feed matches the table above.

## Step 4 — smoke test

Run only after all timelock operations are executed and BENTO/vault exemptions are set.

```bash
export BOX_ID=1
forge script script/Phase1GSmoke.s.sol:Phase1GSmoke \
  --rpc-url "$RPC_URL" \
  --broadcast \
  -vvvv
```

Smoke behavior:

- Quotes all 7 mint legs through the adapter.
- Applies 2% per-leg tolerance.
- Mints `0.01 ETH` into MAG7 using per-component mins.
- Quotes all redeem legs.
- Redeems 100% immediately using per-component ETH mins.
- Asserts round-trip loss is under `200 bps`.

If it fails with `FeedStale`, do **not** widen production feed age as a reflex. Wait for stock feeds to update unless the Safe intentionally decides to loosen `maxFeedAge` temporarily.

## Pause / rollback procedures

### Global mint pause

Who can pause: Timelock admin via Safe proposal/execution.

Calldata:

```bash
cast calldata 'setGlobalMintPaused(bool)' true
```

Submit Safe → Timelock targeting `BOX_ENGINE_ADDRESS`. After delay/execute:

```bash
cast call $BOX_ENGINE_ADDRESS 'globalMintPaused()(bool)' --rpc-url "$RPC_URL"
```

Redeem paths are intentionally not pausable.

### Per-box mint pause

```bash
cast calldata 'setMintPaused(uint256,bool)' 1 true
```

Use when only MAG7 minting should stop while other future boxes remain unaffected.

### Lower launch caps

```bash
cast calldata 'setPerTxMintCap(uint256,uint128)' 1 100000000000000000  # 0.1 ETH
cast calldata 'setTvlCap(uint256,uint128)' 1 1000000000000000000       # 1 ETH
```

### Disable BENTO tax forever

Only for the future community disable moment:

```bash
cast calldata 'lockTaxForever()'
```

This is irreversible and sets `taxBps = 0` permanently.

### Stock halt / paused stock claims

If a stock token pauses or blocks transfers:

- `redeemForStocks` does not revert wholesale.
- Transferable components are paid immediately.
- The paused component amount is recorded in `pendingClaims(boxId, user, token)`.
- `reservedClaims(boxId, token)` keeps those vault tokens out of later NAV/redeem availability.
- When the stock unpauses, the user calls:

```bash
cast send $BOX_ENGINE_ADDRESS 'claimPending(uint256,address,address)' 1 <STOCK_TOKEN> <USER_TO> \
  --rpc-url "$RPC_URL" --private-key <USER_KEY>
```

`redeemForETH` also records stock claims for paused transfer/swap components when no per-leg min was requested. If a per-leg min was requested and a swap leg fails, it reverts `Slippage` instead of silently treating that as a stock halt.

## Rollback mindset

Contracts are immutable/no-upgrade. Rollback means:

1. Pause mint globally.
2. Keep redemptions open.
3. Lower caps if needed.
4. Communicate the issue and whether claims are expected.
5. Deploy a new engine/adapter version only after a new review cycle.
6. Use `BoxRegistry` to map future box IDs to a new engine; existing box tokens/vaults stay on the original engine.

## Live fork dry-run output

Command:

```bash
RUN_LIVE_FORK=true ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Phase1GDeployForkTest -vv
```

Result:

```text
Ran 1 test for test/Phase1GDeployFork.t.sol:Phase1GDeployForkTest
[PASS] testPhase1GDeployVerifyAndSmoke() (gas: 20464160)
Logs:
  Phase1G timelock 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
  Phase1G bento 0x2e234DAe75C793f67A35089C9d99245E1C58470b
  Phase1G feeCollector 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
  Phase1G registry 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9
  Phase1G adapter 0xc7183455a4C133Ae270771860664b6B7ec320bB1
  Phase1G engine 0xa0Cb889707d426A7A386870A03bc70d1b0697598
  Phase1G MAG7 boxToken 0x83B4EEa426B7328eB3bE89cDb558F18BAF6A2Bf7
  Phase1G MAG7 vault 0xf5Ba21691a8bC011B7b430854B41d5be0B78b938
  Phase1G smoke ethOut 9871443232081500
  Phase1G smoke bps 128

Suite result: ok. 1 passed; 0 failed; 0 skipped
```

Note: the fork harness temporarily sets `maxFeedAge = 14 days` through the timelock because the current live fork feed timestamp for NVDA was stale by ~9.8 days. Production should keep the 24h default unless the Safe intentionally changes it.
