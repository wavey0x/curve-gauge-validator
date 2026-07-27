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

        assertEq(address(gaugeModule), deployment.GAUGE_MODULE_ADDRESS());
        assertEq(address(proposalModule), deployment.PROPOSAL_MODULE_ADDRESS());
        assertEq(address(validator), deployment.VALIDATOR_ADDRESS());
        assertEq(address(gaugeModule).codehash, deployment.GAUGE_MODULE_RUNTIME_HASH());
        assertEq(address(proposalModule).codehash, deployment.PROPOSAL_MODULE_RUNTIME_HASH());
        assertEq(address(validator).codehash, deployment.VALIDATOR_RUNTIME_HASH());
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

    function test_DeploymentIsSafelyRerunnable() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        (GaugeValidationModuleV1 firstGauge, ProposalValidationModuleV1 firstProposal, GaugeValidator firstValidator) =
            deployment.run();
        (GaugeValidationModuleV1 nextGauge, ProposalValidationModuleV1 nextProposal, GaugeValidator nextValidator) =
            deployment.run();

        assertEq(address(nextGauge), address(firstGauge));
        assertEq(address(nextProposal), address(firstProposal));
        assertEq(address(nextValidator), address(firstValidator));
    }

    function test_DeploymentRejectsWrongChain() public {
        vm.chainId(10);
        DeployGaugeValidator deployment = new DeployGaugeValidator();

        vm.expectRevert(abi.encodeWithSelector(DeployGaugeValidator.WrongChain.selector, 10));
        deployment.run();
    }

    function test_DeploymentRejectsUnexpectedCodeAtTarget() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        address target = deployment.GAUGE_MODULE_ADDRESS();
        bytes memory unexpectedCode = hex"00";
        vm.etch(target, unexpectedCode);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGaugeValidator.RuntimeCodeHashMismatch.selector,
                target,
                deployment.GAUGE_MODULE_RUNTIME_HASH(),
                keccak256(unexpectedCode)
            )
        );
        deployment.run();
    }

    function test_DeploymentRejectsUnexpectedCreateXRuntime() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();
        address createX = deployment.CREATE_X();
        bytes memory unexpectedCode = hex"00";
        vm.etch(createX, unexpectedCode);

        vm.expectRevert(
            abi.encodeWithSelector(DeployGaugeValidator.CreateXCodeHashMismatch.selector, keccak256(unexpectedCode))
        );
        deployment.run();
    }

    function test_FrozenInitCodeAndVanityAddressesMatch() public {
        DeployGaugeValidator deployment = new DeployGaugeValidator();

        bytes memory gaugeModuleInitCode = type(GaugeValidationModuleV1).creationCode;
        bytes memory proposalModuleInitCode = abi.encodePacked(
            type(ProposalValidationModuleV1).creationCode,
            abi.encode(
                MainnetGaugeConfiguration.DAO,
                MainnetGaugeConfiguration.OWNER,
                MainnetGaugeConfiguration.GAUGE_CONTROLLER
            )
        );
        bytes memory validatorInitCode = abi.encodePacked(
            type(GaugeValidator).creationCode,
            abi.encode(
                MainnetGaugeConfiguration.OWNER,
                deployment.PROPOSAL_MODULE_ADDRESS(),
                MainnetGaugeConfiguration.bindings(deployment.GAUGE_MODULE_ADDRESS())
            )
        );

        assertEq(keccak256(gaugeModuleInitCode), deployment.GAUGE_MODULE_INIT_CODE_HASH());
        assertEq(keccak256(proposalModuleInitCode), deployment.PROPOSAL_MODULE_INIT_CODE_HASH());
        assertEq(keccak256(validatorInitCode), deployment.VALIDATOR_INIT_CODE_HASH());
        assertEq(
            _createXAddress(
                deployment.CREATE_X(),
                deployment.DEPLOYER(),
                deployment.GAUGE_MODULE_SALT(),
                deployment.GAUGE_MODULE_INIT_CODE_HASH()
            ),
            deployment.GAUGE_MODULE_ADDRESS()
        );
        assertEq(
            _createXAddress(
                deployment.CREATE_X(),
                deployment.DEPLOYER(),
                deployment.PROPOSAL_MODULE_SALT(),
                deployment.PROPOSAL_MODULE_INIT_CODE_HASH()
            ),
            deployment.PROPOSAL_MODULE_ADDRESS()
        );
        assertEq(
            _createXAddress(
                deployment.CREATE_X(),
                deployment.DEPLOYER(),
                deployment.VALIDATOR_SALT(),
                deployment.VALIDATOR_INIT_CODE_HASH()
            ),
            deployment.VALIDATOR_ADDRESS()
        );
    }

    function _createXAddress(address createX, address deployer, bytes32 rawSalt, bytes32 initCodeHash)
        private
        pure
        returns (address)
    {
        bytes32 guardedSalt = keccak256(abi.encode(deployer, uint256(1), rawSalt));
        bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), createX, guardedSalt, initCodeHash));
        // The CREATE2 address is the low 20 bytes of the digest.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(digest)));
    }
}
