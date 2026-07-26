// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalAnalysisModuleV1} from "../src/ProposalAnalysisModuleV1.sol";

/// @notice Reads the deployed validator configuration without mutating state.
contract InspectGaugeValidator is Script {
    uint256 public constant MAINNET_CHAIN_ID = 1;

    error WrongChain(uint256 chainId);
    error MissingCode(address target);
    error ConfigurationMismatch();

    function run() external view {
        if (block.chainid != MAINNET_CHAIN_ID) revert WrongChain(block.chainid);

        address validatorAddress = vm.envAddress("VALIDATOR");
        if (validatorAddress.code.length == 0) revert MissingCode(validatorAddress);

        GaugeValidator validator = GaugeValidator(validatorAddress);
        address gaugeModuleAddress = validator.gaugeValidationModule();
        address proposalModuleAddress = validator.proposalAnalysisModule();
        if (gaugeModuleAddress.code.length == 0 || proposalModuleAddress.code.length == 0) {
            revert ConfigurationMismatch();
        }

        ProposalAnalysisModuleV1 proposalModule = ProposalAnalysisModuleV1(proposalModuleAddress);
        if (
            validator.owner() != MainnetGaugeConfiguration.OWNER
                || address(proposalModule.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalModule.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalModule.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
        ) revert ConfigurationMismatch();

        bytes32[] memory expectedValidationIds = MainnetGaugeConfiguration.validationIds();
        if (validator.validationIdCount() != expectedValidationIds.length) revert ConfigurationMismatch();

        for (uint256 i; i < expectedValidationIds.length; ++i) {
            if (validator.validationIdAt(i) != expectedValidationIds[i]) revert ConfigurationMismatch();
        }

        GaugeValidator.FactoryBinding[] memory expectedBindings = MainnetGaugeConfiguration.bindings();
        for (uint256 i; i < expectedBindings.length; ++i) {
            GaugeValidator.FactoryBinding memory binding = expectedBindings[i];
            if (
                binding.factory.code.length == 0
                    || validator.validationIdForFactory(binding.factory) != binding.validationId
            ) {
                revert ConfigurationMismatch();
            }
        }

        console2.log("validator", validatorAddress);
        console2.log("owner", validator.owner());
        console2.log("proposal analysis module", proposalModuleAddress);
        console2.log("gauge validation module", gaugeModuleAddress);
        console2.log("DAO", address(proposalModule.DAO()));
        console2.log("Agent", proposalModule.AGENT());
        console2.log("GaugeController", proposalModule.GAUGE_CONTROLLER());
        console2.log("validation ID count", validator.validationIdCount());

        for (uint256 i; i < validator.validationIdCount(); ++i) {
            console2.log("validation ID", i);
            console2.logBytes32(validator.validationIdAt(i));
        }

        for (uint256 i; i < expectedBindings.length; ++i) {
            console2.log("factory", expectedBindings[i].factory);
            console2.logBytes32(validator.validationIdForFactory(expectedBindings[i].factory));
        }
    }
}
