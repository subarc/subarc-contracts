const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

function readManifest(manifestPath) {
  const absolutePath = path.resolve(process.cwd(), manifestPath);

  if (!fs.existsSync(absolutePath)) {
    throw new Error(`Deployment manifest not found: ${absolutePath}`);
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

function validateManifest(manifest) {
  if (!manifest || manifest.project !== "SubArc") {
    throw new Error("Deployment manifest is not a SubArc manifest");
  }

  if (!manifest.deployedAt) {
    throw new Error("Deployment manifest is still a placeholder: deployedAt is null");
  }

  assertAddress(manifest.paymentToken && manifest.paymentToken.address, "paymentToken.address");
  assertAddress(
    manifest.contracts &&
      manifest.contracts.subArcLogicV1 &&
      manifest.contracts.subArcLogicV1.address,
    "contracts.subArcLogicV1.address"
  );
  assertAddress(
    manifest.contracts &&
      manifest.contracts.subArcFactoryV1 &&
      manifest.contracts.subArcFactoryV1.address,
    "contracts.subArcFactoryV1.address"
  );

  if (!manifest.contracts.subArcLogicV1.deployTransactionHash) {
    throw new Error("Deployment manifest is still a placeholder: logic deploy tx hash is null");
  }

  if (!manifest.contracts.subArcFactoryV1.deployTransactionHash) {
    throw new Error("Deployment manifest is still a placeholder: factory deploy tx hash is null");
  }

  if (!manifest.platformWallet) {
    throw new Error("Deployment manifest is missing platformWallet");
  }

  return manifest;
}

module.exports = {
  readManifest,
  validateManifest,
};
