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
        address proposalModuleAddress = validator.proposalAnalysisModule();
        if (proposalModuleAddress.code.length == 0) revert ConfigurationMismatch();

        ProposalAnalysisModuleV1 proposalModule = ProposalAnalysisModuleV1(proposalModuleAddress);
        if (
            validator.owner() != MainnetGaugeConfiguration.OWNER
                || address(proposalModule.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalModule.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalModule.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
        ) revert ConfigurationMismatch();

        if (validator.routeCount() == 0) revert ConfigurationMismatch();
        (address gaugeModuleAddress,) = validator.routeAt(0);
        if (gaugeModuleAddress.code.length == 0) revert ConfigurationMismatch();

        GaugeValidator.Route[] memory expectedRoutes = MainnetGaugeConfiguration.routes(gaugeModuleAddress);
        if (validator.routeCount() != expectedRoutes.length) revert ConfigurationMismatch();

        for (uint256 expectedIndex; expectedIndex < expectedRoutes.length; ++expectedIndex) {
            bool found;
            for (uint256 actualIndex; actualIndex < validator.routeCount(); ++actualIndex) {
                (address module, bytes32 validationId) = validator.routeAt(actualIndex);
                if (
                    module == expectedRoutes[expectedIndex].module
                        && validationId == expectedRoutes[expectedIndex].validationId
                ) {
                    found = true;
                    break;
                }
            }
            if (!found) revert ConfigurationMismatch();
        }

        GaugeValidator.FactoryBinding[] memory expectedBindings = MainnetGaugeConfiguration.bindings(gaugeModuleAddress);
        for (uint256 i; i < expectedBindings.length; ++i) {
            GaugeValidator.FactoryBinding memory binding = expectedBindings[i];
            bytes32 expectedKey = keccak256(abi.encode(binding.module, binding.validationId));
            if (binding.factory.code.length == 0 || validator.routeForFactory(binding.factory) != expectedKey) {
                revert ConfigurationMismatch();
            }
        }

        for (uint256 routeIndex; routeIndex < expectedRoutes.length; ++routeIndex) {
            bytes32 routeKey =
                keccak256(abi.encode(expectedRoutes[routeIndex].module, expectedRoutes[routeIndex].validationId));
            uint256 expectedFactoryCount;
            for (uint256 bindingIndex; bindingIndex < expectedBindings.length; ++bindingIndex) {
                if (
                    expectedBindings[bindingIndex].module == expectedRoutes[routeIndex].module
                        && expectedBindings[bindingIndex].validationId == expectedRoutes[routeIndex].validationId
                ) {
                    ++expectedFactoryCount;
                }
            }
            if (validator.routeFactoryCount(routeKey) != expectedFactoryCount) revert ConfigurationMismatch();
        }

        console2.log("validator", validatorAddress);
        console2.log("owner", validator.owner());
        console2.log("proposal analysis module", proposalModuleAddress);
        console2.log("gauge validation module", gaugeModuleAddress);
        console2.log("DAO", address(proposalModule.DAO()));
        console2.log("Agent", proposalModule.AGENT());
        console2.log("GaugeController", proposalModule.GAUGE_CONTROLLER());
        console2.log("route count", validator.routeCount());

        for (uint256 i; i < validator.routeCount(); ++i) {
            (address module, bytes32 validationId) = validator.routeAt(i);
            console2.log("route", i);
            console2.log("module", module);
            console2.logBytes32(validationId);
            console2.log("factory count", validator.routeFactoryCount(keccak256(abi.encode(module, validationId))));
        }

        for (uint256 i; i < expectedBindings.length; ++i) {
            console2.log("factory", expectedBindings[i].factory);
            console2.logBytes32(validator.routeForFactory(expectedBindings[i].factory));
        }
    }
}
