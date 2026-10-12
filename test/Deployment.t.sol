// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalValidationModuleV1} from "../src/ProposalValidationModuleV1.sol";
import {DeployGaugeValidator} from "../script/DeployGaugeValidator.s.sol";
import {InspectGaugeValidator} from "../script/InspectGaugeValidator.s.sol";
import {MockCurveFactory, MockValidationModule} from "./helpers/Mocks.sol";

contract DeploymentTest is Test {
    uint256 private constant FORK_BLOCK = 26_177_927;
    address private constant MANAGER = 0xc0DE00005F21Fa7846BA0EA2E3F2FC4F048a72C9;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL", string("http://wavey:8545")), FORK_BLOCK);
    }

    function test_DeploymentReusesModulesAndCreatesGovernanceOwnedCoreWithInitialManager() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        bytes32 proofHash = deployment.GAUGE_MODULE_ADDRESS().codehash;
        bytes32 parserHash = deployment.PROPOSAL_MODULE_ADDRESS().codehash;
        GaugeValidator validator = deployment.run();
        assertEq(address(validator), deployment.VALIDATOR_ADDRESS());
        assertEq(address(validator).codehash, deployment.VALIDATOR_RUNTIME_HASH());
        assertEq(deployment.GAUGE_MODULE_ADDRESS().codehash, proofHash);
        assertEq(deployment.PROPOSAL_MODULE_ADDRESS().codehash, parserHash);
        assertEq(validator.owner(), MainnetGaugeConfiguration.OWNER);
        assertEq(validator.proposalModule(), deployment.PROPOSAL_MODULE_ADDRESS());
        assertTrue(validator.managers(MANAGER));
        assertFalse(validator.managers(deployment.DEPLOYER()));
        ProposalValidationModuleV1 parser = ProposalValidationModuleV1(validator.proposalModule());
        assertEq(address(parser.DAO()), MainnetGaugeConfiguration.DAO);
        assertEq(parser.AGENT(), MainnetGaugeConfiguration.OWNER);
        assertEq(parser.GAUGE_CONTROLLER(), MainnetGaugeConfiguration.GAUGE_CONTROLLER);
        _assertPolicies(validator);
    }

    function test_DeploymentIsSafelyRerunnable() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        assertEq(address(deployment.run()), address(deployment.run()));
    }

    function test_DeploymentRejectsMissingOrChangedReusedModules() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        address target = deployment.GAUGE_MODULE_ADDRESS();
        vm.etch(target, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGaugeValidator.RuntimeCodeHashMismatch.selector,
                target,
                deployment.GAUGE_MODULE_RUNTIME_HASH(),
                keccak256(hex"00")
            )
        );
        deployment.run();
        vm.etch(target, hex"");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGaugeValidator.RuntimeCodeHashMismatch.selector,
                target,
                deployment.GAUGE_MODULE_RUNTIME_HASH(),
                keccak256(hex"")
            )
        );
        deployment.run();
    }

    function test_DeploymentRejectsUnexpectedCoreRuntime() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        address target = deployment.VALIDATOR_ADDRESS();
        vm.etch(target, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGaugeValidator.RuntimeCodeHashMismatch.selector,
                target,
                deployment.VALIDATOR_RUNTIME_HASH(),
                keccak256(hex"00")
            )
        );
        deployment.run();
    }

    function test_DeploymentRejectsUnexpectedCreateXRuntime() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        vm.etch(deployment.CREATE_X(), hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(DeployGaugeValidator.CreateXCodeHashMismatch.selector, keccak256(hex"00"))
        );
        deployment.run();
    }

    function test_FrozenCoreArtifactMatches() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        bytes memory initCode = abi.encodePacked(
            type(GaugeValidator).creationCode,
            abi.encode(
                MainnetGaugeConfiguration.OWNER,
                MainnetGaugeConfiguration.INITIAL_MANAGER,
                deployment.PROPOSAL_MODULE_ADDRESS(),
                MainnetGaugeConfiguration.bindings(deployment.GAUGE_MODULE_ADDRESS())
            )
        );
        assertEq(keccak256(initCode), deployment.VALIDATOR_INIT_CODE_HASH());
        bytes32 guardedSalt = keccak256(abi.encode(deployment.DEPLOYER(), uint256(1), deployment.VALIDATOR_SALT()));
        bytes32 digest = keccak256(
            abi.encodePacked(bytes1(0xff), deployment.CREATE_X(), guardedSalt, deployment.VALIDATOR_INIT_CODE_HASH())
        );
        // CREATE2 selects the low 20 bytes of the digest.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(uint160(uint256(digest))), deployment.VALIDATOR_ADDRESS());
    }

    function test_InspectionAcceptsLiveMixedModulesAndDisabledPolicies() public {
        GaugeValidator validator = new DeployGaugeValidator().run();
        MockCurveFactory factory = new MockCurveFactory();
        MockValidationModule module = new MockValidationModule();
        vm.startPrank(MainnetGaugeConfiguration.OWNER);
        validator.setProposalModule(address(0));
        vm.stopPrank();
        vm.startPrank(MANAGER);
        validator.setFactoryPolicy(address(factory), address(module), 255);
        validator.setFactoryPolicy(MainnetGaugeConfiguration.REGULAR_GAUGE_FACTORY, address(0), 0);
        vm.stopPrank();
        // Test-local inputs to the read-only inspection script.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("VALIDATOR", vm.toString(address(validator)));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(
            "FACTORIES",
            string.concat(
                vm.toString(address(factory)), ",", vm.toString(MainnetGaugeConfiguration.REGULAR_GAUGE_FACTORY)
            )
        );
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("MANAGER", vm.toString(MANAGER));
        new InspectGaugeValidator().run();
    }

    function _assertPolicies(GaugeValidator validator) private view {
        GaugeValidator.FactoryBinding[] memory bindings =
            MainnetGaugeConfiguration.bindings(MainnetGaugeConfiguration.GAUGE_MODULE);
        for (uint256 i; i < bindings.length; ++i) {
            (address module, uint8 methodId) = validator.policyForFactory(bindings[i].factory);
            assertEq(module, bindings[i].module);
            assertEq(methodId, bindings[i].methodId);
        }
    }
}
