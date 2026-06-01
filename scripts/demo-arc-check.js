require("dotenv").config();

const hre = require("hardhat");
const { readManifest, validateManifest } = require("./relayer/manifest");
const { DEFAULT_RENEWAL_GRACE_PERIOD_SECONDS } = require("./relayer/service");

async function main() {
  const manifest = validateManifest(
    readManifest(process.env.DEPLOYMENT_MANIFEST_PATH || "deployments/arcTestnet.latest.json")
  );
  const { ethers } = hre;
  const serviceAddress = process.env.SERVICE_ADDRESS;
  const subscriberAddress = process.env.SUBSCRIBER_ADDRESS;

  if (!serviceAddress) {
    throw new Error(
      "SERVICE_ADDRESS is required for demo:arc:check.\nSet SERVICE_ADDRESS=<merchant service address> and optionally SUBSCRIBER_ADDRESS=<subscriber>."
    );
  }

  const factory = await ethers.getContractAt("SubArcFactoryV1", manifest.factoryAddress);
  const service = await ethers.getContractAt("SubArcLogicV1", serviceAddress);
  const paymentToken = await ethers.getContractAt("MockUSDC", manifest.paymentTokenAddress);

  const owner = await service.owner();
  const defaultPlanId = await service.defaultPlanId();
  const plan = defaultPlanId > 0n ? await service.getPlan(defaultPlanId) : null;

  let subscription = null;
  let remainingTime = null;
  let due = null;
  let shouldRenew = null;

  if (subscriberAddress) {
    subscription = await service.getSubscriptionDetails(subscriberAddress);
    remainingTime = await service.getRemainingTime(subscriberAddress);
    const now = BigInt((await ethers.provider.getBlock("latest")).timestamp);
    due =
      subscription.expiry > 0n &&
      !subscription.canceled &&
      subscription.expiry <= now;
    shouldRenew =
      due &&
      now <= subscription.expiry + DEFAULT_RENEWAL_GRACE_PERIOD_SECONDS;
  }

  const merchantWithdrawableBalance = await paymentToken.balanceOf(serviceAddress);
  const protocolFeeBalance = await paymentToken.balanceOf(manifest.platformWallet);
  const currentFeeBps = await factory.getCurrentFeeBps(serviceAddress);

  console.log("");
  console.log("========================================");
  console.log(" SubArc Arc Testnet Demo Check");
  console.log("========================================");
  console.log(`Factory:            ${manifest.factoryAddress}`);
  console.log(`Service:            ${serviceAddress}`);
  console.log(`Service owner:      ${owner}`);
  console.log(`Current fee bps:    ${currentFeeBps}`);
  if (plan) {
    console.log(`Default plan ID:    ${defaultPlanId}`);
    console.log(`Plan price:         ${ethers.formatUnits(plan.price, 6)} USDC`);
    console.log(`Plan interval:      ${plan.interval} seconds`);
    console.log(`Plan active:        ${plan.isActive}`);
  } else {
    console.log("Default plan:       none");
  }
  if (subscriberAddress && subscription) {
    console.log("----------------------------------------");
    console.log(`Subscriber:         ${subscriberAddress}`);
    console.log(`Subscription plan:  ${subscription.planId}`);
    console.log(`Expiry:             ${subscription.expiry}`);
    console.log(`Canceled:           ${subscription.canceled}`);
    console.log(`Agreed price:       ${subscription.agreedPrice}`);
    console.log(`Agreed interval:    ${subscription.agreedInterval}`);
    console.log(`Max fee bps:        ${subscription.maxFeeBps}`);
    console.log(`Remaining time:     ${remainingTime} seconds`);
    console.log(`Due now:            ${due}`);
    console.log(`Relayer should renew:${shouldRenew}`);
  } else {
    console.log("----------------------------------------");
    console.log("Subscriber details: skipped (set SUBSCRIBER_ADDRESS to inspect)");
  }
  console.log("----------------------------------------");
  console.log(
    `Merchant withdrawable: ${ethers.formatUnits(merchantWithdrawableBalance, 6)} USDC`
  );
  console.log(
    `Protocol fee balance:  ${ethers.formatUnits(protocolFeeBalance, 6)} USDC`
  );
  console.log("========================================");
  console.log("");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
