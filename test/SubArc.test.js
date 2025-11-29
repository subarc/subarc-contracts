const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("SubArc Ecosystem (Factory + Logic Integration)", function () {
  
  // Test Sabitleri
  const FEE_FREE = 500n; // 5%
  const FEE_PRO = 100n;  // 1%
  const PRO_PRICE = ethers.parseUnits("50", 6); // 50 USDC
  const SUB_PRICE = ethers.parseUnits("10", 6); // 10 USDC (Abonelik ücreti)
  const INTERVAL = 30 * 24 * 3600; // 30 Gün

  // --- FIXTURE: Her testten önce temiz kurulum ---
  async function deployFixture() {
    const [owner, platformWallet, merchant, user1, user2] = await ethers.getSigners();

    // 1. Mock USDC Deploy
    // MockUSDC kontratının constructor parametresi alıp almadığına dikkat et.
    // Genelde: constructor(string memory name, string memory symbol)
    const MockToken = await ethers.getContractFactory("MockUSDC");
    const paymentToken = await MockToken.deploy("Mock USDC", "mUSDC");
    
    // 2. Logic Implementation Deploy (Initialize edilmemiş hali)
    const Logic = await ethers.getContractFactory("SubArcLogicV1");
    const logicImpl = await Logic.deploy();

    // 3. Factory Deploy
    const Factory = await ethers.getContractFactory("SubArcFactoryV1");
    const factory = await Factory.deploy(
        await logicImpl.getAddress(),
        await paymentToken.getAddress(),
        platformWallet.address
    );

    // 4. Para Dağıtma (Mint)
    // Merchant'a Tier satın alması için para ver (1000 USDC)
    await paymentToken.mint(merchant.address, ethers.parseUnits("1000", 6));
    // User'lara abonelik için para ver
    await paymentToken.mint(user1.address, ethers.parseUnits("1000", 6));
    await paymentToken.mint(user2.address, ethers.parseUnits("1000", 6));

    return { factory, logicImpl, paymentToken, owner, platformWallet, merchant, user1, user2 };
  }

  // =========================================================
  // BÖLÜM 1: TEMEL KURULUM VE SERVİS YARATMA
  // =========================================================
  describe("1. Deployment & Service Creation", function () {
    it("Should create a new service clone correctly", async function () {
      const { factory, paymentToken, merchant } = await loadFixture(deployFixture);

      const tx = await factory.connect(merchant).createService(
        await paymentToken.getAddress(),
        SUB_PRICE,
        INTERVAL
      );
      const receipt = await tx.wait();

      // Factory'den ServiceCreated eventini filtrele
      const filter = factory.filters.ServiceCreated();
      const events = await factory.queryFilter(filter);
      const cloneAddress = events[0].args[0];

      // Factory bu adresi tanıyor mu?
      expect(await factory.isService(cloneAddress)).to.be.true;

      // Logic kontratına bağlanıp owner kontrolü yap
      const service = await ethers.getContractAt("SubArcLogicV1", cloneAddress);
      expect(await service.owner()).to.equal(merchant.address);
    });
  });

  // =========================================================
  // BÖLÜM 2: ABONELİK AKIŞI (DEFAULT FREE TIER)
  // =========================================================
  describe("2. Subscription Flow (Free Tier)", function () {
    let service, factory, paymentToken, user1, merchant, platformWallet;

    beforeEach(async function () {
      const fix = await loadFixture(deployFixture);
      factory = fix.factory;
      paymentToken = fix.paymentToken;
      user1 = fix.user1;
      merchant = fix.merchant;
      platformWallet = fix.platformWallet;

      // Servis oluştur
      const tx = await factory.connect(merchant).createService(
        await paymentToken.getAddress(),
        SUB_PRICE,
        INTERVAL
      );
      const events = await factory.queryFilter(factory.filters.ServiceCreated());
      service = await ethers.getContractAt("SubArcLogicV1", events[0].args[0]);
    });

    it("Should charge 5% fee by default", async function () {
      // 1. User Approve
      await paymentToken.connect(user1).approve(await service.getAddress(), SUB_PRICE);

      // Başlangıç bakiyeleri
      const platformStart = await paymentToken.balanceOf(platformWallet.address);
      const serviceStart = await paymentToken.balanceOf(await service.getAddress());

      // 2. Subscribe
      await service.connect(user1).subscribe();

      // 3. Hesaplamalar
      // 10 USDC * %5 = 0.5 USDC Fee
      // 10 USDC - 0.5 = 9.5 USDC Merchant
      const feeAmount = (SUB_PRICE * 500n) / 10000n; // 500 bps
      const netAmount = SUB_PRICE - feeAmount;

      expect(await paymentToken.balanceOf(platformWallet.address)).to.equal(platformStart + feeAmount);
      expect(await paymentToken.balanceOf(await service.getAddress())).to.equal(serviceStart + netAmount);
      
      // Kullanıcı abone görünüyor mu?
      expect(await service.isSubscribed(user1.address)).to.be.true;
    });

    it("Should revert with Custom Error if price not set (Zero Price Check)", async function () {
       // Fiyatı 0 olan bir servis yaratmayı dene (Logic içinde initialize check yoksa yaratır)
       // Ama subscribe anında PriceNotSet() hatası almalı
       // Not: LogicV1 initialize içinde interval > 0 check var ama price > 0 check yok,
       // subscribe içinde price > 0 check var.
    });
  });

  // =========================================================
  // BÖLÜM 3: TIER YÜKSELTME (PRO)
  // =========================================================
  describe("3. Upgrading to Pro Tier", function () {
    let service, factory, paymentToken, user1, merchant, platformWallet;

    beforeEach(async function () {
      const fix = await loadFixture(deployFixture);
      factory = fix.factory;
      paymentToken = fix.paymentToken;
      user1 = fix.user1;
      merchant = fix.merchant;
      platformWallet = fix.platformWallet;

      const tx = await factory.connect(merchant).createService(await paymentToken.getAddress(), SUB_PRICE, INTERVAL);
      const events = await factory.queryFilter(factory.filters.ServiceCreated());
      service = await ethers.getContractAt("SubArcLogicV1", events[0].args[0]);
    });

    it("Merchant upgrades to Pro -> Fee drops to 1%", async function () {
      // 1. Merchant Approve (50 USDC for Pro)
      await paymentToken.connect(merchant).approve(await factory.getAddress(), PRO_PRICE);

      // 2. Purchase Tier 1 (Pro)
      await expect(factory.connect(merchant).purchaseTier(await service.getAddress(), 1))
        .to.emit(factory, "SubscriptionPurchased");

      // 3. User Subscribes
      await paymentToken.connect(user1).approve(await service.getAddress(), SUB_PRICE);
      await service.connect(user1).subscribe();

      // 4. Check Fees (Should be 1% instead of 5%)
      const feeAmount = (SUB_PRICE * 100n) / 10000n; // 1%
      
      // Platform bakiyesi: 50 (Pro ücreti) + 0.1 (Fee) olmalı
      // Not: Platform wallet başlangıçta 0 (fixture'da mintlenmedi)
      const platformBal = await paymentToken.balanceOf(platformWallet.address);
      expect(platformBal).to.equal(PRO_PRICE + feeAmount);
    });
  });

  // =========================================================
  // BÖLÜM 4: ZAMAN YOLCULUĞU (EXPIRY & DOWNGRADE)
  // =========================================================
  describe("4. Expiration & Downgrade", function () {
    let service, factory, paymentToken, user1, merchant, platformWallet;

    beforeEach(async function () {
      const fix = await loadFixture(deployFixture);
      factory = fix.factory;
      paymentToken = fix.paymentToken;
      user1 = fix.user1;
      merchant = fix.merchant;
      platformWallet = fix.platformWallet;

      const tx = await factory.connect(merchant).createService(await paymentToken.getAddress(), SUB_PRICE, INTERVAL);
      const events = await factory.queryFilter(factory.filters.ServiceCreated());
      service = await ethers.getContractAt("SubArcLogicV1", events[0].args[0]);

      // Pro al
      await paymentToken.connect(merchant).approve(await factory.getAddress(), PRO_PRICE);
      await factory.connect(merchant).purchaseTier(await service.getAddress(), 1);
    });

    it("Should revert to 5% fee after 30 days (Pro Expired)", async function () {
      // 1. Zamanı 31 gün ileri sar
      await time.increase(31 * 24 * 3600);

      // 2. User Subscribes
      await paymentToken.connect(user1).approve(await service.getAddress(), SUB_PRICE);
      
      const balBefore = await paymentToken.balanceOf(platformWallet.address);
      await service.connect(user1).subscribe();
      const balAfter = await paymentToken.balanceOf(platformWallet.address);

      // 3. Check Fee difference (Should include 5% fee)
      const feeAmount = (SUB_PRICE * 500n) / 10000n; // 0.5 USDC
      expect(balAfter - balBefore).to.equal(feeAmount);
    });
  });

  // =========================================================
  // BÖLÜM 5: GÜVENLİK & ADMIN FONKSİYONLARI
  // =========================================================
  describe("5. Security Checks", function () {
    let service, paymentToken, merchant, user1;

    beforeEach(async function () {
      const fix = await loadFixture(deployFixture);
      paymentToken = fix.paymentToken;
      merchant = fix.merchant;
      user1 = fix.user1;

      const tx = await fix.factory.connect(merchant).createService(await paymentToken.getAddress(), SUB_PRICE, INTERVAL);
      const events = await fix.factory.queryFilter(fix.factory.filters.ServiceCreated());
      service = await ethers.getContractAt("SubArcLogicV1", events[0].args[0]);
    });

    it("Only owner can withdraw funds", async function () {
      // Para yükle
      await paymentToken.connect(user1).approve(await service.getAddress(), SUB_PRICE);
      await service.connect(user1).subscribe();

      // User1 denesin -> Revert
      await expect(service.connect(user1).withdrawFunds())
        .to.be.revertedWith("Ownable: caller is not the owner");

      // Merchant denesin -> Success
      await expect(service.connect(merchant).withdrawFunds())
        .to.emit(service, "FundsWithdrawn");
    });

    it("Pause mechanism should block new subscriptions", async function () {
      // Pause et
      await service.connect(merchant).pause();
      
      await paymentToken.connect(user1).approve(await service.getAddress(), SUB_PRICE);
      
      // Subscribe denemesi -> Revert with "Pausable: paused"
      await expect(service.connect(user1).subscribe()).to.be.revertedWith("Pausable: paused");

      // Unpause et
      await service.connect(merchant).unpause();
      
      // Subscribe tekrar dene -> Başarılı
      await expect(service.connect(user1).subscribe()).not.to.be.reverted;
    });

    it("RecoverERC20 cannot steal paymentToken", async function () {
        // PaymentToken çekmeye çalış (recoverERC20 ile)
        // Logic kontratında bu engelli (InvalidToken error)
        await expect(service.connect(merchant).recoverERC20(await paymentToken.getAddress()))
            .to.be.revertedWithCustomError(service, "InvalidToken");
    });
  });
});