# SubArc Protocol 🔄

**EVM-based, gas-efficient subscription infrastructure for the Web3 ecosystem.**

SubArc is a decentralized "Software as a Service" (SaaS) protocol that allows any dApp, game, or service provider to easily set up recurring crypto payments. It utilizes the **EIP-1167 Minimal Proxy (Clones)** pattern to ensure ultra-low gas costs for deploying subscription services.

---

## 🏗 Architecture

The protocol consists of two main components:

1.  **SubArcFactoryV1:** The main registry and management contract. It handles:
    * Deploying new Service clones.
    * Managing the Tier system (Free / Pro / Enterprise).
    * Collecting platform fees.
    * Global security (Pause/Unpause).

2.  **SubArcLogicV1:** The implementation contract. It handles:
    * User subscriptions (`subscribe`).
    * Validity checks (`isSubscribed`).
    * Dynamic fee resolution (queries the Factory).
    * Merchant withdrawals (`withdrawFunds`).

## ✨ Key Features

* **🏭 Factory & Clone Pattern:** Merchants can deploy their own subscription contract for ~$0.50 (on L2s).
* **💸 Dynamic Fee System:**
    * **Free Tier:** 5% platform fee.
    * **Pro Tier:** 1% platform fee (requires monthly payment).
    * **Enterprise:** 0.1% platform fee (for high-volume merchants).
* **🛡️ Security First:**
    * `ReentrancyGuard` on all payment functions.
    * `Pausable` (Circuit Breaker) for emergencies.
    * `Ownable` access control.
    * Safety caps on fee percentages (Max 50%).
* **🔌 Plug & Play:** Supports any ERC-20 token (USDC, USDT, etc.) as payment currency.

---

## 🚀 Getting Started

### Prerequisites

* Node.js (v18+)
* npm or yarn

### Installation

1.  Clone the repository:
    ```bash
    git clone [https://github.com/subarc/subarc-contracts.git](https://github.com/subarc/subarc-contracts.git)
    cd subarc-contracts
    ```

2.  Install dependencies:
    ```bash
    npm install
    ```

### 🧪 Running Tests

We use **Hardhat** for testing. The suite includes integration tests covering the full lifecycle (Factory creation -> Subscription -> Fee distribution -> Upgrades).

```bash
npx hardhat test
Expected Output:Plaintext  SubArc Ecosystem (Factory + Logic Integration)
    ✔ Should create a new service clone correctly
    ✔ Should charge 5% fee by default
    ✔ Merchant upgrades to Pro -> Fee drops to 1%
    ✔ Should revert to 5% fee after 30 days (Pro Expired)
    ✔ Only owner can withdraw funds
    ...
  8 passing

📜 Contract Details
Contract	            Type	Description
SubArcFactoryV1	        Core	Manages tiers, creates clones, collects fees.
SubArcLogicV1	        Logic	The blueprint for all subscription services.
MockUSDC	            Test	Used for local testing environment (6 decimals).

🔒 Security & Audit
This project follows industry best practices (Checks-Effects-Interactions, OpenZeppelin standards).

Access Control: Strict onlyOwner usage.

Initializers: Implementation contract is locked (_disableInitializers).

Rescue: Accidental token transfers can be recovered by the owner.

Note: This code has not yet been audited by a third-party firm. Use at your own risk.

📄 License
Distributed under the Business Source License 1.1. See LICENSE for more information.

built with 💙 by the SubArc Team.
