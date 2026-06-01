# SubArc Demo Flow

This document shows how to run the SubArc MVP demo locally and on Arc testnet.

## Local Demo

Run:

```bash
npm install
cp .env.example .env
npm run demo:local
```

The local demo will:

1. deploy `MockUSDC`
2. deploy `SubArcLogicV1`
3. deploy `SubArcFactoryV1`
4. mint demo USDC to the subscriber
5. create a merchant service
6. create a paid plan
7. approve USDC
8. call safe `subscribe(planId, expectedPrice, expectedInterval, maxFeeBps)`
9. advance time past expiry
10. run a relayer-style `renew(user)`
11. withdraw merchant funds

## Expected Terminal Output

You should see a human-readable summary including:

- service address
- plan id
- plan price
- subscriber expiry before renewal
- subscriber expiry after renewal
- protocol fee delta
- merchant withdraw amount
- renewal tx hash

## Arc Testnet Demo

### 1. Deploy

```bash
npm run deploy:arc
```

This generates:

```text
deployments/arcTestnet.latest.json
```

### 2. Prepare a Merchant Demo Service

```bash
npm run demo:arc:prepare
```

This will:

- read the deployment manifest
- connect to Arc testnet
- create a merchant service
- create a short demo paid plan
- print:
  - service address
  - plan id
  - price
  - interval
  - expected subscribe parameters

### 3. Manual Subscriber Steps

Subscriber needs to:

1. approve USDC to the service contract
2. call:

```solidity
subscribe(planId, expectedPrice, expectedInterval, maxFeeBps)
```

### 4. Check Live State

```bash
SERVICE_ADDRESS=0x... SUBSCRIBER_ADDRESS=0x... npm run demo:arc:check
```

This prints:

- service owner
- plan details
- subscription details
- remaining time
- whether it is due
- whether the relayer should renew
- merchant withdrawable balance
- protocol fee balance

### 5. Relayer Step

Run once:

```bash
npm run relayer:once
```

Or continuously:

```bash
npm run relayer:loop
```

## Troubleshooting

### Placeholder manifest error

If a script says the manifest is still a placeholder:

```bash
npm run deploy:arc
```

### No relayer state yet

If `npm run relayer:status` says no state exists yet:

```bash
npm run relayer:scan
```

### Missing subscriber output

For `demo:arc:check`, set:

- `SERVICE_ADDRESS`
- `SUBSCRIBER_ADDRESS`

### Renewal not happening

Check:

- subscription is not canceled
- expiry has passed
- still inside grace period
- user allowance is sufficient
- user balance is sufficient
- current fee does not exceed subscriber `maxFeeBps`
