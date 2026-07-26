// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalGaugeValidator} from "../src/ProposalGaugeValidator.sol";
import {DeployGaugeValidator} from "../script/DeployGaugeValidator.s.sol";
import {InspectGaugeValidator} from "../script/InspectGaugeValidator.s.sol";

contract DeploymentTest is Test {
    uint256 private constant FORK_BLOCK = 25_619_622;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL", string("http://wavey:8545")), FORK_BLOCK);
    }

    function test_DeploymentCreatesFullyConfiguredGovernanceOwnedCore() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        (GaugeValidator validator, ProposalGaugeValidator proposalValidator) = deployment.run();

        assertEq(validator.owner(), MainnetGaugeConfiguration.OWNER);
        assertNotEq(validator.owner(), address(deployment));
        assertEq(address(proposalValidator.DAO()), MainnetGaugeConfiguration.DAO);
        assertEq(proposalValidator.AGENT(), MainnetGaugeConfiguration.OWNER);
        assertEq(proposalValidator.GAUGE_CONTROLLER(), MainnetGaugeConfiguration.GAUGE_CONTROLLER);
        assertEq(address(proposalValidator.GAUGE_VALIDATOR()), address(validator));

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings();
        for (uint256 i; i < bindings.length; ++i) {
            assertEq(uint256(validator.proofForFactory(bindings[i].factory)), uint256(bindings[i].proof));
        }

        // Test-local environment used only by the read-only inspection script.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("VALIDATOR", vm.toString(address(validator)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("PROPOSAL_VALIDATOR", vm.toString(address(proposalValidator)));
        new InspectGaugeValidator().run();
    }
}
