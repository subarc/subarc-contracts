require("dotenv").config();

const hre = require("hardhat");
const { readManifest, validateManifest } = require("./relayer/manifest");

const DEFAULT_DEMO_PRICE_USDC = "5";
const DEFAULT_DEMO_INTERVAL_SECONDS = 600;

async function main() {
  const manifest = validateManifest(
    readManifest(process.env.DEPLOYMENT_MANIFEST_PATH || "deployments/arcTestnet.latest.json")
  );
  const { ethers } = hre;
  const [merchant] = await ethers.getSigners();
  const provider = ethers.provider;
  const network = await provider.getNetwork();

  if (Number(network.chainId) !== manifest.chainId) {
    throw new Error(
      `Connected chainId ${network.chainId} does not match manifest chainId ${manifest.chainId}`
    );
  }

  const demoPrice = ethers.parseUnits(
    process.env.DEMO_PLAN_PRICE_USDC || DEFAULT_DEMO_PRICE_USDC,
    6
  );
  const demoInterval = Number(
    process.env.DEMO_PLAN_INTERVAL_SECONDS || DEFAULT_DEMO_INTERVAL_SECONDS
  );

  const factory = await ethers.getContractAt("SubArcFactoryV1", manifest.factoryAddress);
  const createServiceTx = await factory
    .connect(merchant)
    ["createService(address)"](manifest.paymentTokenAddress);
  const createServiceReceipt = await createServiceTx.wait();
  const serviceCreatedEvent = createServiceReceipt.logs
    .map((log) => {
      try {
        return factory.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find((parsed) => parsed && parsed.name === "ServiceCreated");

  const serviceAddress = serviceCreatedEvent.args.service;
  const service = await ethers.getContractAt("SubArcLogicV1", serviceAddress);
  const createPlanTx = await service.connect(merchant).createPlan(demoPrice, demoInterval);
  const createPlanReceipt = await createPlanTx.wait();
  const planCreatedEvent = createPlanReceipt.logs
    .map((log) => {
      try {
        return service.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find((parsed) => parsed && parsed.name === "PlanCreated");
  const planId = planCreatedEvent.args.planId;

  console.log("");
  console.log("========================================");
  console.log(" SubArc Arc Testnet Demo Preparation");
  console.log("========================================");
  console.log(`Merchant:           ${merchant.address}`);
  console.log(`Factory:            ${manifest.factoryAddress}`);
  console.log(`Service:            ${serviceAddress}`);
  console.log(`Plan ID:            ${planId}`);
  console.log(`Price:              ${ethers.formatUnits(demoPrice, 6)} USDC`);
  console.log(`Interval:           ${demoInterval} seconds`);
  console.log("----------------------------------------");
  console.log("Expected subscribe parameters:");
  console.log(`planId=${planId}`);
  console.log(`expectedPrice=${demoPrice}`);
  console.log(`expectedInterval=${demoInterval}`);
  console.log("maxFeeBps=1000");
  console.log("----------------------------------------");
  console.log("Next manual subscriber steps:");
  console.log(`1. Approve payment token ${manifest.paymentTokenAddress} to service ${serviceAddress}`);
  console.log(
    `2. Call subscribe(${planId}, ${demoPrice}, ${demoInterval}, 1000) on ${serviceAddress}`
  );
  console.log("3. Run npm run demo:arc:check with SERVICE_ADDRESS and SUBSCRIBER_ADDRESS if needed");
  console.log("========================================");
  console.log("");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
