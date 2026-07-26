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
            address(proposalModule),
            MainnetGaugeConfiguration.routes(address(gaugeModule)),
            MainnetGaugeConfiguration.bindings(address(gaugeModule))
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
                || validator.proposalAnalysisModule() != address(proposalModule) || validator.routeCount() != 4
                || address(proposalModule.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalModule.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalModule.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
        ) revert DeploymentInvariantFailed();

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings(address(gaugeModule));
        for (uint256 i; i < bindings.length; ++i) {
            bytes32 expectedKey = keccak256(abi.encode(bindings[i].module, bindings[i].validationId));
            if (validator.routeForFactory(bindings[i].factory) != expectedKey) {
                revert DeploymentInvariantFailed();
            }
        }
    }
}
