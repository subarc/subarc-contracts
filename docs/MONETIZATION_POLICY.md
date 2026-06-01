# SubArc Monetization Policy

## Goal

SubArc should price itself closer to infrastructure than to an app store.

That means:

- low recurring take rate on subscription volume
- clear value-based tier upgrades for merchants
- subscriber-side protection against silent fee changes
- room for negotiated enterprise deals

## Recommended Model

Use two separate revenue levers:

1. merchant platform tier payment
2. protocol fee on subscriber payments

Do not rely on protocol fee alone.

Protocol fee only works well once merchant volume is high. Early-stage infrastructure also needs predictable merchant-side revenue to cover relayer operations, dashboard support, webhooks, monitoring, and gas sponsorship.

## Merchant Tiers

### Free / Starter

- monthly tier price: `0`
- protocol fee: `500 bps` (`5%`)
- target user: hobby, testing, low-volume merchants

Reason:

- zero upfront friction
- high enough take rate to cover support and ops on small merchants

### Pro

- monthly tier price: `50 USDC`
- protocol fee: `100 bps` (`1%`)
- target user: real businesses with recurring volume

Reason:

- strong default commercial plan
- competitive with crypto payment infrastructure
- much cheaper than app-store economics

### Enterprise

- monthly tier price: `starting at 500 USDC`
- protocol fee: `10-50 bps` (`0.10% - 0.50%`)
- target user: high-volume merchants, custom support, custom SLA, negotiated routing

Reason:

- large merchants care more about variable take rate than fixed SaaS price
- creates room for custom agreements without weakening the default pricing story

Operational note:

- the public onchain `Enterprise` preset in this repo can stay at `500 USDC` and `10 bps`
- negotiated enterprise deals should use explicit business approval plus service-level custom fee override

## Answer To The Key Product Question

Yes. In the recommended model, when a merchant selects `Pro` or `Enterprise`, they should make an extra platform payment.

That payment is separate from subscriber payments.

Why this is the right tradeoff:

- merchant-side SaaS fee gives predictable platform revenue
- lower protocol fee makes the product easier to sell
- high-volume merchants prefer fixed platform spend plus low take rate
- low-volume merchants can stay on the free tier and pay a higher percentage instead

This matches the current contract direction, where tier purchase and protocol fee are already separate concerns.

## How To Explain It Commercially

Simple merchant story:

- `Free`: no monthly fee, higher take rate
- `Pro`: small monthly fee, low take rate
- `Enterprise`: custom monthly agreement starting at `500 USDC`, very low take rate

Simple subscriber story:

- subscribers never pay an extra hidden platform charge beyond the subscription payment they approve
- the protocol fee is carved out of the merchant settlement

## Real-World Pricing Anchors

Useful benchmarks:

- Stripe card payments are commonly around `2.9% + 30c`
- crypto payment processors often cluster around `1%`
- merchant-of-record products can be around `5% + 50c`
- app-store subscription platforms can reach `15-30%`

SubArc should not price like an app store.

The best positioning is:

- more expensive than raw settlement
- much cheaper than distribution monopolies
- competitive with crypto-native payment infrastructure

## Blockchain-Specific Guidance

Prefer percentage-based fee only.

Do not add a fixed per-renewal fee in MVP.

Why:

- fixed fees punish low-price subscriptions
- stablecoin subscriptions often need simple UX
- dynamic gas surcharges increase complexity and break merchant predictability

If gas sponsorship becomes expensive, handle it through tier policy, not per-renewal fee math.

Examples:

- keep `Free` at a higher take rate
- include sponsored renewals only for `Pro` and above
- reserve custom relayer guarantees for `Enterprise`

## Governance Recommendation

Short term:

- keep fee control at platform level
- prefer tier-based fee changes
- use service-level custom fee only for exceptional enterprise deals

Medium term:

- move owner powers behind a multisig
- add operational policy for fee changes and merchant notice periods

Long term:

- transfer fee governance to DAO + timelock

## Break-Even Logic

The model works only if the upgrade thresholds are easy to explain.

### Free -> Pro

- `Free` fee: `5%`
- `Pro` fee: `1%`
- `Pro` monthly fee: `50 USDC`

Difference in take rate: `4%`

Break-even volume:

- `50 / 0.04 = 1,250 USDC / month`

Interpretation:

- below `1,250 USDC / month`, `Free` is cheaper
- above `1,250 USDC / month`, `Pro` becomes economically rational

### Pro -> Enterprise

- `Pro` fee: `1%`
- `Enterprise` fee floor: `0.10%`
- `Enterprise` monthly fee floor: `500 USDC`

Difference in take rate: `0.90%`

Break-even volume:

- `500 / 0.009 = ~55,556 USDC / month`

Interpretation:

- `Enterprise` should be sold, not self-serve
- it only makes sense for merchants with meaningful recurring volume or operational needs

## Recommended Defaults For This Repo

Use these defaults:

- `Free`: `0 USDC / month`, `500 bps`
- `Pro`: `50 USDC / month`, `100 bps`
- `Enterprise`: public preset `500 USDC / month`, `10 bps`
- global fee cap: `1000 bps`

For enterprise deals, allow custom fee override only with explicit business approval.

In other words:

- the repo keeps one clean public enterprise preset
- real enterprise pricing can still be negotiated around that preset

## Subscriber Protection Rules

Keep these rules unchanged:

- `expectedPrice`
- `expectedInterval`
- `maxFeeBps`

These are core trust guarantees.

If platform fee rises above a subscriber's accepted `maxFeeBps`, renewal should fail rather than silently charge under new terms.
