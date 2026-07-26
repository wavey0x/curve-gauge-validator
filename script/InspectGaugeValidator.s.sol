// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalGaugeValidator} from "../src/ProposalGaugeValidator.sol";

/// @notice Reads the deployed validator configuration without mutating state.
contract InspectGaugeValidator is Script {
    uint256 public constant MAINNET_CHAIN_ID = 1;

    error WrongChain(uint256 chainId);
    error MissingCode(address target);
    error ConfigurationMismatch();

    function run() external view {
        if (block.chainid != MAINNET_CHAIN_ID) revert WrongChain(block.chainid);

        address validatorAddress = vm.envAddress("VALIDATOR");
        address proposalValidatorAddress = vm.envAddress("PROPOSAL_VALIDATOR");
        if (validatorAddress.code.length == 0) revert MissingCode(validatorAddress);
        if (proposalValidatorAddress.code.length == 0) revert MissingCode(proposalValidatorAddress);

        GaugeValidator validator = GaugeValidator(validatorAddress);
        ProposalGaugeValidator proposalValidator = ProposalGaugeValidator(proposalValidatorAddress);
        if (
            validator.owner() != MainnetGaugeConfiguration.OWNER
                || address(proposalValidator.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalValidator.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalValidator.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
                || address(proposalValidator.GAUGE_VALIDATOR()) != validatorAddress
        ) revert ConfigurationMismatch();

        GaugeValidator.FactoryBinding[] memory expectedBindings = MainnetGaugeConfiguration.bindings();
        for (uint256 i; i < expectedBindings.length; ++i) {
            GaugeValidator.FactoryBinding memory binding = expectedBindings[i];
            if (binding.factory.code.length == 0 || validator.proofForFactory(binding.factory) != binding.proof) {
                revert ConfigurationMismatch();
            }
        }

        console2.log("validator", validatorAddress);
        console2.log("proposal validator", proposalValidatorAddress);
        console2.log("owner", validator.owner());
        for (uint256 i; i < expectedBindings.length; ++i) {
            console2.log("factory", expectedBindings[i].factory);
            console2.log("proof", uint256(expectedBindings[i].proof));
        }
    }
}
