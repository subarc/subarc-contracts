# SubArc Security Notes

These notes describe the frozen Arc testnet MVP security posture.

## Subscriber Agreed Terms

Subscribers pass:

- `planId`
- `expectedPrice`
- `expectedInterval`
- `maxFeeBps`

This protects them from silent same-block changes to plan price, interval, or platform fee expectations.

## Mutable Plan Safety

Renewals use stored subscriber-agreed terms:

- agreed price
- agreed interval
- max fee cap

That means later plan edits do not silently change an existing subscriber's renewal price or interval.

## USDC-Only MVP

Factory service creation is restricted to the configured Arc payment token for the MVP.

This keeps the demo focused on recurring USDC billing and avoids broader token-surface risk.

## No Relayer Custody

The relayer never custodies user funds.

It only calls:

```solidity
renew(user)
```

The subscription contract itself performs the token `transferFrom`.

## Factory Pause and Service Pause

- factory pause blocks new service creation, subscribe, and renew flows
- service pause blocks subscribe and renew for that service

## Cancel Always Allowed

Cancellation remains callable even while the factory or service is paused.

This is an intentional user-protection rule in the MVP.

## Renewal Grace Period

Renewals are allowed only after expiry and only within the configured grace period.

For the contract MVP, the grace window is `7 days`.

## Ownership Source Of Truth

Authorization must use the live `owner()` value on the service contract.

Indexing helpers such as service ownership lists may become stale after ownership transfers.

## Gateway Out Of Contracts

Circle Gateway is not implemented in the contracts.

It remains a future frontend/backend funding and onboarding layer only.

## Audit / Production Status

This repository is prepared for Arc testnet MVP demos.

It is not presented as:

- mainnet audited
- production-ready recurring billing infrastructure
- a final operational security model
