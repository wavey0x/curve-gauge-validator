// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";

/// @notice Deploys the fully configured, governance-owned validator in one transaction.
contract DeployGaugeValidator is Script {
    uint256 public constant MAINNET_CHAIN_ID = 1;

    error WrongChain(uint256 chainId);
    error DeploymentInvariantFailed();

    function run() external returns (GaugeValidator validator) {
        if (block.chainid != MAINNET_CHAIN_ID) revert WrongChain(block.chainid);

        vm.startBroadcast();
        validator = new GaugeValidator(MainnetGaugeConfiguration.OWNER, MainnetGaugeConfiguration.bindings());
        vm.stopBroadcast();

        _assertDeployment(validator);
    }

    function _assertDeployment(GaugeValidator validator) private view {
        if (validator.owner() != MainnetGaugeConfiguration.OWNER) revert DeploymentInvariantFailed();

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings();
        for (uint256 i; i < bindings.length; ++i) {
            if (validator.proofForFactory(bindings[i].factory) != bindings[i].proof) {
                revert DeploymentInvariantFailed();
            }
        }
    }
}
