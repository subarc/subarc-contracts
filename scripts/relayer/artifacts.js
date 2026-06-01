const path = require("path");

function getArtifact(contractPath) {
  const artifactPath = path.resolve(
    __dirname,
    "..",
    "..",
    "artifacts",
    "contracts",
    contractPath
  );

  // eslint-disable-next-line global-require, import/no-dynamic-require
  return require(artifactPath);
}

const factoryArtifact = getArtifact(path.join("SubArcFactoryV1.sol", "SubArcFactoryV1.json"));
const logicArtifact = getArtifact(path.join("SubArcLogicV1.sol", "SubArcLogicV1.json"));
const erc20Artifact = require("@openzeppelin/contracts/build/contracts/ERC20.json");

module.exports = {
  factoryAbi: factoryArtifact.abi,
  logicAbi: logicArtifact.abi,
  erc20Abi: erc20Artifact.abi,
};
