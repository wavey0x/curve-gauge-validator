// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalAnalysisModuleV1} from "../src/ProposalAnalysisModuleV1.sol";
import {ICurveDAO} from "../src/interfaces/ICurveDAO.sol";

/// @notice Creates both initial modules and then the fully configured,
///         governance-owned core in three broadcast transactions.
contract DeployGaugeValidator is Script {
    uint256 public constant MAINNET_CHAIN_ID = 1;

    error WrongChain(uint256 chainId);
    error DeploymentInvariantFailed();

    function run()
        external
        returns (GaugeValidationModuleV1 gaugeModule, ProposalAnalysisModuleV1 proposalModule, GaugeValidator validator)
    {
        if (block.chainid != MAINNET_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }

        vm.startBroadcast();
        gaugeModule = new GaugeValidationModuleV1();
        proposalModule = new ProposalAnalysisModuleV1(
            ICurveDAO(MainnetGaugeConfiguration.DAO),
            MainnetGaugeConfiguration.OWNER,
            MainnetGaugeConfiguration.GAUGE_CONTROLLER
        );
        validator = new GaugeValidator(
            MainnetGaugeConfiguration.OWNER,
            address(gaugeModule),
            address(proposalModule),
            MainnetGaugeConfiguration.validationIds(),
            MainnetGaugeConfiguration.bindings()
        );
        vm.stopBroadcast();

        _assertDeployment(gaugeModule, proposalModule, validator);
    }

    function _assertDeployment(
        GaugeValidationModuleV1 gaugeModule,
        ProposalAnalysisModuleV1 proposalModule,
        GaugeValidator validator
    ) private view {
        if (
            validator.owner() != MainnetGaugeConfiguration.OWNER
                || validator.gaugeValidationModule() != address(gaugeModule)
                || validator.proposalAnalysisModule() != address(proposalModule) || validator.validationIdCount() != 4
                || address(proposalModule.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalModule.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalModule.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
        ) revert DeploymentInvariantFailed();

        bytes32[] memory validationIds = MainnetGaugeConfiguration.validationIds();
        for (uint256 i; i < validationIds.length; ++i) {
            if (validator.validationIdAt(i) != validationIds[i]) revert DeploymentInvariantFailed();
        }

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings();
        for (uint256 i; i < bindings.length; ++i) {
            if (validator.validationIdForFactory(bindings[i].factory) != bindings[i].validationId) {
                revert DeploymentInvariantFailed();
            }
        }
    }
}
