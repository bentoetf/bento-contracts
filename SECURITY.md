# Security Policy

## Status

Bento Protocol Phase 1 contracts are currently unaudited release-candidate software. Do not treat this repository as audited production infrastructure.

## Reporting a vulnerability

Please use GitHub private vulnerability reporting for this repository when available:

1. Open the repository on GitHub.
2. Go to **Security → Advisories → Report a vulnerability**.
3. Include affected contract(s), impact, reproduction steps, and any proof-of-concept code.

If private vulnerability reporting is not enabled yet, contact the maintainers through the repository owner and avoid posting exploitable details in a public issue. Public issues are fine for non-sensitive hardening suggestions, documentation bugs, and test failures.

## Scope

In scope:

- Solidity contracts under `src/`
- Deployment/smoke scripts under `script/`
- Tests and fork harnesses under `test/`
- Documentation that could cause unsafe deployment or operation

Out of scope:

- Third-party dependencies under `lib/`
- Public Robinhood Chain, Chainlink, Uniswap, Sushi, Safe, or OpenZeppelin infrastructure
- Social engineering or physical attacks
- Attacks requiring leaked private keys or compromised admin signers

## Launch controls

The intended production deployment uses a 2-of-3 Safe behind a 24h timelock, small launch caps, per-component slippage checks, and unpausable redemptions. See [DEPLOY.md](./DEPLOY.md) and [RISKS.md](./RISKS.md).
