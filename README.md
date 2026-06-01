# SubArc Contracts

SubArc is an Arc-native recurring USDC billing MVP built around a factory + clone architecture.

This repository contains the frozen Arc testnet MVP contracts plus the minimum off-chain tooling needed to demo the product end-to-end:

- contract deployment on Arc testnet
- deployment manifest generation
- local relayer/indexer service
- Hardhat test coverage for contracts and relayer flow

SubArc MVP scope is intentionally narrow:

- `SubArcFactoryV1` deploys and indexes merchant services
- `SubArcLogicV1` handles plans, subscriptions, renewals, and merchant withdrawals
- subscribers agree to price, interval, and fee cap at subscribe time
- renewals are triggered off-chain by a relayer via `renew(user)`
- Circle Gateway is not part of the contracts and remains a future frontend/backend funding layer

Not included in this repository or MVP:

- DAO
- token
- staking
- governance
- keeper network
- Gateway smart contracts

## Repository Layout

- `contracts/`
  - `SubArcFactoryV1.sol`
  - `SubArcLogicV1.sol`
  - `mocks/MockUSDC.sol`
- `scripts/`
  - `deploy-arc-testnet.js`
  - `relayer-cli.js`
  - `relayer/`
- `deployments/`
  - `arcTestnet.latest.json`
- `docs/`
  - `MVP_INTEGRATION.md`
- `test/`
  - contract integration tests
  - relayer/indexer tests

## Quick Start

```bash
npm install
cp .env.example .env
npm test
```

## Environment Variables

Common deploy/runtime fields:

- `PRIVATE_KEY`
- `PLATFORM_WALLET`
- `ARC_RPC_URL`
- `ARC_USDC_ADDRESS`
- `ARCSCAN_API_KEY`
- `ARCSCAN_API_URL`
- `ARCSCAN_BROWSER_URL`
- `DEPLOY_MOCK_USDC`
- `MOCK_USDC_NAME`
- `MOCK_USDC_SYMBOL`
- `DEPLOYMENT_OUTFILE`

Relayer fields:

- `RELAYER_PRIVATE_KEY`
- `DEPLOYMENT_MANIFEST_PATH`
- `RENEWAL_SCAN_INTERVAL_SECONDS`

See [.env.example](.env.example) for the full template.

## Test

```bash
npm test
```

Current local suite covers:

- service creation rules
- plan validation and agreed-term safety
- renewal timing and fee-cap rules
- pause/cancel behavior
- ownership safety
- relayer manifest validation
- relayer indexing and due-renewal execution

## Arc Testnet Deployment

Deploy the MVP stack to Arc testnet:

```bash
npm run deploy:arc
```

The deploy script:

- deploys `SubArcLogicV1`
- deploys `SubArcFactoryV1`
- optionally deploys `MockUSDC`
- writes a machine-readable manifest to `deployments/arcTestnet.latest.json`

Default payment token:

```text
0x3600000000000000000000000000000000000000
```

If you want a demo-only token instead of Arc-native USDC:

```bash
DEPLOY_MOCK_USDC=true npm run deploy:arc
```

## Contract Verification

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

The generated deployment manifest also includes ready-to-run verification commands.

## Relayer / Indexer

The MVP relayer/indexer is a local Node service that:

- reads `deployments/arcTestnet.latest.json`
- rejects placeholder manifests
- connects to Arc RPC
- indexes:
  - `ServiceCreated`
  - `PlanCreated`
  - `Subscribed`
  - `Renewed`
  - `SubscriptionCancelled`
  - `FundsWithdrawn`
- stores local state in `relayer-data/state.json`
- detects due subscriptions using chain time
- checks cancellation, grace window, fee cap, user balance, and user allowance before calling `renew(user)`
- never custodies user funds

Before running it, make sure `deployments/arcTestnet.latest.json` contains a real deployment and not the checked-in placeholder template.

Scan and index only:

```bash
npm run relayer:scan
```

Scan and process due renewals once:

```bash
npm run relayer:once
```

Run the relayer loop:

```bash
npm run relayer:loop
```

Operational notes:

- the relayer wallet only calls `renew(user)`
- the subscription contract performs the actual USDC `transferFrom`
- duplicate renewal attempts for the same `(service, user)` are suppressed for a short cooldown window
- skip and failure reasons are written into the local state store alongside tx hashes when present

## MVP Demo Flow

1. Deploy `SubArcLogicV1` and `SubArcFactoryV1`.
2. Merchant creates a service with the factory.
3. Merchant creates a paid plan.
4. Subscriber approves USDC to the service.
5. Subscriber calls `subscribe(planId, expectedPrice, expectedInterval, maxFeeBps)`.
6. The relayer waits until expiry, then calls `renew(subscriber)`.
7. Merchant calls `withdrawFunds()`.
8. The dashboard shows protocol fee accounting, merchant net amounts, and subscription state.

## Dashboard Event Sources

Factory:

- `ServiceCreated`
- `SubscriptionPurchased`
- `CustomFeeSet`
- `TierUpdated`
- `PlatformWalletUpdated`

Logic:

- `PlanCreated`
- `PlanUpdated`
- `Subscribed`
- `Renewed`
- `SubscriptionCancelled`
- `FundsWithdrawn`
- `ConfigUpdated`

## Additional Docs

- [MVP integration notes](docs/MVP_INTEGRATION.md)

Historical note:

- `docs/SECURITY_AND_GAMIFICATION_ANALYSIS.md` is an older exploratory document and should not be treated as the current MVP product spec.

## Notes

- Arc testnet MVP is USDC-only at the service creation layer.
- Same-plan re-subscribe is treated as explicit prepaid extension.
- Different-plan switching while active is blocked.
- This repository is prepared for Arc testnet MVP demos, not production mainnet launch.
