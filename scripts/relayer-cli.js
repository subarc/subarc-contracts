require("dotenv").config();

const path = require("path");
const { ethers } = require("ethers");
const { readManifest, validateManifest } = require("./relayer/manifest");
const { readState, writeState } = require("./relayer/store");
const { SubArcRelayerService } = require("./relayer/service");

const DEFAULT_MANIFEST_PATH = "deployments/arcTestnet.latest.json";
const DEFAULT_STORE_PATH = "relayer-data/state.json";
const DEFAULT_SCAN_INTERVAL_SECONDS = 60;

function getConfig() {
  return {
    manifestPath: process.env.DEPLOYMENT_MANIFEST_PATH || DEFAULT_MANIFEST_PATH,
    storePath: process.env.RELAYER_STORE_PATH || DEFAULT_STORE_PATH,
    rpcUrl: process.env.ARC_RPC_URL || null,
    relayerPrivateKey: process.env.RELAYER_PRIVATE_KEY || null,
    scanIntervalSeconds: Number(
      process.env.RENEWAL_SCAN_INTERVAL_SECONDS || DEFAULT_SCAN_INTERVAL_SECONDS
    ),
  };
}

async function buildRuntime(command) {
  const config = getConfig();
  const manifest = validateManifest(readManifest(config.manifestPath));
  const rpcUrl = config.rpcUrl || (manifest.rpc && manifest.rpc.url);

  if (!rpcUrl) {
    throw new Error("ARC_RPC_URL is required when the manifest does not include an RPC URL");
  }

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  let signer = null;

  if (command !== "scan") {
    if (!config.relayerPrivateKey) {
      throw new Error("RELAYER_PRIVATE_KEY is required for relayer:once and relayer:loop");
    }
    signer = new ethers.Wallet(config.relayerPrivateKey, provider);
  }

  const { absolutePath: statePath, state } = readState(config.storePath);
  const service = new SubArcRelayerService({
    provider,
    signer,
    manifest,
    state,
  });

  return {
    config,
    manifest,
    provider,
    signer,
    statePath,
    state,
    service,
  };
}

async function runScan(runtime) {
  const result = await runtime.service.scan();
  writeState(runtime.statePath, runtime.state);
  console.log(
    JSON.stringify(
      {
        command: "scan",
        manifest: path.resolve(runtime.manifest.__path),
        statePath: runtime.statePath,
        result,
      },
      null,
      2
    )
  );
}

async function runOnce(runtime) {
  const scanResult = await runtime.service.scan();
  const renewalResults = await runtime.service.renewDueSubscriptions();
  writeState(runtime.statePath, runtime.state);
  console.log(
    JSON.stringify(
      {
        command: "once",
        manifest: path.resolve(runtime.manifest.__path),
        statePath: runtime.statePath,
        scanResult,
        renewalResults,
      },
      null,
      2
    )
  );
}

async function runLoop(runtime) {
  const intervalMs = runtime.config.scanIntervalSeconds * 1000;

  if (!Number.isFinite(intervalMs) || intervalMs <= 0) {
    throw new Error("RENEWAL_SCAN_INTERVAL_SECONDS must be a positive number");
  }

  console.log(
    `SubArc relayer loop started. Manifest=${runtime.manifest.__path} Store=${runtime.statePath} Interval=${runtime.config.scanIntervalSeconds}s`
  );

  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      const scanResult = await runtime.service.scan();
      const renewalResults = await runtime.service.renewDueSubscriptions();
      writeState(runtime.statePath, runtime.state);
      console.log(
        JSON.stringify(
          {
            timestamp: new Date().toISOString(),
            scanResult,
            renewalResults,
          },
          null,
          2
        )
      );
    } catch (error) {
      console.error(error);
    }

    await new Promise((resolve) => {
      setTimeout(resolve, intervalMs);
    });
  }
}

async function main() {
  const command = process.argv[2];

  if (!["scan", "once", "loop"].includes(command)) {
    throw new Error("Usage: node scripts/relayer-cli.js <scan|once|loop>");
  }

  const runtime = await buildRuntime(command);

  if (command === "scan") {
    await runScan(runtime);
    return;
  }

  if (command === "once") {
    await runOnce(runtime);
    return;
  }

  await runLoop(runtime);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
