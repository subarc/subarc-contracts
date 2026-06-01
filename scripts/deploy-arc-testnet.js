const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const ARC_CHAIN_ID = 5042002n;
const DEFAULT_ARC_USDC = "0x3600000000000000000000000000000000000000";

function asBool(value, fallback = false) {
  if (value == null || value === "") {
    return fallback;
  }

  return ["1", "true", "yes", "on"].includes(String(value).toLowerCase());
}

async function ensureHasCode(address, label, provider) {
  const code = await provider.getCode(address);
  if (code === "0x") {
    throw new Error(`${label} has no code at ${address}`);
  }
}

async function main() {
  const { ethers, network } = hre;
  const [deployer] = await ethers.getSigners();
  const provider = ethers.provider;
  const feeData = await provider.getFeeData();
  const latestBlock = await provider.getBlock("latest");
  const networkInfo = await provider.getNetwork();

  const platformWallet = process.env.PLATFORM_WALLET || deployer.address;
  const deployMockUsdc =
    asBool(process.env.DEPLOY_MOCK_USDC, false) || network.name === "hardhat";

  let paymentTokenAddress = process.env.ARC_USDC_ADDRESS || DEFAULT_ARC_USDC;
  let paymentTokenKind = "arc-usdc";
  let mockUsdc = null;

  if (deployMockUsdc) {
    const mockName = process.env.MOCK_USDC_NAME || "Arc Test USDC";
    const mockSymbol = process.env.MOCK_USDC_SYMBOL || "USDC";
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUsdc = await MockUSDC.deploy(mockName, mockSymbol);
    await mockUsdc.waitForDeployment();
    paymentTokenAddress = await mockUsdc.getAddress();
    paymentTokenKind = "mock-usdc";
  } else {
    await ensureHasCode(paymentTokenAddress, "Payment token", provider);
  }

  const Logic = await ethers.getContractFactory("SubArcLogicV1");
  const logic = await Logic.deploy();
  await logic.waitForDeployment();

  const Factory = await ethers.getContractFactory("SubArcFactoryV1");
  const factory = await Factory.deploy(
    await logic.getAddress(),
    paymentTokenAddress,
    platformWallet
  );
  await factory.waitForDeployment();

  const manifest = {
    project: "SubArc",
    environment: "arc-testnet-mvp",
    network: network.name,
    chainId: Number(networkInfo.chainId),
    expectedArcChainId: Number(ARC_CHAIN_ID),
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
    platformWallet,
    paymentToken: {
      kind: paymentTokenKind,
      address: paymentTokenAddress,
      decimals: 6,
      deployedByScript: Boolean(mockUsdc),
    },
    contracts: {
      subArcLogicV1: {
        address: await logic.getAddress(),
        deployTransactionHash: logic.deploymentTransaction().hash,
      },
      subArcFactoryV1: {
        address: await factory.getAddress(),
        deployTransactionHash: factory.deploymentTransaction().hash,
        constructorArgs: {
          implementation: await logic.getAddress(),
          paymentToken: paymentTokenAddress,
          platformWallet,
        },
      },
      mockUsdc: mockUsdc
        ? {
            address: paymentTokenAddress,
            deployTransactionHash: mockUsdc.deploymentTransaction().hash,
          }
        : null,
    },
    rpc: {
      url: process.env.ARC_RPC_URL || "https://rpc.testnet.arc.network",
      blockNumber: latestBlock ? latestBlock.number : null,
      gasPriceWei: feeData.gasPrice ? feeData.gasPrice.toString() : null,
    },
    verify: {
      explorer: process.env.ARCSCAN_BROWSER_URL || "https://testnet.arcscan.app",
      apiUrl: process.env.ARCSCAN_API_URL || "https://testnet.arcscan.app/api",
      commands: {
        subArcLogicV1: `npx hardhat verify --network ${network.name} ${await logic.getAddress()}`,
        subArcFactoryV1: `npx hardhat verify --network ${network.name} ${await factory.getAddress()} "${await logic.getAddress()}" "${paymentTokenAddress}" "${platformWallet}"`,
        mockUsdc: mockUsdc
          ? `npx hardhat verify --network ${network.name} ${paymentTokenAddress} "${process.env.MOCK_USDC_NAME || "Arc Test USDC"}" "${process.env.MOCK_USDC_SYMBOL || "USDC"}"`
          : null,
      },
    },
  };

  const outFile =
    process.env.DEPLOYMENT_OUTFILE ||
    path.join("deployments", `${network.name}.latest.json`);
  const absoluteOutFile = path.resolve(process.cwd(), outFile);

  fs.mkdirSync(path.dirname(absoluteOutFile), { recursive: true });
  fs.writeFileSync(absoluteOutFile, JSON.stringify(manifest, null, 2));

  console.log("SubArc MVP deployment complete");
  console.log(`Network: ${network.name} (${networkInfo.chainId})`);
  console.log(`Logic:   ${manifest.contracts.subArcLogicV1.address}`);
  console.log(`Factory: ${manifest.contracts.subArcFactoryV1.address}`);
  console.log(`Token:   ${manifest.paymentToken.address} [${manifest.paymentToken.kind}]`);
  console.log(`Manifest written to ${absoluteOutFile}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
