// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalValidationModuleV1} from "../src/ProposalValidationModuleV1.sol";

/// @notice Reads the deployed validator configuration without mutating state.
contract InspectGaugeValidator is Script {
    uint256 public constant MAINNET_CHAIN_ID = 1;

    error WrongChain(uint256 chainId);
    error MissingCode(address target);
    error ConfigurationMismatch();

    function run() external view {
        if (block.chainid != MAINNET_CHAIN_ID) revert WrongChain(block.chainid);

        address validatorAddress = vm.envAddress("VALIDATOR");
        address gaugeModuleAddress = vm.envAddress("GAUGE_MODULE");
        address proposalModuleAddress = vm.envAddress("PROPOSAL_MODULE");
        if (validatorAddress.code.length == 0) revert MissingCode(validatorAddress);
        if (gaugeModuleAddress.code.length == 0) revert MissingCode(gaugeModuleAddress);
        if (proposalModuleAddress.code.length == 0) revert MissingCode(proposalModuleAddress);

        GaugeValidator validator = GaugeValidator(validatorAddress);
        ProposalValidationModuleV1 proposalModule = ProposalValidationModuleV1(proposalModuleAddress);
        if (
            validator.owner() != MainnetGaugeConfiguration.OWNER || validator.proposalModule() != proposalModuleAddress
                || address(proposalModule.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalModule.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalModule.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
        ) revert ConfigurationMismatch();

        GaugeValidator.FactoryBinding[] memory expectedBindings = MainnetGaugeConfiguration.bindings(gaugeModuleAddress);
        for (uint256 i; i < expectedBindings.length; ++i) {
            GaugeValidator.FactoryBinding memory binding = expectedBindings[i];
            (address module, uint8 methodId) = validator.policyForFactory(binding.factory);
            if (binding.factory.code.length == 0 || module != binding.module || methodId != binding.methodId) {
                revert ConfigurationMismatch();
            }
        }

        console2.log("validator", validatorAddress);
        console2.log("gauge module", gaugeModuleAddress);
        console2.log("proposal module", proposalModuleAddress);
        console2.log("owner", validator.owner());
        for (uint256 i; i < expectedBindings.length; ++i) {
            console2.log("factory", expectedBindings[i].factory);
            console2.log("method ID", expectedBindings[i].methodId);
        }
    }
}
