// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalValidationModuleV1} from "../src/ProposalValidationModuleV1.sol";
import {ICurveDAO} from "../src/interfaces/ICurveDAO.sol";

/// @notice Deploys both policy modules and their stable validator entry point.
contract DeployGaugeValidator is Script {
    uint256 public constant MAINNET_CHAIN_ID = 1;

    error WrongChain(uint256 chainId);
    error DeploymentInvariantFailed();

    function run()
        external
        returns (
            GaugeValidationModuleV1 gaugeModule,
            ProposalValidationModuleV1 proposalModule,
            GaugeValidator validator
        )
    {
        if (block.chainid != MAINNET_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }

        vm.startBroadcast();
        gaugeModule = new GaugeValidationModuleV1();
        proposalModule = new ProposalValidationModuleV1(
            ICurveDAO(MainnetGaugeConfiguration.DAO),
            MainnetGaugeConfiguration.OWNER,
            MainnetGaugeConfiguration.GAUGE_CONTROLLER
        );
        validator = new GaugeValidator(
            MainnetGaugeConfiguration.OWNER,
            address(proposalModule),
            MainnetGaugeConfiguration.bindings(address(gaugeModule))
        );
        vm.stopBroadcast();

        _assertDeployment(gaugeModule, proposalModule, validator);
    }

    function _assertDeployment(
        GaugeValidationModuleV1 gaugeModule,
        ProposalValidationModuleV1 proposalModule,
        GaugeValidator validator
    ) private view {
        if (
            validator.owner() != MainnetGaugeConfiguration.OWNER
                || validator.proposalModule() != address(proposalModule)
                || address(proposalModule.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalModule.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalModule.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
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
