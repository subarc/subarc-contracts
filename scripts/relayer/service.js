const { ethers } = require("ethers");
const { factoryAbi, logicAbi, erc20Abi } = require("./artifacts");
const { planKey, subscriptionKey, pushRenewalAttempt } = require("./store");

const DEFAULT_RENEWAL_GRACE_PERIOD_SECONDS = 7n * 24n * 60n * 60n;
const DEFAULT_DUPLICATE_WINDOW_MS = 5 * 60 * 1000;
const DEFAULT_MAX_BLOCK_RANGE = 5_000;

async function fetchDeploymentBlock(provider, txHash, fallbackBlock) {
  const receipt = txHash ? await provider.getTransactionReceipt(txHash) : null;
  if (receipt && receipt.blockNumber != null) {
    return Number(receipt.blockNumber);
  }
  return fallbackBlock || 0;
}

async function queryEventsInChunks(contract, filter, fromBlock, toBlock, maxBlockRange) {
  const events = [];

  if (toBlock < fromBlock) {
    return events;
  }

  for (let start = fromBlock; start <= toBlock; start += maxBlockRange) {
    const end = Math.min(start + maxBlockRange - 1, toBlock);
    const chunk = await contract.queryFilter(filter, start, end);
    events.push(...chunk);
  }

  return events;
}

function serializeAddress(value) {
  return value.toLowerCase();
}

function toBigIntString(value) {
  return BigInt(value).toString();
}

function isRecentAttempt(state, serviceAddress, userAddress, nowMs, duplicateWindowMs) {
  const serviceKey = serviceAddress.toLowerCase();
  const userKey = userAddress.toLowerCase();

  return state.renewalAttempts.some((attempt) => {
    return (
      attempt.serviceAddress === serviceKey &&
      attempt.userAddress === userKey &&
      nowMs - new Date(attempt.timestamp).getTime() < duplicateWindowMs
    );
  });
}

class SubArcRelayerService {
  constructor({
    provider,
    signer = null,
    manifest,
    state,
    clock = () => Date.now(),
    options = {},
  }) {
    this.provider = provider;
    this.signer = signer;
    this.manifest = manifest;
    this.state = state;
    this.clock = clock;
    this.options = {
      confirmationBlocks: Number(options.confirmationBlocks || 0),
      duplicateWindowMs:
        options.duplicateWindowMs == null
          ? DEFAULT_DUPLICATE_WINDOW_MS
          : Number(options.duplicateWindowMs),
      renewalGracePeriodSeconds: BigInt(
        options.renewalGracePeriodSeconds || DEFAULT_RENEWAL_GRACE_PERIOD_SECONDS
      ),
      startBlock:
        options.startBlock == null || options.startBlock === ""
          ? null
          : Number(options.startBlock),
      maxBlockRange: Number(options.maxBlockRange || DEFAULT_MAX_BLOCK_RANGE),
    };

    this.factory = new ethers.Contract(
      manifest.factoryAddress,
      factoryAbi,
      signer || provider
    );
    this.paymentToken = new ethers.Contract(
      manifest.paymentTokenAddress,
      erc20Abi,
      signer || provider
    );

    this.state.metadata.manifestPath = manifest.__path || null;
    this.state.metadata.network = manifest.network;
    this.state.metadata.factoryAddress = manifest.factoryAddress;
    this.state.metadata.paymentTokenAddress = manifest.paymentTokenAddress;
  }

  getKnownServices() {
    return Object.values(this.state.services);
  }

  async getCurrentChainTimestamp() {
    const latestBlock = await this.provider.getBlock("latest");
    return BigInt(latestBlock.timestamp);
  }

  async getScannableBlockNumber() {
    const latestBlock = Number(await this.provider.getBlockNumber());
    return Math.max(0, latestBlock - this.options.confirmationBlocks);
  }

  async scanFactory() {
    const latestBlock = await this.getScannableBlockNumber();
    const startBlock =
      this.state.metadata.lastFactoryScanBlock == null
        ? Math.max(
            this.options.startBlock || 0,
            await fetchDeploymentBlock(
              this.provider,
              this.manifest.txHashes.factoryAddress,
              this.manifest.deploymentBlock
            )
          )
        : this.state.metadata.lastFactoryScanBlock + 1;

    const events = await queryEventsInChunks(
      this.factory,
      this.factory.filters.ServiceCreated(),
      startBlock,
      latestBlock,
      this.options.maxBlockRange
    );

    for (const event of events) {
      const serviceAddress = serializeAddress(event.args.service);
      this.state.services[serviceAddress] = {
        address: serviceAddress,
        owner: serializeAddress(event.args.owner),
        createdAtBlock: Number(event.blockNumber),
        createdAtTxHash: event.transactionHash,
        lastScannedBlock: Number(event.blockNumber) - 1,
        withdrawals: this.state.services[serviceAddress]
          ? this.state.services[serviceAddress].withdrawals || []
          : [],
      };
    }

    this.state.metadata.lastFactoryScanBlock = latestBlock;
    return { latestBlock, servicesDiscovered: events.length };
  }

  async scanServices() {
    const latestBlock = await this.getScannableBlockNumber();
    const knownServices = this.getKnownServices();
    let indexedEvents = 0;

    for (const serviceRecord of knownServices) {
      const service = new ethers.Contract(serviceRecord.address, logicAbi, this.provider);
      const fromBlock = Math.max(
        0,
        (serviceRecord.lastScannedBlock || serviceRecord.createdAtBlock) + 1
      );

      const [planCreated, subscribed, renewed, cancelled, withdrawn] = await Promise.all([
        queryEventsInChunks(
          service,
          service.filters.PlanCreated(),
          fromBlock,
          latestBlock,
          this.options.maxBlockRange
        ),
        queryEventsInChunks(
          service,
          service.filters.Subscribed(),
          fromBlock,
          latestBlock,
          this.options.maxBlockRange
        ),
        queryEventsInChunks(
          service,
          service.filters.Renewed(),
          fromBlock,
          latestBlock,
          this.options.maxBlockRange
        ),
        queryEventsInChunks(
          service,
          service.filters.SubscriptionCancelled(),
          fromBlock,
          latestBlock,
          this.options.maxBlockRange
        ),
        queryEventsInChunks(
          service,
          service.filters.FundsWithdrawn(),
          fromBlock,
          latestBlock,
          this.options.maxBlockRange
        ),
      ]);

      for (const event of planCreated) {
        indexedEvents += 1;
        const key = planKey(serviceRecord.address, event.args.planId);
        this.state.plans[key] = {
          serviceAddress: serviceRecord.address,
          planId: String(event.args.planId),
          price: toBigIntString(event.args.price),
          interval: toBigIntString(event.args.interval),
          isDefault: Boolean(event.args.isDefault),
          lastUpdatedBlock: Number(event.blockNumber),
          lastUpdatedTxHash: event.transactionHash,
        };
      }

      for (const event of subscribed) {
        indexedEvents += 1;
        const userAddress = serializeAddress(event.args.user);
        const key = subscriptionKey(serviceRecord.address, userAddress);
        this.state.subscriptions[key] = {
          serviceAddress: serviceRecord.address,
          userAddress,
          planId: String(event.args.planId),
          expiresAt: toBigIntString(event.args.expiresAt),
          agreedPrice: toBigIntString(event.args.agreedPrice),
          agreedInterval: toBigIntString(event.args.agreedInterval),
          maxFeeBps: null,
          canceled: false,
          lastEvent: "Subscribed",
          lastEventBlock: Number(event.blockNumber),
          lastEventTxHash: event.transactionHash,
          lastRenewedAt: null,
        };
      }

      for (const event of renewed) {
        indexedEvents += 1;
        const userAddress = serializeAddress(event.args.user);
        const key = subscriptionKey(serviceRecord.address, userAddress);
        const existing = this.state.subscriptions[key] || {
          serviceAddress: serviceRecord.address,
          userAddress,
        };
        this.state.subscriptions[key] = {
          ...existing,
          planId: String(event.args.planId),
          expiresAt: toBigIntString(event.args.expiresAt),
          agreedPrice: toBigIntString(event.args.agreedPrice),
          agreedInterval: toBigIntString(event.args.agreedInterval),
          canceled: false,
          lastEvent: "Renewed",
          lastEventBlock: Number(event.blockNumber),
          lastEventTxHash: event.transactionHash,
          lastRenewedAt: new Date(this.clock()).toISOString(),
        };
      }

      for (const event of cancelled) {
        indexedEvents += 1;
        const userAddress = serializeAddress(event.args.user);
        const key = subscriptionKey(serviceRecord.address, userAddress);
        const existing = this.state.subscriptions[key] || {
          serviceAddress: serviceRecord.address,
          userAddress,
        };
        this.state.subscriptions[key] = {
          ...existing,
          planId: String(event.args.planId),
          canceled: true,
          lastEvent: "SubscriptionCancelled",
          lastEventBlock: Number(event.blockNumber),
          lastEventTxHash: event.transactionHash,
        };
      }

      for (const event of withdrawn) {
        indexedEvents += 1;
        this.state.services[serviceRecord.address].withdrawals.push({
          owner: serializeAddress(event.args.owner),
          token: serializeAddress(event.args.token),
          amount: toBigIntString(event.args.amount),
          blockNumber: Number(event.blockNumber),
          txHash: event.transactionHash,
          timestamp: new Date(this.clock()).toISOString(),
        });
      }

      serviceRecord.lastScannedBlock = latestBlock;
    }

    this.state.metadata.lastServiceScanBlock = latestBlock;
    this.state.metadata.lastIndexedBlock = latestBlock;

    await this.refreshTrackedSubscriptions();

    return { latestBlock, indexedEvents };
  }

  async refreshTrackedSubscriptions() {
    const entries = Object.values(this.state.subscriptions);

    for (const subscription of entries) {
      const service = new ethers.Contract(subscription.serviceAddress, logicAbi, this.provider);
      const details = await service.getSubscriptionDetails(subscription.userAddress);
      subscription.planId = String(details.planId);
      subscription.expiresAt = toBigIntString(details.expiry);
      subscription.canceled = Boolean(details.canceled);
      subscription.agreedPrice = toBigIntString(details.agreedPrice);
      subscription.agreedInterval = toBigIntString(details.agreedInterval);
      subscription.maxFeeBps = toBigIntString(details.maxFeeBps);
    }
  }

  async scan() {
    const factoryResult = await this.scanFactory();
    const serviceResult = await this.scanServices();
    return { factoryResult, serviceResult };
  }

  async getDueSubscriptions() {
    const nowSeconds = await this.getCurrentChainTimestamp();

    return Object.values(this.state.subscriptions).filter((subscription) => {
      if (subscription.canceled || !subscription.expiresAt) {
        return false;
      }

      const expiresAt = BigInt(subscription.expiresAt);
      return (
        expiresAt <= nowSeconds &&
        nowSeconds <= expiresAt + this.options.renewalGracePeriodSeconds
      );
    });
  }

  buildAttemptBase(subscription) {
    return {
      serviceAddress: subscription.serviceAddress.toLowerCase(),
      userAddress: subscription.userAddress.toLowerCase(),
      timestamp: new Date(this.clock()).toISOString(),
    };
  }

  async validateRenewalEligibility(subscription) {
    const nowSeconds = await this.getCurrentChainTimestamp();
    const nowMs = this.clock();

    if (
      isRecentAttempt(
        this.state,
        subscription.serviceAddress,
        subscription.userAddress,
        nowMs,
        this.options.duplicateWindowMs
      )
    ) {
      return { ok: false, reason: "duplicate-window" };
    }

    const service = new ethers.Contract(subscription.serviceAddress, logicAbi, this.provider);
    const details = await service.getSubscriptionDetails(subscription.userAddress);

    if (details.canceled) {
      return { ok: false, reason: "subscription-canceled" };
    }
    if (details.planId === 0n) {
      return { ok: false, reason: "no-active-subscription" };
    }
    if (details.expiry > nowSeconds) {
      return { ok: false, reason: "not-due-yet" };
    }
    if (nowSeconds > details.expiry + this.options.renewalGracePeriodSeconds) {
      return { ok: false, reason: "grace-window-expired" };
    }

    const currentFeeBps = await this.factory.getCurrentFeeBps(subscription.serviceAddress);
    if (currentFeeBps > details.maxFeeBps) {
      return { ok: false, reason: "fee-cap-exceeded" };
    }

    const requiredAmount = details.agreedPrice;
    const balance = await this.paymentToken.balanceOf(subscription.userAddress);
    if (balance < requiredAmount) {
      return { ok: false, reason: "insufficient-balance" };
    }

    const allowance = await this.paymentToken.allowance(
      subscription.userAddress,
      subscription.serviceAddress
    );
    if (allowance < requiredAmount) {
      return { ok: false, reason: "insufficient-allowance" };
    }

    return {
      ok: true,
      service,
      details,
    };
  }

  async renewDueSubscriptions() {
    if (!this.signer) {
      throw new Error("Relayer signer is required for renewals");
    }

    const dueSubscriptions = await this.getDueSubscriptions();
    const results = [];

    for (const subscription of dueSubscriptions) {
      const attemptBase = this.buildAttemptBase(subscription);

      try {
        const validation = await this.validateRenewalEligibility(subscription);

        if (!validation.ok) {
          const skipped = {
            ...attemptBase,
            status: "skipped",
            txHash: null,
            failureReason: validation.reason,
          };
          pushRenewalAttempt(this.state, skipped);
          results.push(skipped);
          continue;
        }

        const connectedService = validation.service.connect(this.signer);
        const tx = await connectedService.renew(subscription.userAddress);
        const receipt = await tx.wait();

        const success = {
          ...attemptBase,
          status: "submitted",
          txHash: tx.hash,
          failureReason: null,
          receiptStatus: receipt ? receipt.status : null,
        };
        pushRenewalAttempt(this.state, success);
        results.push(success);
      } catch (error) {
        const failed = {
          ...attemptBase,
          status: "failed",
          txHash: error && error.transactionHash ? error.transactionHash : null,
          failureReason:
            error && error.shortMessage
              ? error.shortMessage
              : error && error.message
                ? error.message
                : "unknown-error",
        };
        pushRenewalAttempt(this.state, failed);
        results.push(failed);
      }
    }

    await this.refreshTrackedSubscriptions();
    return results;
  }

  async getStatusSummary() {
    const now = await this.getCurrentChainTimestamp();
    const subscriptions = Object.values(this.state.subscriptions);
    const activeSubscriptions = subscriptions.filter((subscription) => {
      return !subscription.canceled && BigInt(subscription.expiresAt || 0) > now;
    });
    const dueSubscriptions = subscriptions.filter((subscription) => {
      if (subscription.canceled) {
        return false;
      }
      const expiry = BigInt(subscription.expiresAt || 0);
      return (
        expiry <= now &&
        now <= expiry + this.options.renewalGracePeriodSeconds
      );
    });
    const canceledSubscriptions = subscriptions.filter((subscription) => subscription.canceled);
    const recentAttempts = this.state.renewalAttempts.slice(-10).reverse();
    const recentIssues = recentAttempts.filter((attempt) => {
      return attempt.status !== "submitted";
    });

    return {
      manifestPath: this.manifest.__path,
      network: this.manifest.network,
      factoryAddress: this.manifest.factoryAddress,
      paymentTokenAddress: this.manifest.paymentTokenAddress,
      lastIndexedBlock: this.state.metadata.lastIndexedBlock,
      services: Object.keys(this.state.services).length,
      plans: Object.keys(this.state.plans).length,
      activeSubscriptions: activeSubscriptions.length,
      dueSubscriptions: dueSubscriptions.length,
      canceledSubscriptions: canceledSubscriptions.length,
      recentRenewalAttempts: recentAttempts,
      recentIssues,
    };
  }
}

module.exports = {
  SubArcRelayerService,
  DEFAULT_RENEWAL_GRACE_PERIOD_SECONDS,
  DEFAULT_DUPLICATE_WINDOW_MS,
};
