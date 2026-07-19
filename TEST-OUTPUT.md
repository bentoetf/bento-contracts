# Bento Phase 1G Test Output

## Phase 1G scope

Ops-only deploy runbook and scripts. No production contract logic changes.

Added:

- `script/Phase1GDeploy.s.sol`
  - Deploy/reuse Timelock, BentoToken, FeeCollector, BoxRegistry, UniswapV4Adapter, BoxEngine.
  - Set adapter MAG7 routes and transfer adapter ownership to timelock.
  - Set BoxRegistry registrar once.
  - Read back deploy-time config and assert admin/config values.
  - Log all addresses.
  - Write Safe→Timelock calldata files under `out/phase1g-*.calldata.txt`.
- `script/Phase1GSmoke.s.sol`
  - Post-deploy 0.01 ETH mint → immediate redeemForETH with per-component min arrays.
  - Asserts round trip under 200 bps.
- `test/Phase1GDeployFork.t.sol`
  - Live-fork dry-run of full immutable-admin/timelock deploy flow, MAG7 create/config readback, and smoke.
- `DEPLOY.md`
  - Mainnet runbook, verification reads, pause/rollback procedures, stock-halt claims process.

Important deploy constraint found and documented:

```text
BoxEngine.admin, FeeCollector.admin, and BentoToken.admin are immutable.
Therefore final admin must be timelock at construction; setup happens through Safe→Timelock.
There is no deploy-with-EOA-then-transfer-admin path without contract changes.
```

## Focused Phase 1G fork dry-run

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

Suite result: ok. 1 passed, 0 failed, 0 skipped
```

Note: the focused fork dry-run temporarily used `setMaxFeedAge(14 days)` through timelock because the current live fork NVDA feed timestamp was stale by ~9.8 days. `DEPLOY.md` says production should keep the 24h default unless the Safe intentionally decides otherwise.

## Full live fork acceptance

Command:

```bash
RUN_LIVE_FORK=true ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract 'Phase1GDeployForkTest|RobinhoodV4(Adapter|EngineLifecycle)ForkTest|DeploySafeForkTest' -vv
```

Result:

```text
Ran 4 test suites: 6 tests passed, 0 failed, 0 skipped
```

Key logs:

```text
DeploySafe:
Predicted Safe 0xBfD386cf7e1a167f1ccfb3e747c77f5925cB3243
Deployed Safe 0xBfD386cf7e1a167f1ccfb3e747c77f5925cB3243

Phase1G deploy/smoke:
Phase1G smoke ethOut 9871447438616212
Phase1G smoke bps 128

Immediate mint -> redeemForETH all-in:
0.1 ETH -> 0.098714614103053672 ETH, 128 bps
0.5 ETH -> 0.493575332341658622 ETH, 128 bps
2.0 ETH -> 1.974334706216175645 ETH, 128 bps
```

## Local full suite

Command:

```bash
forge fmt --check && forge build && forge test -vv && forge snapshot
```

Result:

```text
forge fmt --check: passed
forge build: compiler run successful (warnings only)
forge test -vv: 30 tests passed, 0 failed, 0 skipped
forge snapshot: 30 tests passed, 0 failed, 0 skipped; .gas-snapshot generated
```

## Static analysis

Command:

```bash
uvx --from slither-analyzer slither . --exclude-dependencies --filter-paths 'test/|script/' --json slither-report.json
```

Result:

```text
slither_exit=255 because findings were reported.
Detector categories unchanged from prior triage.
Scripts/tests are excluded by the standard Slither source filter.
Raw outputs: slither-output.txt and slither-report.json
```
