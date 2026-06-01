const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

function readManifest(manifestPath) {
  const absolutePath = path.resolve(process.cwd(), manifestPath);

  if (!fs.existsSync(absolutePath)) {
    throw new Error(
      `Deployment manifest not found: ${absolutePath}\nRun "npm run deploy:arc" to generate deployments/arcTestnet.latest.json.`
    );
  }

  const manifest = JSON.parse(fs.readFileSync(absolutePath, "utf8"));
  manifest.__path = absolutePath;
  return manifest;
}

function assertAddress(address, fieldName) {
  if (!address || !ethers.isAddress(address) || address === ethers.ZeroAddress) {
    throw new Error(`Manifest field ${fieldName} is missing or invalid`);
  }
}

function normalizeManifest(manifest) {
  const logicAddress =
    manifest.logicAddress ||
    (manifest.contracts &&
      manifest.contracts.subArcLogicV1 &&
      manifest.contracts.subArcLogicV1.address) ||
    null;
  const factoryAddress =
    manifest.factoryAddress ||
    (manifest.contracts &&
      manifest.contracts.subArcFactoryV1 &&
      manifest.contracts.subArcFactoryV1.address) ||
    null;
  const paymentTokenAddress =
    manifest.paymentTokenAddress ||
    (manifest.paymentToken && manifest.paymentToken.address) ||
    (manifest.contracts &&
      manifest.contracts.subArcFactoryV1 &&
      manifest.contracts.subArcFactoryV1.constructorArgs &&
      manifest.contracts.subArcFactoryV1.constructorArgs.paymentToken) ||
    null;
  const txHashes = {
    logicAddress:
      (manifest.txHashes && manifest.txHashes.logicAddress) ||
      (manifest.contracts &&
        manifest.contracts.subArcLogicV1 &&
        manifest.contracts.subArcLogicV1.deployTransactionHash) ||
      null,
    factoryAddress:
      (manifest.txHashes && manifest.txHashes.factoryAddress) ||
      (manifest.contracts &&
        manifest.contracts.subArcFactoryV1 &&
        manifest.contracts.subArcFactoryV1.deployTransactionHash) ||
      null,
    mockUsdc:
      (manifest.txHashes && manifest.txHashes.mockUsdc) ||
      (manifest.contracts &&
        manifest.contracts.mockUsdc &&
        manifest.contracts.mockUsdc.deployTransactionHash) ||
      null,
  };

  return {
    ...manifest,
    logicAddress,
    factoryAddress,
    paymentTokenAddress,
    deploymentBlock:
      manifest.deploymentBlock ||
      (manifest.rpc && manifest.rpc.blockNumber) ||
      null,
    txHashes,
    paymentToken: {
      kind:
        (manifest.paymentToken && manifest.paymentToken.kind) ||
        "arc-usdc",
      address: paymentTokenAddress,
      decimals:
        (manifest.paymentToken && manifest.paymentToken.decimals) || 6,
      deployedByScript:
        Boolean(manifest.paymentToken && manifest.paymentToken.deployedByScript),
    },
    verification:
      manifest.verification ||
      manifest.verify || {
        commands: {},
      },
  };
}

function isPlaceholderManifest(manifest) {
  return (
    !manifest.deployedAt ||
    !manifest.deployer ||
    !manifest.logicAddress ||
    !manifest.factoryAddress ||
    !manifest.paymentTokenAddress ||
    !manifest.platformWallet ||
    !manifest.txHashes.logicAddress ||
    !manifest.txHashes.factoryAddress
  );
}

function validateManifest(manifest) {
  if (!manifest || manifest.project !== "SubArc") {
    throw new Error("Deployment manifest is not a SubArc manifest");
  }

  const normalized = normalizeManifest(manifest);

  if (isPlaceholderManifest(normalized)) {
    throw new Error(
      `Deployment manifest is still a placeholder or incomplete: ${normalized.__path || "unknown path"}\nRun "npm run deploy:arc" to generate a real deployments/arcTestnet.latest.json.`
    );
  }

  assertAddress(normalized.logicAddress, "logicAddress");
  assertAddress(normalized.factoryAddress, "factoryAddress");
  assertAddress(normalized.paymentTokenAddress, "paymentTokenAddress");
  assertAddress(normalized.platformWallet, "platformWallet");

  if (!normalized.network) {
    throw new Error("Manifest field network is missing");
  }
  if (!normalized.chainId) {
    throw new Error("Manifest field chainId is missing");
  }
  if (!normalized.deploymentBlock) {
    throw new Error("Manifest field deploymentBlock is missing");
  }

  return normalized;
}

module.exports = {
  readManifest,
  normalizeManifest,
  validateManifest,
  isPlaceholderManifest,
};
