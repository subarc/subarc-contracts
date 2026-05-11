# SubArc Contracts

Foundry workspace for the SubArc MVP contracts.

## Contracts

- `SubArcFactory.sol`: merchant registration and subscription contract creation.
- `SubArcSubscription.sol`: merchant-owned subscription contract with manual subscribe, renew, cancel, plan creation, status checks, and merchant withdrawal.
- Both contracts expose a versioned V1 API, use clone-based service deployment, and include pause, fee-cap, reentrancy, safe-transfer, and payment-token rescue protections.

## Commands

```bash
cd packages/contracts
forge build
forge test -vv
```

## Arc Testnet Deploy

```bash
cd packages/contracts
export ARC_TESTNET_RPC_URL="https://rpc.testnet.arc.network"
export PRIVATE_KEY="..."
export SUBARC_FEE_RECIPIENT="0x..."
export SUBARC_PLATFORM_FEE_BPS="100"
export SUBARC_PAYMENT_TOKEN="0x..." # Arc testnet USDC or MockUSDC
forge script script/DeployArcTestnet.s.sol --rpc-url "$ARC_TESTNET_RPC_URL" --broadcast
```

The deploy script writes `deployments/arc-testnet.json` with:

- `factory`
- `subscriptionImplementation`
- `paymentToken`
- `feeRecipient`
- `chainId`
- `deploymentBlock`

Copy `factory` to Hub as `NEXT_PUBLIC_FACTORY_ADDRESS` and `paymentToken` as `NEXT_PUBLIC_USDC_ADDRESS`.
