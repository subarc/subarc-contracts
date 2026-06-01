# SubArc MVP Integration Layer

This document covers the off-chain layer for the frozen Arc testnet MVP contracts:

- deployment
- verification
- relayer behavior
- indexer/dashboard data needs
- MVP demo flow

The contracts remain:

- `SubArcFactoryV1`
- `SubArcLogicV1`

No DAO, token, staking, governance, keeper network, or Gateway contract logic is added here.

## Arc Testnet Deployment

Primary deploy script:

```bash
npx hardhat run scripts/deploy-arc-testnet.js --network arcTestnet
```

The script deploys:

- `SubArcLogicV1`
- `SubArcFactoryV1`
- optional `MockUSDC` if `DEPLOY_MOCK_USDC=true`

It writes a machine-readable manifest to:

```bash
deployments/arcTestnet.latest.json
```

Checked-in template:

```bash
deployments/arcTestnet.example.json
```

The relayer and Arc demo scripts expect a real generated `arcTestnet.latest.json`, not the checked-in example.

By default the script assumes Arc-native USDC at:

```text
0x3600000000000000000000000000000000000000
```

If you want a fully isolated demo token instead, set:

```bash
DEPLOY_MOCK_USDC=true
```

## Verification

The Hardhat config is prewired for Arc testnet verification through the Arc explorer API.

Verify logic:

```bash
npx hardhat verify --network arcTestnet <LOGIC_ADDRESS>
```

Verify factory:

```bash
npx hardhat verify --network arcTestnet <FACTORY_ADDRESS> "<LOGIC_ADDRESS>" "<PAYMENT_TOKEN_ADDRESS>" "<PLATFORM_WALLET>"
```

Verify mock USDC if deployed:

```bash
npx hardhat verify --network arcTestnet <MOCK_USDC_ADDRESS> "Arc Test USDC" "USDC"
```

The deploy manifest also stores ready-to-run verification commands after a real deployment.

## Minimal Relayer Design

Goal:
- renew expired subscriptions during the renewal grace period
- never custody user funds
- only call `renew(user)` when renewal is actually due

Suggested service shape:

1. `listener`
- watches `ServiceCreated`, `PlanCreated`, `Subscribed`, `Renewed`, and `SubscriptionCancelled`
- maintains the list of known service clone addresses

2. `scheduler`
- tracks subscriber expiry timestamps per service
- marks subscriptions as `due` once `expiresAt <= now`
- drops subscriptions once `canceled=true`
- drops subscriptions after `expiresAt + RENEWAL_GRACE_PERIOD`

3. `executor`
- calls `renew(user)` against the service
- retries transient RPC failures
- records terminal failures such as low allowance, low balance, or fee cap exceeded

4. `state store`
- PostgreSQL or SQLite is enough for MVP
- one row per `(service, subscriber)`

Recommended subscription table fields:

- `service_address`
- `subscriber_address`
- `plan_id`
- `expires_at`
- `agreed_price`
- `agreed_interval`
- `max_fee_bps`
- `canceled`
- `next_action_at`
- `last_renew_attempt_at`
- `last_renew_status`
- `last_renew_tx_hash`

Recommended relayer execution policy:

- poll due subscriptions every 1-5 minutes
- before submitting `renew(user)`, read `getSubscriptionDetails(user)`
- only submit when:
  - `planId != 0`
  - `canceled == false`
  - `expiry <= now`
  - `expiry + gracePeriod >= now`
- use a per-service and per-user idempotency key to prevent duplicate sends
- treat same-plan prepay as a user action only; relayer should not extend early

## Minimal Indexer Design

The indexer only needs to support the MVP dashboard:

- factory overview
- merchant service list
- plan list per service
- subscription activity
- renewal history
- protocol fee visibility

Recommended derived entities:

- `factory`
- `service`
- `plan`
- `merchant`
- `subscriber_subscription`
- `renewal_attempt`
- `merchant_withdrawal`
- `tier_purchase`

The simplest MVP implementation is:

- log-based ingestion from RPC
- local DB
- REST or JSON endpoint consumed by the dashboard

No subgraph is required for the MVP.

## Dashboard Event List

Factory events:

- `ServiceCreated(address service, address owner)`
  - discover new merchant services

- `SubscriptionPurchased(address service, uint256 tierId, uint256 expiresAt)`
  - show merchant tier/license purchases

- `CustomFeeSet(address service, uint256 feeBps, bool active)`
  - show fee override state

- `TierUpdated(uint256 tierId, uint256 price, uint256 feeBps, uint256 duration, bool isActive)`
  - show current tier catalog

- `PlatformWalletUpdated(address oldWallet, address newWallet)`
  - operational/admin visibility

Logic events:

- `PlanCreated(uint256 planId, uint256 price, uint256 interval, bool isDefault)`
  - render service plan catalog

- `PlanUpdated(uint256 planId, uint256 price, uint256 interval, bool isActive)`
  - update live plan display

- `Subscribed(address user, uint256 planId, uint256 expiresAt, uint256 agreedPrice, uint256 agreedInterval, uint256 feePaid, uint256 netAmount)`
  - new subscriptions and same-plan extensions

- `Renewed(address user, uint256 planId, address triggeredBy, uint256 expiresAt, uint256 agreedPrice, uint256 agreedInterval, uint256 feePaid, uint256 netAmount)`
  - renewal history and relayer activity

- `SubscriptionCancelled(address user, uint256 planId)`
  - cancellation state

- `FundsWithdrawn(address owner, address token, uint256 amount)`
  - merchant cash-out history

- `ConfigUpdated(uint256 planId, uint256 newPrice, uint256 newInterval)`
  - default-plan configuration changes

Recommended dashboard reads in addition to events:

- `factory.getCurrentFeeBps(service)`
- `factory.getLicenseInfo(service)`
- `factory.getServicesByOwner(owner)`
- `service.getPlan(planId)`
- `service.getSubscriptionDetails(user)`
- `service.getRemainingTime(user)`

Important caveat:

- `serviceOwner` and `servicesByOwner` are helper indexes only
- authorization and accurate current ownership must use live `owner()` on each service

## MVP Demo Flow

1. Deploy `SubArcLogicV1` and `SubArcFactoryV1`.
2. Optionally deploy `MockUSDC` if the demo should not use Arc-native USDC.
3. Merchant creates a service through `factory.createService(...)`.
4. Merchant creates a paid plan through `service.createPlan(price, interval)`.
5. Subscriber approves USDC to the service contract.
6. Subscriber calls:

```solidity
subscribe(planId, expectedPrice, expectedInterval, maxFeeBps)
```

7. Dashboard shows:
- protocol fee paid
- merchant net amount
- subscriber expiry
- agreed renewal terms

8. After expiry, the relayer calls:

```solidity
renew(subscriber)
```

9. Merchant calls:

```solidity
withdrawFunds()
```

10. Dashboard shows:
- withdrawal amount
- protocol fees collected
- renewal history

## Product Notes For MVP

- same-plan active subscribe is treated as explicit prepaid extension
- different-plan switching while active remains blocked
- cancel must remain available even if the factory or service is paused
- Gateway remains an optional future frontend/backend funding layer only
