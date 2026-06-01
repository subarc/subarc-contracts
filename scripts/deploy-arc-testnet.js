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

function buildVerificationCommands(networkName, logicAddress, factoryAddress, paymentTokenAddress, platformWallet, mockInfo) {
  return {
    logicAddress: `npx hardhat verify --network ${networkName} ${logicAddress}`,
    factoryAddress: `npx hardhat verify --network ${networkName} ${factoryAddress} "${logicAddress}" "${paymentTokenAddress}" "${platformWallet}"`,
    mockUsdc: mockInfo
      ? `npx hardhat verify --network ${networkName} ${mockInfo.address} "${mockInfo.name}" "${mockInfo.symbol}"`
      : null,
  };
}

async function main() {
  const { ethers, network } = hre;
  const [deployer] = await ethers.getSigners();
  const provider = ethers.provider;
  const feeData = await provider.getFeeData();
  const networkInfo = await provider.getNetwork();

  const platformWallet = process.env.PLATFORM_WALLET || deployer.address;
  const deployMockUsdc =
    asBool(process.env.DEPLOY_MOCK_USDC, false) || network.name === "hardhat";

  let paymentTokenAddress = process.env.ARC_USDC_ADDRESS || DEFAULT_ARC_USDC;
  let paymentTokenKind = "arc-usdc";
  let mockUsdc = null;
  let mockInfo = null;

  if (deployMockUsdc) {
    const mockName = process.env.MOCK_USDC_NAME || "Arc Test USDC";
    const mockSymbol = process.env.MOCK_USDC_SYMBOL || "USDC";
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUsdc = await MockUSDC.deploy(mockName, mockSymbol);
    await mockUsdc.waitForDeployment();
    paymentTokenAddress = await mockUsdc.getAddress();
    paymentTokenKind = "mock-usdc";
    mockInfo = {
      address: paymentTokenAddress,
      name: mockName,
      symbol: mockSymbol,
      deployTransactionHash: mockUsdc.deploymentTransaction().hash,
    };
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

  const latestBlock = await provider.getBlock("latest");
  const verificationCommands = buildVerificationCommands(
    network.name,
    await logic.getAddress(),
    await factory.getAddress(),
    paymentTokenAddress,
    platformWallet,
    mockInfo
  );

  const manifest = {
    project: "SubArc",
    environment: "arc-testnet-mvp",
    network: network.name,
    chainId: Number(networkInfo.chainId),
    expectedArcChainId: Number(ARC_CHAIN_ID),
    logicAddress: await logic.getAddress(),
    factoryAddress: await factory.getAddress(),
    paymentTokenAddress,
    platformWallet,
    deploymentBlock: latestBlock ? latestBlock.number : null,
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
    txHashes: {
      logicAddress: logic.deploymentTransaction().hash,
      factoryAddress: factory.deploymentTransaction().hash,
      mockUsdc: mockInfo ? mockInfo.deployTransactionHash : null,
    },
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
      mockUsdc: mockInfo
        ? {
            address: mockInfo.address,
            deployTransactionHash: mockInfo.deployTransactionHash,
          }
        : null,
    },
    rpc: {
      url: process.env.ARC_RPC_URL || "https://rpc.testnet.arc.network",
      blockNumber: latestBlock ? latestBlock.number : null,
      gasPriceWei: feeData.gasPrice ? feeData.gasPrice.toString() : null,
    },
    verification: {
      explorer: process.env.ARCSCAN_BROWSER_URL || "https://testnet.arcscan.app",
      apiUrl: process.env.ARCSCAN_API_URL || "https://testnet.arcscan.app/api",
      commands: verificationCommands,
    },
    verify: {
      explorer: process.env.ARCSCAN_BROWSER_URL || "https://testnet.arcscan.app",
      apiUrl: process.env.ARCSCAN_API_URL || "https://testnet.arcscan.app/api",
      commands: verificationCommands,
    },
  };

  const outFile =
    process.env.DEPLOYMENT_OUTFILE ||
    path.join("deployments", `${network.name}.latest.json`);
  const absoluteOutFile = path.resolve(process.cwd(), outFile);

  fs.mkdirSync(path.dirname(absoluteOutFile), { recursive: true });
  fs.writeFileSync(absoluteOutFile, JSON.stringify(manifest, null, 2));

  console.log("SubArc MVP deployment complete");
  console.log(`Network:        ${network.name} (${networkInfo.chainId})`);
  console.log(`Logic address:  ${manifest.logicAddress}`);
  console.log(`Factory:        ${manifest.factoryAddress}`);
  console.log(`Payment token:  ${manifest.paymentTokenAddress} [${manifest.paymentToken.kind}]`);
  console.log(`PlatformWallet: ${manifest.platformWallet}`);
  console.log(`Block:          ${manifest.deploymentBlock}`);
  console.log(`Manifest:       ${absoluteOutFile}`);
  console.log("");
  console.log("Verification commands:");
  console.log(`- Logic:   ${verificationCommands.logicAddress}`);
  console.log(`- Factory: ${verificationCommands.factoryAddress}`);
  if (verificationCommands.mockUsdc) {
    console.log(`- MockUSDC:${verificationCommands.mockUsdc}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
