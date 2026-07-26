// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalAnalysisModuleV1} from "../src/ProposalAnalysisModuleV1.sol";
import {DeployGaugeValidator} from "../script/DeployGaugeValidator.s.sol";
import {InspectGaugeValidator} from "../script/InspectGaugeValidator.s.sol";

contract DeploymentTest is Test {
    uint256 private constant FORK_BLOCK = 25_619_622;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL", string("http://wavey:8545")), FORK_BLOCK);
    }

    function test_DeploymentCreatesFullyConfiguredGovernanceOwnedCore() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        (GaugeValidationModuleV1 module, ProposalAnalysisModuleV1 proposalModule, GaugeValidator validator) =
            deployment.run();

        assertEq(validator.owner(), MainnetGaugeConfiguration.OWNER);
        assertNotEq(validator.owner(), address(deployment));
        assertEq(validator.gaugeValidationModule(), address(module));
        assertEq(validator.proposalAnalysisModule(), address(proposalModule));
        assertEq(validator.validationIdCount(), 4);
        assertEq(address(proposalModule.DAO()), MainnetGaugeConfiguration.DAO);
        assertEq(proposalModule.AGENT(), MainnetGaugeConfiguration.OWNER);

        bytes32[] memory validationIds = MainnetGaugeConfiguration.validationIds();
        for (uint256 i; i < validationIds.length; ++i) {
            assertEq(validator.validationIdAt(i), validationIds[i]);
        }

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings();
        for (uint256 i; i < bindings.length; ++i) {
            assertEq(validator.validationIdForFactory(bindings[i].factory), bindings[i].validationId);
        }

        // Test-local environment used only by the read-only inspection script.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("VALIDATOR", vm.toString(address(validator)));
        new InspectGaugeValidator().run();
    }
}
