# SubArc Contracts

Foundry workspace for the SubArc MVP contracts.

> Security status: MVP/testnet code. It is not third-party audited and should not be
> marketed as production-ready or fully automated recurring billing until an
> external audit, production deployment review, and operational multisig/timelock
> setup are complete.

## Contracts

- `SubArcFactory.sol`: merchant registration, clone-based service creation, service ownership registry, payment-token whitelist, global pause, platform fee config, and paid merchant tier licenses.
- `SubArcSubscription.sol`: merchant-owned prepaid subscription contract with guarded subscribe, guarded renew, cancel, plan creation, status checks, and merchant withdrawal.
- Both contracts expose a versioned V1 API and include pause controls, fee caps, reentrancy protection, strict ERC-20 transfer accounting, payment-token rescue protections, and implementation-initializer locks.

## Positioning

SubArc V1 is an Arc-native subscription contract factory for prepaid on-chain
access, with renewal-ready infrastructure. It does not automatically pull future
payments from subscribers. Production recurring billing should be built later
with signed renewal intents, Permit2/ERC-2612, account abstraction session keys,
or another explicit user-authorization layer.

## Payment Model

- Amounts are raw ERC-20 units. For USDC, use 6-decimal amounts such as `10_000000` for 10 USDC.
- Service subscription payments are split at payment time. The platform fee goes directly to the current factory `feeRecipient`; net merchant proceeds remain in the service contract until merchant withdrawal.
- Subscribers must pass payment guards when subscribing or renewing:
  - `expectedPrice`: maximum accepted plan price.
  - `expectedInterval`: exact accepted plan interval.
  - `maxFeeBps`: maximum accepted platform fee.
- Existing services read the current factory fee recipient during each payment.
- Free-tier services read the current platform fee. Paid tier licenses snapshot
  the tier fee at purchase time, so later tier updates do not retroactively
  change an active license.
- Paid merchant tiers are purchased with the service payment token. Default tiers assume USDC-style 6-decimal units:
  - Free: platform fee configured at factory deploy time.
  - Pro: 50 USDC for 30 days, 1% fee.
  - Enterprise: 500 USDC for 30 days, 0.1% fee.
- Payment token addresses must be explicitly whitelisted by the factory owner
  and must contain contract code. Default production stance should be verified
  stablecoins only, such as USDC/EURC on supported networks.
- Subscription and tier payments check recipient balance deltas. Fee-on-transfer
  or deflationary tokens are rejected.

## Security Notes

See `SECURITY.md` for production readiness requirements and reporting guidance.

- Subscription `subscribe` and `renew` are protected by a storage reentrancy guard.
- Factory global `pause()` blocks new service creation, tier purchases, and
  existing service subscribe/renew calls.
- Merchant service `pause()` blocks that service's subscribe/renew calls.
- Subscribe/renew calls include price, interval, and fee guards to protect users
  from same-block config or fee changes.
- ERC-20 transfers support both standard bool-returning tokens and no-return tokens, and revert on failed calls.
- Merchants cannot rescue the configured payment token; they must use `withdrawFunds`.
- Factory owner controls payment-token whitelist, platform fee bps, fee recipient,
  and tier definitions. Fees are capped at 10%. Production owner should be a
  multisig or timelock-controlled account.
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

The deploy script deploys the factory and whitelists `SUBARC_PAYMENT_TOKEN`.

The deploy script writes `deployments/arc-testnet.json` with:

- `factory`
- `subscriptionImplementation`
- `paymentToken`
- `feeRecipient`
- `chainId`
- `deploymentBlock`

Copy `factory` to Hub as `NEXT_PUBLIC_FACTORY_ADDRESS` and `paymentToken` as `NEXT_PUBLIC_USDC_ADDRESS`.
