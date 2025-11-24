const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("ArcSubscription Upgrade Test", function () {
  let owner, user;
  let V1, V2;
  let proxy;

  beforeEach(async function () {
    [owner, user] = await ethers.getSigners();

    // V1 kontratını yükle
    V1 = await ethers.getContractFactory("ArcSubscriptionV1");

    // V1'i proxy ile deploy et
    proxy = await upgrades.deployProxy(V1, [], {
      kind: "uups",
      initializer: "initialize",
    });
    await proxy.waitForDeployment();

    // V1'deki başlangıç değerlerini doğrula
    const price = await proxy.subscriptionPrice();
    const interval = await proxy.interval();

    expect(price).to.equal(2n * 10n ** 6n); // 2 USDC
    expect(interval).to.equal(60n);
  });

  it("should upgrade from V1 to V2 and preserve storage", async function () {
    // V2 kontratını al
    V2 = await ethers.getContractFactory("ArcSubscriptionV2_Safe");

    // Upgrade et
    const proxyV2 = await upgrades.upgradeProxy(await proxy.getAddress(), V2);

    // V1 değerleri hala duruyor mu?
    const priceAfter = await proxyV2.subscriptionPrice();
    const intervalAfter = await proxyV2.interval();

    expect(priceAfter).to.equal(2n * 10n ** 6n);
    expect(intervalAfter).to.equal(60n);

    // initializeV2 (reinitializer(2)) çağır
    await proxyV2.initializeV2();

    // Yeni değişkenler doğru mu?
    expect(await proxyV2.gracePeriod()).to.equal(0n);
    expect(await proxyV2.isSystemPaused()).to.equal(false);

    // USDC adresi 0x0 olmamalı
    const usdc = await proxyV2.usdc();
    expect(usdc).to.not.equal(ethers.ZeroAddress);

    // Version string
    const version = await proxyV2.getVersion();
    // Kontratın gerçek çıktısına göre assert
    expect(version).to.equal("Version 2.0 - Safe & Secure");
  });

  it("should restrict pause/unpause to owner", async function () {
    V2 = await ethers.getContractFactory("ArcSubscriptionV2_Safe");
    const proxyV2 = await upgrades.upgradeProxy(await proxy.getAddress(), V2);

    await proxyV2.initializeV2();

    // Başlangıçta paused olmamalı
    expect(await proxyV2.isSystemPaused()).to.equal(false);

    // ❌ Pause → user çağırınca revert etmeli
    try {
      await proxyV2.connect(user).pause();
      expect.fail("Non-owner should not be able to pause");
    } catch (err) {
      expect(err.message).to.include("Ownable: caller is not the owner");
    }

    // ✅ Owner pause edebilmeli
    await proxyV2.pause();
    expect(await proxyV2.isSystemPaused()).to.equal(true);

    // ❌ Unpause → user çağırınca revert etmeli
    try {
      await proxyV2.connect(user).unpause();
      expect.fail("Non-owner should not be able to unpause");
    } catch (err) {
      expect(err.message).to.include("Ownable: caller is not the owner");
    }

    // ✅ Owner unpause edebilmeli
    await proxyV2.unpause();
    expect(await proxyV2.isSystemPaused()).to.equal(false);
  });
});
