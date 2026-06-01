const hre = require("hardhat");

const DEMO_PRICE = 10n * 10n ** 6n;
const DEMO_INTERVAL = 5 * 60;
const MAX_FEE_BPS = 1000;

function formatUsdc(amount) {
  return `${hre.ethers.formatUnits(amount, 6)} USDC`;
}

async function main() {
  const { ethers, network } = hre;
  const [deployer, platformWallet, merchant, subscriber, relayer] = await ethers.getSigners();

  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const mockUsdc = await MockUSDC.deploy("Arc Test USDC", "USDC");
  await mockUsdc.waitForDeployment();

  const Logic = await ethers.getContractFactory("SubArcLogicV1");
  const logic = await Logic.deploy();
  await logic.waitForDeployment();

  const Factory = await ethers.getContractFactory("SubArcFactoryV1");
  const factory = await Factory.deploy(
    await logic.getAddress(),
    await mockUsdc.getAddress(),
    platformWallet.address
  );
  await factory.waitForDeployment();

  await mockUsdc.mint(subscriber.address, ethers.parseUnits("1000", 6));

  const createServiceTx = await factory
    .connect(merchant)
    ["createService(address)"](await mockUsdc.getAddress());
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

  const createPlanTx = await service.connect(merchant).createPlan(DEMO_PRICE, DEMO_INTERVAL);
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

  await mockUsdc.connect(subscriber).approve(await service.getAddress(), DEMO_PRICE * 2n);

  const subscribeTx = await service
    .connect(subscriber)
    .subscribe(planId, DEMO_PRICE, DEMO_INTERVAL, MAX_FEE_BPS);
  await subscribeTx.wait();

  const beforeRenewal = await service.getSubscriptionDetails(subscriber.address);
  const protocolFeeBeforeRenew = await mockUsdc.balanceOf(platformWallet.address);
  const merchantBalanceBeforeWithdraw = await mockUsdc.balanceOf(merchant.address);

  await network.provider.send("evm_increaseTime", [DEMO_INTERVAL + 5]);
  await network.provider.send("evm_mine");

  const renewTx = await service.connect(relayer).renew(subscriber.address);
  await renewTx.wait();

  const afterRenewal = await service.getSubscriptionDetails(subscriber.address);
  const protocolFeeAfterRenew = await mockUsdc.balanceOf(platformWallet.address);
  const serviceEscrowBalance = await mockUsdc.balanceOf(await service.getAddress());

  const withdrawTx = await service.connect(merchant).withdrawFunds();
  await withdrawTx.wait();
  const merchantBalanceAfterWithdraw = await mockUsdc.balanceOf(merchant.address);

  const merchantWithdrawAmount = merchantBalanceAfterWithdraw - merchantBalanceBeforeWithdraw;
  const protocolFeeAmount = protocolFeeAfterRenew - protocolFeeBeforeRenew;

  console.log("");
  console.log("========================================");
  console.log(" SubArc Local MVP Demo");
  console.log("========================================");
  console.log(`Payment token:       ${await mockUsdc.getAddress()} (Mock USDC)`);
  console.log(`Logic address:       ${await logic.getAddress()}`);
  console.log(`Factory address:     ${await factory.getAddress()}`);
  console.log(`Service address:     ${serviceAddress}`);
  console.log(`Plan ID:             ${planId}`);
  console.log(`Plan price:          ${formatUsdc(DEMO_PRICE)}`);
  console.log(`Plan interval:       ${DEMO_INTERVAL} seconds`);
  console.log("----------------------------------------");
  console.log(`Subscriber expiry 1: ${beforeRenewal.expiry}`);
  console.log(`Subscriber expiry 2: ${afterRenewal.expiry}`);
  console.log(`Renewal tx hash:     ${renewTx.hash}`);
  console.log(`Protocol fee delta:  ${formatUsdc(protocolFeeAmount)}`);
  console.log(`Merchant withdraw:   ${formatUsdc(merchantWithdrawAmount)}`);
  console.log(`Service escrow pre-withdraw: ${formatUsdc(serviceEscrowBalance)}`);
  console.log("----------------------------------------");
  console.log("Flow completed:");
  console.log("1. MockUSDC deployed");
  console.log("2. SubArc logic + factory deployed");
  console.log("3. Merchant service created");
  console.log("4. Paid plan created");
  console.log("5. Subscriber approved and subscribed");
  console.log("6. Time advanced past expiry");
  console.log("7. Relayer-like renew(user) executed");
  console.log("8. Merchant withdrew accumulated proceeds");
  console.log("========================================");
  console.log("");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
