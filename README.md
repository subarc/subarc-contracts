# SubArc Contracts

SubArc is an Arc-native recurring USDC billing MVP for merchant subscriptions, with safe subscriber-agreed terms and relayer-triggered renewals.

## What is SubArc?

SubArc lets a merchant deploy a dedicated subscription service contract through a factory, define paid plans, accept subscriber-approved USDC payments, and support renewals through an external relayer.

The goal of this repository is simple: an external developer, grant reviewer, or ecosystem partner should be able to clone it, run tests, execute a local end-to-end demo, deploy to Arc testnet, and understand the full MVP flow.

## MVP Scope

- factory + clone service deployment
- Arc USDC-only service creation
- merchant-created paid plans
- safe `subscribe(planId, expectedPrice, expectedInterval, maxFeeBps)`
- subscriber-agreed renewal terms
- relayer-triggered `renew(user)`
- merchant withdrawals
- protocol fee accounting visibility
- local relayer/indexer state tracking

## What Is Intentionally Not Included

- DAO
- token
- staking
- governance
- keeper network
- Gateway smart contracts
- frontend app
- subgraph
- production monitoring stack

Circle Gateway remains a future frontend/backend funding layer only.

## Architecture

```text
Merchant
  ↓ creates
SubArcFactoryV1
  ↓ clones
SubArcLogicV1 Service
  ↓ manages
Plans / Subscribers / Renewals / Withdrawals
  ↑
Relayer calls renew(user)
  ↑
Subscriber approves USDC
```

Core contracts:

- `contracts/SubArcFactoryV1.sol`
- `contracts/SubArcLogicV1.sol`
- `contracts/mocks/MockUSDC.sol`

## Repository Layout

- `contracts/`
- `scripts/`
  - deployment scripts
  - local demo
  - Arc testnet helpers
  - relayer/indexer CLI
- `deployments/`
  - `arcTestnet.example.json`
  - generated runtime manifests
- `docs/`
  - `DEMO_FLOW.md`
  - `MONETIZATION_POLICY.md`
  - `MVP_INTEGRATION.md`
  - `SECURITY_NOTES.md`
- `test/`

## Quick Start

```bash
npm install
cp .env.example .env
npm test
```

## Run Tests

```bash
npm test
```

Current suite covers:

- service creation rules
- plan validation and agreed-term safety
- renewal timing and fee-cap rules
- pause/cancel behavior
- ownership safety
- relayer manifest validation
- relayer indexing and due-renewal execution

## Run Local End-to-End Demo

This is the most important path in the repo.

```bash
npm run demo:local
```

The local demo will:

- deploy `MockUSDC`
- deploy `SubArcLogicV1`
- deploy `SubArcFactoryV1`
- mint demo USDC
- create a merchant service
- create a paid plan
- approve and subscribe
- advance time past expiry
- run a relayer-style renewal
- withdraw merchant funds
- print the final state in a human-readable summary

## Deploy to Arc Testnet

Set at minimum:

- `PRIVATE_KEY`
- `PLATFORM_WALLET`

Then run:

```bash
npm run deploy:arc
```

The deploy script:

- deploys `SubArcLogicV1`
- deploys `SubArcFactoryV1`
- optionally deploys `MockUSDC`
- generates `deployments/arcTestnet.latest.json`

The checked-in `deployments/arcTestnet.example.json` is a template only. Runtime scripts expect a real generated `arcTestnet.latest.json`.

## Verify Contracts

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

The deployment manifest also stores verification commands after a real deploy.

## Run Relayer / Indexer

Index only:

```bash
npm run relayer:scan
```

Index and renew once:

```bash
npm run relayer:once
```

Run the loop:

```bash
npm run relayer:loop
```

Inspect local relayer state:

```bash
npm run relayer:status
```

The relayer:

- reads `deployments/arcTestnet.latest.json`
- rejects placeholder manifests
- tracks services, plans, subscriptions, and renewal attempts
- checks cancellation, fee cap, balance, allowance, and grace window before `renew(user)`
- never custodies subscriber funds

## Arc Testnet Demo Flow

Prepare a short-lived merchant demo service:

```bash
npm run demo:arc:prepare
```

Check a live service/subscriber state:

```bash
SERVICE_ADDRESS=0x... SUBSCRIBER_ADDRESS=0x... npm run demo:arc:check
```

Typical Arc flow:

1. Run `npm run deploy:arc`
2. Run `npm run demo:arc:prepare`
3. Subscriber approves USDC to the generated service
4. Subscriber calls `subscribe(...)`
5. Run `npm run demo:arc:check`
6. Run `npm run relayer:once` or `npm run relayer:loop`
7. Merchant withdraws accumulated proceeds

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

## Product Notes

- Arc testnet MVP is USDC-only at the service creation layer
- same-plan re-subscribe is treated as explicit prepaid extension
- different-plan switching while active is blocked
- relayer only calls `renew(user)`
- subscriber terms are snapshotted at subscribe time

## Security Notes

See [docs/SECURITY_NOTES.md](docs/SECURITY_NOTES.md).

Highlights:

- safe subscriber-agreed terms
- mutable-plan safety for renewals
- no relayer custody
- factory pause and service pause
- cancel remains callable while paused
- renewal grace period
- ownership source of truth uses live service ownership

## Known MVP Limitations

- testnet MVP, not mainnet audited
- local relayer store is JSON-based, not production-grade persistence
- no reorg handling beyond a simple confirmation buffer
- no frontend in this repo
- no database migration or monitoring stack
- no subgraph

## Roadmap

- production-ready deployment process
- stronger operational monitoring
- cleaner dashboard integration surfaces
- future Gateway-assisted onboarding layer outside the contracts
- eventual audit and mainnet readiness work

## License

Business Source License 1.1. See [LICENSE](LICENSE).
