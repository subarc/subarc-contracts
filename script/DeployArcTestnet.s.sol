// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubArcFactory} from "../src/SubArcFactory.sol";

interface Vm {
    function envUint(string calldata key) external view returns (uint256);
    function envAddress(string calldata key) external view returns (address);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
    function serializeAddress(string calldata objectKey, string calldata valueKey, address value)
        external
        returns (string memory);
    function serializeUint(string calldata objectKey, string calldata valueKey, uint256 value)
        external
        returns (string memory);
    function writeJson(string calldata json, string calldata path) external;
}

contract DeployArcTestnet {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (SubArcFactory factory) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address feeRecipient = vm.envAddress("SUBARC_FEE_RECIPIENT");
        uint16 feeBps = uint16(vm.envUint("SUBARC_PLATFORM_FEE_BPS"));
        address paymentToken = vm.envAddress("SUBARC_PAYMENT_TOKEN");

        vm.startBroadcast(deployerKey);
        factory = new SubArcFactory(feeRecipient, feeBps);
        factory.setPaymentTokenAllowed(paymentToken, true);
        uint256 deploymentBlock = block.number;
        vm.stopBroadcast();

        string memory deployment = "arc-testnet";
        string memory json = vm.serializeUint(deployment, "chainId", block.chainid);
        json = vm.serializeUint(deployment, "deploymentBlock", deploymentBlock);
        json = vm.serializeAddress(deployment, "factory", address(factory));
        json = vm.serializeAddress(
            deployment, "subscriptionImplementation", factory.subscriptionImplementation()
        );
        json = vm.serializeAddress(deployment, "paymentToken", paymentToken);
        json = vm.serializeAddress(deployment, "feeRecipient", feeRecipient);
        vm.writeJson(json, "deployments/arc-testnet.json");
    }
}
