# SubArc Contracts

Foundry workspace for the SubArc MVP contracts.

## Contracts

- `SubArcFactory.sol`: merchant registration, clone-based service creation, service ownership registry, platform fee config, and paid merchant tier licenses.
- `SubArcSubscription.sol`: merchant-owned subscription contract with manual subscribe, renew, cancel, plan creation, status checks, and merchant withdrawal.
- Both contracts expose a versioned V1 API and include pause controls, fee caps, reentrancy protection, strict ERC-20 transfer handling, payment-token rescue protections, and implementation-initializer locks.

## Payment Model

- Amounts are raw ERC-20 units. For USDC, use 6-decimal amounts such as `10_000000` for 10 USDC.
- Service subscription payments are split at payment time. The platform fee goes directly to the current factory `feeRecipient`; net merchant proceeds remain in the service contract until merchant withdrawal.
- Existing services read the current factory fee recipient and fee bps during each payment, so owner fee changes apply consistently without redeploying service clones.
- Paid merchant tiers are purchased with the service payment token. Default tiers assume USDC-style 6-decimal units:
  - Free: platform fee configured at factory deploy time.
  - Pro: 50 USDC for 30 days, 1% fee.
  - Enterprise: 500 USDC for 30 days, 0.1% fee.
- Payment token addresses must contain contract code. This avoids silent-success transfers to EOAs or zero-code addresses.

## Security Notes

- Subscription `subscribe` and `renew` are protected by a storage reentrancy guard.
- ERC-20 transfers support both standard bool-returning tokens and no-return tokens, and revert on failed calls.
- Merchants cannot rescue the configured payment token; they must use `withdrawFunds`.
- Factory owner controls platform fee bps, fee recipient, and tier definitions. Fees are capped at 10%.
- Expiry is strictly `expiresAt > block.timestamp`; exact-expiry subscriptions are inactive.

## Commands

```bash
forge build
forge test -vv
npm run abi:generate
npm run coverage
```

## Arc Testnet Deploy

```bash
export ARC_TESTNET_RPC_URL="https://rpc.testnet.arc.network"
export PRIVATE_KEY="..."
export SUBARC_FEE_RECIPIENT="0x..."
export SUBARC_PLATFORM_FEE_BPS="500"
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
