// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalGaugeValidator} from "../src/ProposalGaugeValidator.sol";
import {ICurveDAO} from "../src/interfaces/ICurveDAO.sol";

/// @notice Deploys the current gauge module, stable core, and proposal consumer.
contract DeployGaugeValidator is Script {
    uint256 public constant MAINNET_CHAIN_ID = 1;

    error WrongChain(uint256 chainId);
    error DeploymentInvariantFailed();

    function run()
        external
        returns (
            GaugeValidationModuleV1 gaugeModule,
            GaugeValidator validator,
            ProposalGaugeValidator proposalValidator
        )
    {
        if (block.chainid != MAINNET_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }

        vm.startBroadcast();
        gaugeModule = new GaugeValidationModuleV1();
        validator = new GaugeValidator(
            MainnetGaugeConfiguration.OWNER, MainnetGaugeConfiguration.bindings(address(gaugeModule))
        );
        proposalValidator = new ProposalGaugeValidator(
            ICurveDAO(MainnetGaugeConfiguration.DAO),
            MainnetGaugeConfiguration.OWNER,
            MainnetGaugeConfiguration.GAUGE_CONTROLLER,
            validator
        );
        vm.stopBroadcast();

        _assertDeployment(gaugeModule, validator, proposalValidator);
    }

    function _assertDeployment(
        GaugeValidationModuleV1 gaugeModule,
        GaugeValidator validator,
        ProposalGaugeValidator proposalValidator
    ) private view {
        if (
            validator.owner() != MainnetGaugeConfiguration.OWNER
                || address(proposalValidator.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalValidator.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalValidator.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
                || address(proposalValidator.GAUGE_VALIDATOR()) != address(validator)
        ) revert DeploymentInvariantFailed();

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings(address(gaugeModule));
        for (uint256 i; i < bindings.length; ++i) {
            (address module, uint8 methodId) = validator.policyForFactory(bindings[i].factory);
            if (module != bindings[i].module || methodId != bindings[i].methodId) {
                revert DeploymentInvariantFailed();
            }
        }
    }
}
