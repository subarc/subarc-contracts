# Security Policy

## Status

SubArc contracts are MVP/testnet contracts. They have internal tests and static
analysis checks, but no independent third-party audit yet.

Do not present this repository as production-ready until:

- Independent audit is complete.
- Factory owner is transferred to a multisig or timelock-controlled account.
- Deployment addresses are verified.
- Payment-token whitelist is limited to reviewed stablecoins.
- Hub, indexer, and contract ABIs are pinned to the same release commit.

## Current Safety Controls

- Factory-level global pause blocks service creation, tier purchases, and
  existing service subscribe/renew calls.
- Service-level pause blocks that service's subscribe/renew calls.
- Subscription and renewal calls require `expectedPrice`, `expectedInterval`,
  and `maxFeeBps`.
- Factory payment tokens are allowlisted.
- Fee-on-transfer payment tokens are rejected through balance-delta checks.
- Active paid tier licenses use a fee snapshot taken at purchase time.
- Reentrancy guards protect subscription payments, tier purchases, withdrawals,
  and token recovery.

## Reporting

For private vulnerability reports, contact the project maintainers directly
before publishing details. Include:

- Affected commit hash.
- A concise proof of concept.
- Impact and affected funds or permissions.
- Suggested remediation, if known.

