const fs = require("fs");
const os = require("os");
const path = require("path");
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { validateManifest } = require("../scripts/relayer/manifest");
const { defaultState } = require("../scripts/relayer/store");
const { SubArcRelayerService } = require("../scripts/relayer/service");

describe("SubArc relayer/indexer MVP service", function () {
  const SUB_PRICE = ethers.parseUnits("10", 6);
  const MONTH = 30 * 24 * 3600;

  async function deployFixture() {
    const [owner, platformWallet, merchant, subscriber, relayer, other] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("MockUSDC");
    const paymentToken = await MockToken.deploy("Mock USDC", "mUSDC");

    const Logic = await ethers.getContractFactory("SubArcLogicV1");
    const logicImpl = await Logic.deploy();

    const Factory = await ethers.getContractFactory("SubArcFactoryV1");
    const factory = await Factory.deploy(
      await logicImpl.getAddress(),
      await paymentToken.getAddress(),
      platformWallet.address
    );

    await paymentToken.mint(subscriber.address, ethers.parseUnits("1000", 6));
    await paymentToken.mint(other.address, ethers.parseUnits("1000", 6));

    return { owner, platformWallet, merchant, subscriber, relayer, other, paymentToken, logicImpl, factory };
  }

  async function createService(txPromise, factory) {
    const tx = await txPromise;
    await tx.wait();
    const events = await factory.queryFilter(factory.filters.ServiceCreated());
    return ethers.getContractAt("SubArcLogicV1", events.at(-1).args[0]);
  }

  function buildManifest({ paymentToken, logicImpl, factory, platformWallet }) {
    return {
      project: "SubArc",
      environment: "arc-testnet-mvp",
      network: "hardhat",
      chainId: 31337,
      expectedArcChainId: 5042002,
      logicAddress: logicImpl.target,
      factoryAddress: factory.target,
      paymentTokenAddress: paymentToken.target,
      deploymentBlock: 1,
      deployedAt: new Date().toISOString(),
      deployer: platformWallet.address,
      platformWallet: platformWallet.address,
      txHashes: {
        logicAddress: logicImpl.deploymentTransaction().hash,
        factoryAddress: factory.deploymentTransaction().hash,
        mockUsdc: paymentToken.deploymentTransaction().hash,
      },
      paymentToken: {
        kind: "mock-usdc",
        address: paymentToken.target,
        decimals: 6,
        deployedByScript: true,
      },
      contracts: {
        subArcLogicV1: {
          address: logicImpl.target,
          deployTransactionHash: logicImpl.deploymentTransaction().hash,
        },
        subArcFactoryV1: {
          address: factory.target,
          deployTransactionHash: factory.deploymentTransaction().hash,
          constructorArgs: {
            implementation: logicImpl.target,
            paymentToken: paymentToken.target,
            platformWallet: platformWallet.address,
          },
        },
        mockUsdc: {
          address: paymentToken.target,
          deployTransactionHash: paymentToken.deploymentTransaction().hash,
        },
      },
      rpc: {
        url: "http://127.0.0.1:8545",
        blockNumber: 0,
        gasPriceWei: null,
      },
    };
  }

  it("rejects placeholder deployment manifests", async function () {
    const placeholder = JSON.parse(
      fs.readFileSync(
        path.resolve(__dirname, "..", "deployments", "arcTestnet.example.json"),
        "utf8"
      )
    );

    expect(() => validateManifest(placeholder))
      .to.throw("Deployment manifest is still a placeholder or incomplete");
  });

  it("indexes events and renews due subscriptions once", async function () {
    const { paymentToken, logicImpl, factory, platformWallet, merchant, subscriber, relayer } =
      await loadFixture(deployFixture);

    const service = await createService(
      factory.connect(merchant)["createService(address,uint256,uint256)"](
        await paymentToken.getAddress(),
        SUB_PRICE,
        MONTH
      ),
      factory
    );

    await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE * 2n);
    await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, 1000);

    const manifest = buildManifest({ paymentToken, logicImpl, factory, platformWallet });
    const relayerService = new SubArcRelayerService({
      provider: ethers.provider,
      signer: relayer,
      manifest,
      state: defaultState(),
    });

    const scanResult = await relayerService.scan();
    expect(scanResult.factoryResult.servicesDiscovered).to.equal(1);
    expect(Object.keys(relayerService.state.services)).to.have.length(1);
    expect(Object.keys(relayerService.state.plans)).to.have.length(1);
    expect(Object.keys(relayerService.state.subscriptions)).to.have.length(1);

    const firstExpiry = (await service.getSubscriptionDetails(subscriber.address)).expiry;
    await time.increaseTo(firstExpiry + 1n);

    const renewalResults = await relayerService.renewDueSubscriptions();
    expect(renewalResults).to.have.length(1);
    expect(renewalResults[0].status).to.equal("submitted");
    expect(renewalResults[0].txHash).to.be.a("string");

    const updated = await service.getSubscriptionDetails(subscriber.address);
    expect(updated.expiry).to.be.gt(firstExpiry);
    expect(relayerService.state.renewalAttempts).to.have.length(1);
  });

  it("skips renewals when allowance is insufficient and stores the failure reason", async function () {
    const { paymentToken, logicImpl, factory, platformWallet, merchant, subscriber, relayer } =
      await loadFixture(deployFixture);

    const service = await createService(
      factory.connect(merchant)["createService(address,uint256,uint256)"](
        await paymentToken.getAddress(),
        SUB_PRICE,
        MONTH
      ),
      factory
    );

    await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);
    await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, 1000);
    await paymentToken.connect(subscriber).approve(await service.getAddress(), 0);

    const manifest = buildManifest({ paymentToken, logicImpl, factory, platformWallet });
    const relayerService = new SubArcRelayerService({
      provider: ethers.provider,
      signer: relayer,
      manifest,
      state: defaultState(),
    });

    await relayerService.scan();
    const expiry = (await service.getSubscriptionDetails(subscriber.address)).expiry;
    await time.increaseTo(expiry + 1n);

    const results = await relayerService.renewDueSubscriptions();
    expect(results).to.have.length(1);
    expect(results[0].status).to.equal("skipped");
    expect(results[0].failureReason).to.equal("insufficient-allowance");
  });

  it("builds a status summary from local relayer state", async function () {
    const { paymentToken, logicImpl, factory, platformWallet, merchant, subscriber, relayer } =
      await loadFixture(deployFixture);

    const service = await createService(
      factory.connect(merchant)["createService(address,uint256,uint256)"](
        await paymentToken.getAddress(),
        SUB_PRICE,
        MONTH
      ),
      factory
    );

    await paymentToken.connect(subscriber).approve(await service.getAddress(), SUB_PRICE);
    await service.connect(subscriber).subscribe(1, SUB_PRICE, MONTH, 1000);

    const manifest = buildManifest({ paymentToken, logicImpl, factory, platformWallet });
    const relayerService = new SubArcRelayerService({
      provider: ethers.provider,
      signer: relayer,
      manifest,
      state: defaultState(),
    });

    await relayerService.scan();
    const summary = await relayerService.getStatusSummary();
    expect(summary.network).to.equal("hardhat");
    expect(summary.factoryAddress).to.equal(factory.target);
    expect(summary.services).to.equal(1);
    expect(summary.plans).to.equal(1);
    expect(summary.activeSubscriptions).to.equal(1);
  });

  it("can read a real manifest path when present", async function () {
    const { paymentToken, logicImpl, factory, platformWallet } = await loadFixture(deployFixture);
    const manifest = buildManifest({ paymentToken, logicImpl, factory, platformWallet });

    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "subarc-manifest-"));
    const filePath = path.join(tempDir, "manifest.json");
    fs.writeFileSync(filePath, JSON.stringify(manifest, null, 2));

    const parsed = JSON.parse(fs.readFileSync(filePath, "utf8"));
    const validated = validateManifest(parsed);
    expect(validated.factoryAddress).to.equal(factory.target);
  });
});
