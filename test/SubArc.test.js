const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("SubArc Service Factory + Arc-native Recurring Billing", function () {
  const SUB_PRICE = ethers.parseUnits("10", 6);
  const HIGHER_PRICE = ethers.parseUnits("100", 6);
  const PRO_PRICE = ethers.parseUnits("50", 6);
  const MONTH = 30 * 24 * 3600;
  const QUARTER = MONTH * 3;
  const FREE_TIER_BPS = 500n;
  const MAX_FEE_BPS = 1000;

  async function deployFixture() {
    const [owner, platformWallet, merchant, subscriber, relayer, other, newOwner] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("MockUSDC");
    const paymentToken = await MockToken.deploy("Mock USDC", "mUSDC");
    const otherToken = await MockToken.deploy("Other USDC", "oUSDC");

    const Logic = await ethers.getContractFactory("SubArcLogicV1");
    const logicImpl = await Logic.deploy();

    const Factory = await ethers.getContractFactory("SubArcFactoryV1");
    const factory = await Factory.deploy(
      await logicImpl.getAddress(),
      await paymentToken.getAddress(),
      platformWallet.address
    );

    await paymentToken.mint(merchant.address, ethers.parseUnits("1000", 6));
    await paymentToken.mint(subscriber.address, ethers.parseUnits("1000", 6));
    await paymentToken.mint(other.address, ethers.parseUnits("1000", 6));
    await paymentToken.mint(newOwner.address, ethers.parseUnits("1000", 6));

    return { factory, paymentToken, otherToken, owner, platformWallet, merchant, subscriber, relayer, other, newOwner };
  }

  async function createService(txPromise, factory) {
    const tx = await txPromise;
    await tx.wait();
    const events = await factory.queryFilter(factory.filters.ServiceCreated());
    return ethers.getContractAt("SubArcLogicV1", events.at(-1).args[0]);
  }

  describe("Service creation", function () {
    it("reverts for non-USDC service creation", async function () {
      const { factory, otherToken, merchant } = await loadFixture(deployFixture);

      await expect(
        factory.connect(merchant)["createService(address)"](await otherToken.getAddress())
      ).to.be.revertedWith("Unsupported payment token");
    });

    it("succeeds with the factory payment token", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      await expect(
        factory.connect(merchant)["createService(address)"](await paymentToken.getAddress())
      ).to.emit(factory, "ServiceCreated");
    });

    it("createService(token, 0, 0) succeeds and creates no default plan", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          0,
          0
        ),
        factory
      );

      expect(await service.defaultPlanId()).to.equal(0n);
      expect(await service.planCount()).to.equal(0n);
    });

    it("createService(token, 0, 30 days) reverts", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      await expect(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          0,
          MONTH
        )
      ).to.be.revertedWithCustomError(
        await ethers.getContractFactory("SubArcLogicV1"),
        "InvalidDefaultPlan"
      );
    });

    it("createService(token, 10e6, 0) reverts", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      await expect(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          0
        )
      ).to.be.revertedWithCustomError(
        await ethers.getContractFactory("SubArcLogicV1"),
        "InvalidDefaultPlan"
      );
    });

    it("createService(token, 10e6, 30 days) succeeds and creates default plan", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      expect(await service.defaultPlanId()).to.equal(1n);
      const plan = await service.getPlan(1);
      expect(plan.price).to.equal(SUB_PRICE);
      expect(plan.interval).to.equal(BigInt(MONTH));
      expect(plan.isActive).to.equal(true);
    });
  });

  describe("Ownership and tier authorization", function () {
    it("service owner can purchase tier", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(merchant).approve(await factory.getAddress(), PRO_PRICE);
      await expect(factory.connect(merchant).purchaseTier(await service.getAddress(), 1))
        .to.emit(factory, "SubscriptionPurchased");
    });

    it("non-owner cannot purchase tier", async function () {
      const { factory, paymentToken, merchant, other } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await expect(factory.connect(other).purchaseTier(await service.getAddress(), 1))
        .to.be.revertedWith("Not service owner");
    });

    it("after ownership transfer, new owner can purchase tier and old owner cannot", async function () {
      const { factory, paymentToken, merchant, newOwner } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await service.connect(merchant).transferOwnership(newOwner.address);

      await paymentToken.connect(newOwner).approve(await factory.getAddress(), PRO_PRICE);
      await expect(factory.connect(newOwner).purchaseTier(await service.getAddress(), 1))
        .to.emit(factory, "SubscriptionPurchased");

      await expect(factory.connect(merchant).purchaseTier(await service.getAddress(), 1))
        .to.be.revertedWith("Not service owner");
    });

    it("license is active before expiresAt", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(merchant).approve(await factory.getAddress(), PRO_PRICE);
      await factory.connect(merchant).purchaseTier(await service.getAddress(), 1);

      const license = await factory.serviceLicenses(await service.getAddress());
      await time.increaseTo(license.expiresAt - 1n);

      expect(await factory.getCurrentFeeBps(await service.getAddress())).to.equal(100n);
    });

    it("license is expired at exactly expiresAt", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(merchant).approve(await factory.getAddress(), PRO_PRICE);
      await factory.connect(merchant).purchaseTier(await service.getAddress(), 1);

      const license = await factory.serviceLicenses(await service.getAddress());
      await time.increaseTo(license.expiresAt);

      expect(await factory.getCurrentFeeBps(await service.getAddress())).to.equal(FREE_TIER_BPS);
    });

    it("license is expired after expiresAt", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(merchant).approve(await factory.getAddress(), PRO_PRICE);
      await factory.connect(merchant).purchaseTier(await service.getAddress(), 1);

      const license = await factory.serviceLicenses(await service.getAddress());
      await time.increaseTo(license.expiresAt + 1n);

      const info = await factory.getLicenseInfo(await service.getAddress());
      expect(info[2]).to.equal(FREE_TIER_BPS);
    });

    it("requires an active enterprise license before enabling a custom fee", async function () {
      const { factory, paymentToken, merchant, owner } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await expect(
        factory.connect(owner).setCustomFee(await service.getAddress(), 25, true)
      ).to.be.revertedWith("Enterprise tier required");
    });

    it("custom fee stops applying once the enterprise license expires", async function () {
      const { factory, paymentToken, merchant, owner } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(merchant).approve(await factory.getAddress(), ethers.parseUnits("500", 6));
      await factory.connect(merchant).purchaseTier(await service.getAddress(), 2);
      await factory.connect(owner).setCustomFee(await service.getAddress(), 25, true);

      expect(await factory.getCurrentFeeBps(await service.getAddress())).to.equal(25n);

      const license = await factory.serviceLicenses(await service.getAddress());
      await time.increaseTo(license.expiresAt + 1n);

      expect(await factory.getCurrentFeeBps(await service.getAddress())).to.equal(FREE_TIER_BPS);
    });

    it("free tier cannot have price > 0", async function () {
      const { factory } = await loadFixture(deployFixture);

      await expect(factory.updateTier(0, 1, 500, 0, true))
        .to.be.revertedWith("Free tier price must be zero");
    });

    it("free tier cannot have duration > 0", async function () {
      const { factory } = await loadFixture(deployFixture);

      await expect(factory.updateTier(0, 0, 500, MONTH, true))
        .to.be.revertedWith("Free tier duration must be zero");
    });

    it("active paid tier cannot have price == 0", async function () {
      const { factory } = await loadFixture(deployFixture);

      await expect(factory.updateTier(1, 0, 100, MONTH, true))
        .to.be.revertedWith("Paid tier price required");
    });

    it("active paid tier cannot have duration == 0", async function () {
      const { factory } = await loadFixture(deployFixture);

      await expect(factory.updateTier(1, PRO_PRICE, 100, 0, true))
        .to.be.revertedWith("Paid tier duration required");
    });

    it("inactive paid tier may be configured without being purchasable if needed", async function () {
      const { factory } = await loadFixture(deployFixture);

      await expect(factory.updateTier(1, 0, 100, 0, false))
        .to.emit(factory, "TierUpdated");
    });

    it("valid paid tier update succeeds", async function () {
      const { factory } = await loadFixture(deployFixture);

      await expect(factory.updateTier(1, PRO_PRICE, 100, MONTH, true))
        .to.emit(factory, "TierUpdated");
    });
  });

  describe("Subscription entrypoint and agreed terms", function () {
    it("unsafe subscribe overloads are removed", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      const subscribeFragments = service.interface.fragments.filter(
        (fragment) => fragment.type === "function" && fragment.name === "subscribe"
      );

      expect(subscribeFragments).to.have.length(1);
      expect(subscribeFragments[0].inputs).to.have.length(4);
    });

    it("safe subscribe stores agreedPrice, agreedInterval, maxFeeBps", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));

      const details = await service.getSubscriptionDetails(subscriber.address);
      expect(details[0]).to.equal(1n);
      expect(details[4]).to.equal(SUB_PRICE);
      expect(details[5]).to.equal(BigInt(MONTH));
      expect(details[6]).to.equal(FREE_TIER_BPS);
    });

    it("maxFeeBps > MAX_FEE_BPS reverts", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);

      await expect(service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, MAX_FEE_BPS + 1))
        .to.be.revertedWithCustomError(service, "FeeExceedsMax");
    });

    it("subscribe with maxFeeBps == MAX_FEE_BPS succeeds if current fee is within limit", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);

      await expect(service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, MAX_FEE_BPS))
        .to.emit(service, "Subscribed");
    });

    it("subscribe with maxFeeBps below current fee reverts", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);

      await expect(service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, 499))
        .to.be.revertedWithCustomError(service, "FeeExceedsMax");
    });

    it("subscribe with expectedPrice mismatch reverts", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);

      await expect(service.connect(subscriber).subscribe(1, HIGHER_PRICE, MONTH, Number(FREE_TIER_BPS)))
        .to.be.revertedWithCustomError(service, "PriceMismatch");
    });

    it("subscribe with expectedInterval mismatch reverts", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);

      await expect(service.connect(subscriber).subscribe(1, SUB_PRICE, QUARTER, Number(FREE_TIER_BPS)))
        .to.be.revertedWithCustomError(service, "IntervalMismatch");
    });
  });

  describe("Renewal behavior", function () {
    it("plan price update does not affect existing subscriber renewal price", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer, platformWallet } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));

      await service.connect(merchant).updatePlan(1, HIGHER_PRICE, MONTH, true);
      await time.increase(MONTH + 1);
      await service.connect(relayer).renew(subscriber.address);

      const expectedFeePerCycle = (SUB_PRICE * FREE_TIER_BPS) / 10000n;
      expect(await paymentToken.balanceOf(platformWallet.address)).to.equal(expectedFeePerCycle * 2n);
    });

    it("plan interval update does not affect existing subscriber renewal interval", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));
      const firstExpiry = (await service.getSubscriptionDetails(subscriber.address))[1];

      await service.connect(merchant).updatePlan(1, SUB_PRICE, QUARTER, true);
      await time.increase(MONTH + 1);
      await service.connect(relayer).renew(subscriber.address);

      const details = await service.getSubscriptionDetails(subscriber.address);
      expect(details[5]).to.equal(BigInt(MONTH));
      expect(details[1]).to.be.gt(firstExpiry);
    });

    it("renewal uses agreedPrice and agreedInterval", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer, platformWallet } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));

      const firstExpiry = (await service.getSubscriptionDetails(subscriber.address))[1];
      await service.connect(merchant).updatePlan(1, HIGHER_PRICE, QUARTER, true);
      await time.increaseTo(firstExpiry + 1n);
      await service.connect(relayer).renew(subscriber.address);

      const details = await service.getSubscriptionDetails(subscriber.address);
      const expectedFeePerCycle = (SUB_PRICE * FREE_TIER_BPS) / 10000n;

      expect(details[4]).to.equal(SUB_PRICE);
      expect(details[5]).to.equal(BigInt(MONTH));
      expect(await paymentToken.balanceOf(platformWallet.address)).to.equal(expectedFeePerCycle * 2n);
    });

    it("fee increase above subscriber maxFeeBps blocks renewal", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer, owner } = await loadFixture(deployFixture);
      const week = 7 * 24 * 3600;

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          week
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, week, 500);

      await paymentToken.connect(merchant).approve(await factory.getAddress(), ethers.parseUnits("500", 6));
      await factory.connect(merchant).purchaseTier(await service.getAddress(), 2);
      await factory.connect(owner).setCustomFee(await service.getAddress(), 600, true);
      await time.increase(week + 1);

      await expect(service.connect(relayer).renew(subscriber.address))
        .to.be.revertedWithCustomError(service, "FeeExceedsMax");
    });

    it("renewal before expiry reverts", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));

      await expect(service.connect(relayer).renew(subscriber.address))
        .to.be.revertedWithCustomError(service, "SubscriptionNotDue");
    });

    it("renewal during grace period succeeds", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));

      await time.increase(MONTH + 1);
      await expect(service.connect(relayer).renew(subscriber.address)).to.emit(service, "Renewed");
    });

    it("renewal after grace period reverts", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));

      await time.increase(MONTH + 8 * 24 * 3600);
      await expect(service.connect(relayer).renew(subscriber.address))
        .to.be.revertedWithCustomError(service, "RenewalWindowExpired");
    });

    it("renewal fails cleanly if allowance is insufficient", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));
      await paymentToken.connect(subscriber).approve(await service.getAddress(), 0);
      await time.increase(MONTH + 1);

      await expect(service.connect(relayer).renew(subscriber.address)).to.be.reverted;
    });

    it("renewal fails cleanly if balance is insufficient", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer, other } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));
      const remainder = await paymentToken.balanceOf(subscriber.address);
      await paymentToken.connect(subscriber).transfer(other.address, remainder);
      await time.increase(MONTH + 1);

      await expect(service.connect(relayer).renew(subscriber.address)).to.be.reverted;
    });
  });

  describe("Pause and cancel safety", function () {
    it("factory pause blocks subscribe", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);
      await factory.pause();

      await expect(service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS)))
        .to.be.revertedWithCustomError(service, "FactoryPaused");
    });

    it("factory pause blocks renew", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));
      await time.increase(MONTH + 1);
      await factory.pause();

      await expect(service.connect(relayer).renew(subscriber.address))
        .to.be.revertedWithCustomError(service, "FactoryPaused");
    });

    it("service pause blocks subscribe", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);
      await service.connect(merchant).pause();

      await expect(service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS)))
        .to.be.revertedWith("Pausable: paused");
    });

    it("service pause blocks renew", async function () {
      const { factory, paymentToken, merchant, subscriber, relayer } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));
      await time.increase(MONTH + 1);
      await service.connect(merchant).pause();

      await expect(service.connect(relayer).renew(subscriber.address))
        .to.be.revertedWith("Pausable: paused");
    });

    it("cancelSubscription works while service is paused", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));
      await service.connect(merchant).pause();

      await expect(service.connect(subscriber).cancelSubscription()).to.emit(service, "SubscriptionCancelled");
    });

    it("cancelSubscription works while factory is paused", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));
      await factory.pause();

      await expect(service.connect(subscriber).cancelSubscription()).to.emit(service, "SubscriptionCancelled");
    });
  });

  describe("Plan switching and funds", function () {
    it("createPlan(0, 30 days) reverts", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address)"](await paymentToken.getAddress()),
        factory
      );

      await expect(service.connect(merchant).createPlan(0, MONTH))
        .to.be.revertedWithCustomError(service, "InvalidPrice");
    });

    it("createPlan(10e6, 0) reverts", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address)"](await paymentToken.getAddress()),
        factory
      );

      await expect(service.connect(merchant).createPlan(SUB_PRICE, 0))
        .to.be.revertedWithCustomError(service, "InvalidInterval");
    });

    it("createPlan(10e6, 30 days) succeeds", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address)"](await paymentToken.getAddress()),
        factory
      );

      await expect(service.connect(merchant).createPlan(SUB_PRICE, MONTH))
        .to.emit(service, "PlanCreated");
    });

    it("active subscriber cannot silently switch to another plan", async function () {
      const { factory, paymentToken, merchant, subscriber } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address)"](await paymentToken.getAddress()),
        factory
      );

      await service.connect(merchant).createPlan(SUB_PRICE, MONTH);
      await service.connect(merchant).createPlan(HIGHER_PRICE, QUARTER);

      await paymentToken.connect(subscriber).approve(await service.getAddress(), HIGHER_PRICE + SUB_PRICE);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));

      await expect(
        service.connect(subscriber).subscribe(2, HIGHER_PRICE, QUARTER, Number(FREE_TIER_BPS))
      ).to.be.revertedWithCustomError(service, "ActiveSubscriptionLocked");
    });

    it("active subscriber can subscribe again to the same plan and extend the subscription", async function () {
      const { factory, paymentToken, merchant, subscriber, platformWallet } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));
      const firstDetails = await service.getSubscriptionDetails(subscriber.address);

      await expect(service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS)))
        .to.emit(service, "Subscribed");

      const secondDetails = await service.getSubscriptionDetails(subscriber.address);
      const feeAmount = (SUB_PRICE * FREE_TIER_BPS) / 10000n;

      expect(secondDetails[1]).to.equal(firstDetails[1] + BigInt(MONTH));
      expect(await paymentToken.balanceOf(platformWallet.address)).to.equal(feeAmount * 2n);
    });

    it("merchant withdraw works and protocol fee accounting is correct", async function () {
      const { factory, paymentToken, merchant, subscriber, platformWallet } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);
      await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, Number(FREE_TIER_BPS));

      const feeAmount = (SUB_PRICE * FREE_TIER_BPS) / 10000n;
      const merchantShare = SUB_PRICE - feeAmount;

      expect(await paymentToken.balanceOf(platformWallet.address)).to.equal(feeAmount);
      expect(await paymentToken.balanceOf(await service.getAddress())).to.equal(merchantShare);

      const merchantBefore = await paymentToken.balanceOf(merchant.address);
      await expect(service.connect(merchant).withdrawFunds()).to.emit(service, "FundsWithdrawn");
      const merchantAfter = await paymentToken.balanceOf(merchant.address);

      expect(merchantAfter - merchantBefore).to.equal(merchantShare);
    });
  });

  describe("Ownership safety", function () {
    it("renounceOwnership is disabled on factory and service", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const service = await createService(
        factory.connect(merchant)["createService(address,uint256,uint256)"](
          await paymentToken.getAddress(),
          SUB_PRICE,
          MONTH
        ),
        factory
      );

      await expect(factory.renounceOwnership()).to.be.revertedWithCustomError(factory, "RenounceDisabled");
      await expect(service.connect(merchant).renounceOwnership()).to.be.revertedWithCustomError(service, "RenounceDisabled");
    });
  });
});
