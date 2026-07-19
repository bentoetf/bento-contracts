# Contributing

Thanks for your interest in Bento Protocol contracts.

This repository is currently in release-candidate review mode. Contributions are welcome, but security-sensitive changes should be small, well-tested, and easy to review.

## Development workflow

1. Fork the repository.
2. Create a topic branch.
3. Install dependencies:

   ```bash
   git submodule update --init --recursive
   foundryup -v 1.7.1
   ```

4. Run checks before opening a pull request:

   ```bash
   forge fmt --check
   forge build
   forge test -vv
   forge snapshot
   ```

5. For changes affecting Robinhood routes, adapters, deploy scripts, or feed logic, also run the gated live fork tests:

   ```bash
   RUN_LIVE_FORK=true \
   ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
   forge test --match-contract 'Phase1GDeployForkTest|RobinhoodV4(Adapter|EngineLifecycle)ForkTest|DeploySafeForkTest' -vv
   ```

## Pull request expectations

- Explain the motivation and security impact.
- Include tests for contract logic changes.
- Do not commit private keys, `.env` files, broadcast artifacts, build outputs, local slither JSON, or RPC credentials.
- Do not widen launch caps, loosen feed staleness, or change admin assumptions without calling it out clearly.

## Reporting vulnerabilities

Please follow [SECURITY.md](./SECURITY.md) instead of opening a public issue with exploit details.
