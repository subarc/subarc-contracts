const fs = require("fs");
const path = require("path");

function defaultState() {
  return {
    metadata: {
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      lastFactoryScanBlock: null,
    },
    services: {},
    plans: {},
    subscriptions: {},
    renewalAttempts: [],
  };
}

function readState(filePath) {
  const absolutePath = path.resolve(process.cwd(), filePath);

  if (!fs.existsSync(absolutePath)) {
    return { absolutePath, state: defaultState() };
  }

  const state = JSON.parse(fs.readFileSync(absolutePath, "utf8"));
  return { absolutePath, state };
}

function writeState(filePath, state) {
  const absolutePath = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(absolutePath), { recursive: true });
  state.metadata.updatedAt = new Date().toISOString();
  fs.writeFileSync(absolutePath, JSON.stringify(state, null, 2));
}

function planKey(serviceAddress, planId) {
  return `${serviceAddress.toLowerCase()}:${String(planId)}`;
}

function subscriptionKey(serviceAddress, userAddress) {
  return `${serviceAddress.toLowerCase()}:${userAddress.toLowerCase()}`;
}

function pushRenewalAttempt(state, attempt) {
  state.renewalAttempts.push(attempt);
  if (state.renewalAttempts.length > 5000) {
    state.renewalAttempts = state.renewalAttempts.slice(-5000);
  }
}

module.exports = {
  defaultState,
  readState,
  writeState,
  planKey,
  subscriptionKey,
  pushRenewalAttempt,
};
