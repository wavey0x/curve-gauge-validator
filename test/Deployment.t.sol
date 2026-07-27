// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalValidationModuleV1} from "../src/ProposalValidationModuleV1.sol";
import {DeployGaugeValidator} from "../script/DeployGaugeValidator.s.sol";
import {InspectGaugeValidator} from "../script/InspectGaugeValidator.s.sol";

contract DeploymentTest is Test {
    uint256 private constant FORK_BLOCK = 25_619_622;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL", string("http://wavey:8545")), FORK_BLOCK);
    }

    function test_DeploymentCreatesFullyConfiguredGovernanceOwnedCore() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        (GaugeValidationModuleV1 gaugeModule, ProposalValidationModuleV1 proposalModule, GaugeValidator validator) =
            deployment.run();

        assertEq(validator.owner(), MainnetGaugeConfiguration.OWNER);
        assertNotEq(validator.owner(), address(deployment));
        assertEq(validator.proposalModule(), address(proposalModule));
        assertEq(address(proposalModule.DAO()), MainnetGaugeConfiguration.DAO);
        assertEq(proposalModule.AGENT(), MainnetGaugeConfiguration.OWNER);
        assertEq(proposalModule.GAUGE_CONTROLLER(), MainnetGaugeConfiguration.GAUGE_CONTROLLER);

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings(address(gaugeModule));
        for (uint256 i; i < bindings.length; ++i) {
            (address configuredModule, uint8 methodId) = validator.policyForFactory(bindings[i].factory);
            assertEq(configuredModule, address(gaugeModule));
            assertEq(methodId, bindings[i].methodId);
        }

        // Test-local environment used only by the read-only inspection script.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("VALIDATOR", vm.toString(address(validator)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GAUGE_MODULE", vm.toString(address(gaugeModule)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("PROPOSAL_MODULE", vm.toString(address(proposalModule)));
        new InspectGaugeValidator().run();
    }
}
