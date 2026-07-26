// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MockGauge, MockTarget, MockValidationModule} from "./helpers/Mocks.sol";

contract GaugeValidatorTest is Test {
    bytes32 private constant METHOD_A = "METHOD_A";
    bytes32 private constant METHOD_B = "METHOD_B";

    MockTarget private proposalAnalyzerA;
    MockTarget private proposalAnalyzerB;
    MockValidationModule private moduleA;
    MockValidationModule private moduleB;
    MockGauge private gauge;
    MockTarget private factoryA;
    MockTarget private factoryB;
    GaugeValidator private validator;

    address private owner = address(this);
    address private user = address(0xB0B);

    event ValidationIdAdded(bytes32 indexed validationId);
    event ValidationIdRemoved(bytes32 indexed validationId);
    event FactoryValidationIdSet(
        address indexed factory, bytes32 indexed previousValidationId, bytes32 indexed newValidationId
    );
    event GaugeValidationModuleSet(address indexed previousModule, address indexed newModule);
    event ProposalAnalysisModuleSet(address indexed previousModule, address indexed newModule);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        proposalAnalyzerA = new MockTarget();
        proposalAnalyzerB = new MockTarget();
        moduleA = new MockValidationModule();
        moduleB = new MockValidationModule();
        gauge = new MockGauge();
        factoryA = new MockTarget();
        factoryB = new MockTarget();

        bytes32[] memory validationIds = new bytes32[](1);
        validationIds[0] = METHOD_A;

        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](1);
        bindings[0] = GaugeValidator.FactoryBinding(address(factoryA), METHOD_A);

        validator = _deploy(address(moduleA), address(proposalAnalyzerA), validationIds, bindings);
        moduleA.setFactory(address(gauge), METHOD_A, address(factoryA));
    }

    function test_ConstructorInstallsModulesIdsAndBindings() public view {
        assertEq(validator.owner(), owner);
        assertEq(validator.gaugeValidationModule(), address(moduleA));
        assertEq(validator.proposalAnalysisModule(), address(proposalAnalyzerA));
        assertEq(validator.validationIdCount(), 1);
        assertEq(validator.validationIdAt(0), METHOD_A);
        assertTrue(validator.isValidationIdActive(METHOD_A));
        assertEq(validator.validationIdForFactory(address(factoryA)), METHOD_A);
    }

    function test_ConstructorConfigurationIsIdempotentAndLastBindingWins() public {
        bytes32[] memory validationIds = new bytes32[](3);
        validationIds[0] = METHOD_A;
        validationIds[1] = METHOD_A;
        validationIds[2] = METHOD_B;

        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](3);
        bindings[0] = GaugeValidator.FactoryBinding(address(factoryA), METHOD_A);
        bindings[1] = GaugeValidator.FactoryBinding(address(factoryA), METHOD_B);
        bindings[2] = GaugeValidator.FactoryBinding(address(factoryA), METHOD_B);

        GaugeValidator configured = _deploy(address(moduleA), address(proposalAnalyzerA), validationIds, bindings);
        moduleA.setFactory(address(gauge), METHOD_A, address(factoryA));
        moduleA.setFactory(address(gauge), METHOD_B, address(factoryA));

        assertEq(configured.validationIdCount(), 2);
        assertEq(configured.validationIdForFactory(address(factoryA)), METHOD_B);
        assertTrue(configured.validateGauge(address(gauge)));
    }

    function test_ConfigurationOperationsAreIdempotent() public {
        validator.addValidationId(METHOD_A);
        validator.removeValidationId(METHOD_B);
        validator.setFactoryValidationId(address(factoryA), METHOD_A);
        validator.setGaugeValidationModule(address(moduleA));
        validator.setProposalAnalysisModule(address(proposalAnalyzerA));
        validator.transferOwnership(owner);

        assertEq(validator.validationIdCount(), 1);
        assertEq(validator.validationIdForFactory(address(factoryA)), METHOD_A);
        assertEq(validator.gaugeValidationModule(), address(moduleA));
        assertEq(validator.proposalAnalysisModule(), address(proposalAnalyzerA));
        assertEq(validator.owner(), owner);
        assertTrue(validator.validateGauge(address(gauge)));
    }

    function test_IdRemovalMaintainsSwapAndPopIndexes() public {
        bytes32 methodC = "METHOD_C";
        validator.addValidationId(METHOD_B);
        validator.addValidationId(methodC);

        validator.removeValidationId(METHOD_B);
        assertFalse(validator.isValidationIdActive(METHOD_B));
        assertTrue(validator.isValidationIdActive(methodC));

        validator.removeValidationId(methodC);
        validator.addValidationId(METHOD_B);
        assertTrue(validator.isValidationIdActive(METHOD_B));
        assertEq(validator.validationIdCount(), 2);
    }

    function test_DormantBindingActivatesDisablesAndReactivatesWithId() public {
        validator.setFactoryValidationId(address(factoryB), METHOD_B);
        moduleA.setFactory(address(gauge), METHOD_B, address(factoryB));

        assertEq(validator.validationIdForFactory(address(factoryB)), METHOD_B);
        assertFalse(validator.isValidationIdActive(METHOD_B));
        assertTrue(validator.validateGauge(address(gauge)));

        validator.removeValidationId(METHOD_A);
        assertFalse(validator.validateGauge(address(gauge)));

        vm.expectEmit(true, false, false, true);
        emit ValidationIdAdded(METHOD_B);
        validator.addValidationId(METHOD_B);
        assertTrue(validator.validateGauge(address(gauge)));

        vm.expectEmit(true, false, false, true);
        emit ValidationIdRemoved(METHOD_B);
        validator.removeValidationId(METHOD_B);
        assertEq(validator.validationIdForFactory(address(factoryB)), METHOD_B);
        assertFalse(validator.validateGauge(address(gauge)));

        validator.addValidationId(METHOD_B);
        assertTrue(validator.validateGauge(address(gauge)));
    }

    function test_GaugePolicyCanBeReplacedDisabledAndRestored() public {
        moduleB.setFactory(address(gauge), METHOD_A, address(factoryA));

        vm.expectEmit(true, true, false, true);
        emit GaugeValidationModuleSet(address(moduleA), address(moduleB));
        validator.setGaugeValidationModule(address(moduleB));
        assertTrue(validator.validateGauge(address(gauge)));

        vm.expectEmit(true, true, false, true);
        emit GaugeValidationModuleSet(address(moduleB), address(0));
        validator.setGaugeValidationModule(address(0));
        assertFalse(validator.validateGauge(address(gauge)));

        validator.setGaugeValidationModule(address(moduleA));
        assertTrue(validator.validateGauge(address(gauge)));
    }

    function test_ExactFactoryToIdBindingIsRequired() public {
        validator.addValidationId(METHOD_B);
        validator.setFactoryValidationId(address(factoryA), METHOD_B);

        assertFalse(validator.validateGauge(address(gauge)));

        moduleA.setFactory(address(gauge), METHOD_B, address(factoryA));
        assertTrue(validator.validateGauge(address(gauge)));
    }

    function test_ZeroOneAndMultipleMatches() public {
        assertTrue(validator.validateGauge(address(gauge)));

        moduleA.setFactory(address(gauge), METHOD_A, address(0));
        assertFalse(validator.validateGauge(address(gauge)));

        moduleA.setFactory(address(gauge), METHOD_A, address(factoryA));
        validator.addValidationId(METHOD_B);
        validator.setFactoryValidationId(address(factoryB), METHOD_B);
        moduleA.setFactory(address(gauge), METHOD_B, address(factoryB));
        assertFalse(validator.validateGauge(address(gauge)));

        validator.removeValidationId(METHOD_B);
        assertTrue(validator.validateGauge(address(gauge)));
    }

    function test_ValidateGaugeRejectsZeroAndCodeLessAddresses() public view {
        assertFalse(validator.validateGauge(address(0)));
        assertFalse(validator.validateGauge(address(0x1234)));
    }

    function test_EveryModuleFailureAndMalformedReturnFailsClosed() public {
        for (uint256 mode = 1; mode <= uint256(MockValidationModule.Mode.RETURN_DATA_BOMB); ++mode) {
            moduleA.setMode(MockValidationModule.Mode(mode));
            assertFalse(validator.validateGauge(address(gauge)));
        }
    }

    function test_FailedIdDoesNotPreventLaterIdFromMatching() public {
        validator.addValidationId(METHOD_B);
        validator.setFactoryValidationId(address(factoryB), METHOD_B);
        moduleA.setValidationIdMode(METHOD_A, MockValidationModule.Mode.RETURN_DATA_BOMB);
        moduleA.setFactory(address(gauge), METHOD_B, address(factoryB));

        assertTrue(validator.validateGauge(address(gauge)));
    }

    function test_InsufficientGasCannotValidateAfterOnlyIdPrefix() public {
        validator.addValidationId(METHOD_B);
        validator.setFactoryValidationId(address(factoryB), METHOD_B);

        (bool success, bytes memory result) =
            address(validator).staticcall{gas: 300_000}(abi.encodeCall(GaugeValidator.validateGauge, (address(gauge))));

        assertTrue(success);
        assertFalse(abi.decode(result, (bool)));
    }

    function test_MaximumIdSetOfGasBurningCallsFailsClosedWithinBound() public {
        bytes32[] memory validationIds = new bytes32[](validator.MAX_VALIDATION_IDS());
        for (uint256 i; i < validationIds.length; ++i) {
            validationIds[i] = bytes32(i + 1);
        }
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](0);
        GaugeValidator maxValidator = _deploy(address(moduleB), address(proposalAnalyzerA), validationIds, bindings);
        moduleB.setMode(MockValidationModule.Mode.BURN_GAS);

        (bool success, bytes memory result) = address(maxValidator).staticcall{gas: 5_000_000}(
            abi.encodeCall(GaugeValidator.validateGauge, (address(gauge)))
        );

        assertTrue(success);
        assertFalse(abi.decode(result, (bool)));
    }

    function test_IdLimitChecksOnlyNewIds() public {
        for (uint256 i = 1; i < validator.MAX_VALIDATION_IDS(); ++i) {
            validator.addValidationId(bytes32(i));
        }
        assertEq(validator.validationIdCount(), validator.MAX_VALIDATION_IDS());

        validator.addValidationId(METHOD_A);

        vm.expectRevert(GaugeValidator.ValidationIdLimitReached.selector);
        validator.addValidationId(bytes32(uint256(999)));
    }

    function test_FactoryBindingCanBeReplacedAndDisabled() public {
        validator.addValidationId(METHOD_B);

        vm.expectEmit(true, true, true, true);
        emit FactoryValidationIdSet(address(factoryA), METHOD_A, METHOD_B);
        validator.setFactoryValidationId(address(factoryA), METHOD_B);
        assertEq(validator.validationIdForFactory(address(factoryA)), METHOD_B);

        vm.expectEmit(true, true, true, true);
        emit FactoryValidationIdSet(address(factoryA), METHOD_B, bytes32(0));
        validator.setFactoryValidationId(address(factoryA), bytes32(0));
        assertEq(validator.validationIdForFactory(address(factoryA)), bytes32(0));
        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_InvalidConfigurationReverts() public {
        vm.expectRevert(GaugeValidator.ZeroValidationId.selector);
        validator.addValidationId(bytes32(0));

        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        validator.setFactoryValidationId(address(0), METHOD_A);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        validator.setFactoryValidationId(address(0x1234), METHOD_A);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        validator.setGaugeValidationModule(address(0x1234));

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        validator.setProposalAnalysisModule(address(0x1234));
    }

    function test_ConstructorRejectsUnestablishableConfiguration() public {
        bytes32[] memory validationIds = new bytes32[](1);
        validationIds[0] = METHOD_A;
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](0);

        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        new GaugeValidator(address(0), address(moduleA), address(proposalAnalyzerA), validationIds, bindings);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        new GaugeValidator(owner, address(0x1234), address(proposalAnalyzerA), validationIds, bindings);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        new GaugeValidator(owner, address(moduleA), address(0x1234), validationIds, bindings);

        bindings = new GaugeValidator.FactoryBinding[](1);
        bindings[0] = GaugeValidator.FactoryBinding(address(0x1234), METHOD_A);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        new GaugeValidator(owner, address(moduleA), address(proposalAnalyzerA), validationIds, bindings);
    }

    function test_NonOwnerCannotMutateConfiguration() public {
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, user));
        validator.addValidationId(METHOD_B);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, user));
        validator.removeValidationId(METHOD_A);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, user));
        validator.setFactoryValidationId(address(factoryA), bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, user));
        validator.setGaugeValidationModule(address(moduleB));

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, user));
        validator.setProposalAnalysisModule(address(proposalAnalyzerB));

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, user));
        validator.transferOwnership(user);

        vm.stopPrank();
    }

    function test_OwnerCanTransferButCannotRenounceOwnership() public {
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(owner, user);
        validator.transferOwnership(user);
        assertEq(validator.owner(), user);

        vm.prank(user);
        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        validator.transferOwnership(address(0));
    }

    function test_ProposalAnalyzerCanBeReplacedDisabledAndRestored() public {
        vm.expectEmit(true, true, false, true);
        emit ProposalAnalysisModuleSet(address(proposalAnalyzerA), address(proposalAnalyzerB));
        validator.setProposalAnalysisModule(address(proposalAnalyzerB));
        assertEq(validator.proposalAnalysisModule(), address(proposalAnalyzerB));

        vm.expectEmit(true, true, false, true);
        emit ProposalAnalysisModuleSet(address(proposalAnalyzerB), address(0));
        validator.setProposalAnalysisModule(address(0));
        assertEq(validator.proposalAnalysisModule(), address(0));

        validator.setProposalAnalysisModule(address(proposalAnalyzerA));
        assertEq(validator.proposalAnalysisModule(), address(proposalAnalyzerA));
    }

    function test_ConstructorMayStartWithBothPoliciesDisabled() public {
        bytes32[] memory validationIds = new bytes32[](0);
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](0);
        GaugeValidator disabled = _deploy(address(0), address(0), validationIds, bindings);

        assertEq(disabled.gaugeValidationModule(), address(0));
        assertEq(disabled.proposalAnalysisModule(), address(0));
        assertFalse(disabled.validateGauge(address(gauge)));
    }

    function _deploy(
        address gaugeModule,
        address proposalModule,
        bytes32[] memory validationIds,
        GaugeValidator.FactoryBinding[] memory bindings
    ) private returns (GaugeValidator) {
        return new GaugeValidator(owner, gaugeModule, proposalModule, validationIds, bindings);
    }
}
