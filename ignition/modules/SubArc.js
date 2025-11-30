const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("SubArcModule", (m) => {
  // 1. Deploy MockUSDC
  const usdc = m.contract("MockUSDC", ["Arc Test USDC", "USDC"]);

  // 2. Deploy Logic
  const logic = m.contract("SubArcLogicV1");

  // 3. Deploy Factory
  // Factory, Logic ve USDC adreslerine ihtiyaç duyar
  const factory = m.contract("SubArcFactoryV1", [
    logic, 
    usdc, 
    m.getAccount(0) // Platform Wallet olarak deploy eden cüzdanı atıyoruz
  ]);

  return { usdc, logic, factory };
});