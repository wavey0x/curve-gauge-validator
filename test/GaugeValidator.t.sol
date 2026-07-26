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

    event RouteAdded(bytes32 indexed routeKey, address indexed module, bytes32 indexed validationId);
    event RouteRemoved(bytes32 indexed routeKey, address indexed module, bytes32 indexed validationId);
    event FactoryRouteSet(address indexed factory, bytes32 indexed previousRouteKey, bytes32 indexed newRouteKey);
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

        GaugeValidator.Route[] memory routes = new GaugeValidator.Route[](1);
        routes[0] = GaugeValidator.Route(address(moduleA), METHOD_A);

        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](1);
        bindings[0] = GaugeValidator.FactoryBinding(address(factoryA), address(moduleA), METHOD_A);

        validator = _deploy(routes, bindings);
        moduleA.setFactory(address(gauge), METHOD_A, address(factoryA));
    }

    function test_ConstructorInstallsOwnerImmutablesRoutesAndBindings() public view {
        assertEq(validator.owner(), owner);
        assertEq(validator.proposalAnalysisModule(), address(proposalAnalyzerA));
        assertEq(validator.routeCount(), 1);

        (address module, bytes32 validationId) = validator.routeAt(0);
        assertEq(module, address(moduleA));
        assertEq(validationId, METHOD_A);

        bytes32 key = _routeKey(address(moduleA), METHOD_A);
        assertEq(validator.routeForFactory(address(factoryA)), key);
        assertEq(validator.routeFactoryCount(key), 1);
    }

    function test_ValidateGaugeAcceptsExactlyOneMatchingRoute() public view {
        assertTrue(validator.validateGauge(address(gauge)));
    }

    function test_ValidateGaugeRejectsZeroAndCodeLessAddresses() public view {
        assertFalse(validator.validateGauge(address(0)));
        assertFalse(validator.validateGauge(address(0x1234)));
    }

    function test_ZeroMatchingRoutesIsInvalid() public {
        moduleA.setFactory(address(gauge), METHOD_A, address(0));
        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_FactoryBoundToDifferentMethodDoesNotMatch() public {
        validator.addRoute(address(moduleA), METHOD_B);
        validator.setFactoryRoute(address(factoryA), address(moduleA), METHOD_B);

        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_MultipleMatchingRoutesFailClosedInEitherOrder() public {
        _addSecondMatch();
        assertFalse(validator.validateGauge(address(gauge)));

        GaugeValidator.Route[] memory reversed = new GaugeValidator.Route[](2);
        reversed[0] = GaugeValidator.Route(address(moduleB), METHOD_B);
        reversed[1] = GaugeValidator.Route(address(moduleA), METHOD_A);

        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](2);
        bindings[0] = GaugeValidator.FactoryBinding(address(factoryA), address(moduleA), METHOD_A);
        bindings[1] = GaugeValidator.FactoryBinding(address(factoryB), address(moduleB), METHOD_B);

        GaugeValidator reversedValidator = _deploy(reversed, bindings);
        assertFalse(reversedValidator.validateGauge(address(gauge)));
    }

    function test_OwnerCanAddRebindRevokeAndCompletelyRemoveModule() public {
        bytes32 secondKey = _routeKey(address(moduleB), METHOD_B);

        vm.expectEmit(true, true, true, true);
        emit RouteAdded(secondKey, address(moduleB), METHOD_B);
        validator.addRoute(address(moduleB), METHOD_B);

        vm.expectEmit(true, true, true, true);
        emit FactoryRouteSet(address(factoryA), _routeKey(address(moduleA), METHOD_A), secondKey);
        validator.setFactoryRoute(address(factoryA), address(moduleB), METHOD_B);

        assertEq(validator.routeFactoryCount(_routeKey(address(moduleA), METHOD_A)), 0);
        assertEq(validator.routeFactoryCount(secondKey), 1);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.RouteStillInUse.selector, secondKey, uint256(1)));
        validator.removeRoute(address(moduleB), METHOD_B);

        validator.setFactoryRoute(address(factoryA), address(0), bytes32(0));
        assertEq(validator.routeForFactory(address(factoryA)), bytes32(0));
        assertEq(validator.routeFactoryCount(secondKey), 0);

        vm.expectEmit(true, true, true, true);
        emit RouteRemoved(secondKey, address(moduleB), METHOD_B);
        validator.removeRoute(address(moduleB), METHOD_B);

        assertEq(validator.routeCount(), 1);
        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_RemoveRouteMaintainsSwapAndPopIndexes() public {
        validator.addRoute(address(moduleA), METHOD_B);
        validator.addRoute(address(moduleB), METHOD_A);
        validator.removeRoute(address(moduleA), METHOD_B);
        validator.removeRoute(address(moduleB), METHOD_A);

        validator.addRoute(address(moduleB), METHOD_B);
        (address module, bytes32 validationId) = validator.routeAt(1);
        assertEq(module, address(moduleB));
        assertEq(validationId, METHOD_B);
    }

    function test_RouteLimitAllowsInitialAndReplacementSets() public {
        for (uint256 i = 1; i < validator.MAX_ROUTES(); ++i) {
            validator.addRoute(address(moduleB), bytes32(i));
        }
        assertEq(validator.routeCount(), validator.MAX_ROUTES());

        vm.expectRevert(GaugeValidator.RouteLimitReached.selector);
        validator.addRoute(address(moduleA), bytes32(uint256(999)));
    }

    function test_RejectsDuplicateRouteAndDuplicateConstructorBinding() public {
        bytes32 key = _routeKey(address(moduleA), METHOD_A);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.DuplicateRoute.selector, key));
        validator.addRoute(address(moduleA), METHOD_A);

        GaugeValidator.Route[] memory routes = new GaugeValidator.Route[](1);
        routes[0] = GaugeValidator.Route(address(moduleA), METHOD_A);
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](2);
        bindings[0] = GaugeValidator.FactoryBinding(address(factoryA), address(moduleA), METHOD_A);
        bindings[1] = GaugeValidator.FactoryBinding(address(factoryA), address(moduleA), METHOD_A);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.DuplicateFactoryBinding.selector, address(factoryA)));
        _deploy(routes, bindings);
    }

    function test_RejectsMissingCodeAndInvalidRevocation() public {
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        validator.addRoute(address(0x1234), METHOD_B);

        vm.expectRevert(GaugeValidator.InvalidRevocation.selector);
        validator.setFactoryRoute(address(factoryA), address(moduleA), bytes32(0));

        vm.expectRevert(GaugeValidator.InvalidRevocation.selector);
        validator.setFactoryRoute(address(factoryA), address(0), METHOD_A);
    }

    function test_RejectsInvalidRouteAndFactoryConfiguration() public {
        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        validator.addRoute(address(0), METHOD_B);

        vm.expectRevert(GaugeValidator.ZeroValidationId.selector);
        validator.addRoute(address(moduleB), bytes32(0));

        bytes32 unknownKey = _routeKey(address(moduleB), METHOD_B);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.UnknownRoute.selector, unknownKey));
        validator.removeRoute(address(moduleB), METHOD_B);

        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        validator.setFactoryRoute(address(0), address(moduleA), METHOD_A);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        validator.setFactoryRoute(address(0x1234), address(moduleA), METHOD_A);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.UnknownRoute.selector, unknownKey));
        validator.setFactoryRoute(address(factoryB), address(moduleB), METHOD_B);
    }

    function test_NonOwnerCannotMutateConfiguration() public {
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, user));
        validator.addRoute(address(moduleB), METHOD_B);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, user));
        validator.removeRoute(address(moduleA), METHOD_A);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, user));
        validator.setFactoryRoute(address(factoryA), address(0), bytes32(0));

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

    function test_OwnerCanReplaceRemoveAndRestoreProposalAnalyzer() public {
        vm.expectEmit(true, true, false, true);
        emit ProposalAnalysisModuleSet(address(proposalAnalyzerA), address(proposalAnalyzerB));
        validator.setProposalAnalysisModule(address(proposalAnalyzerB));
        assertEq(validator.proposalAnalysisModule(), address(proposalAnalyzerB));

        vm.expectEmit(true, true, false, true);
        emit ProposalAnalysisModuleSet(address(proposalAnalyzerB), address(0));
        validator.setProposalAnalysisModule(address(0));
        assertEq(validator.proposalAnalysisModule(), address(0));

        vm.expectEmit(true, true, false, true);
        emit ProposalAnalysisModuleSet(address(0), address(proposalAnalyzerA));
        validator.setProposalAnalysisModule(address(proposalAnalyzerA));
        assertEq(validator.proposalAnalysisModule(), address(proposalAnalyzerA));
    }

    function test_ProposalAnalyzerRequiresCode() public {
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        validator.setProposalAnalysisModule(address(0x1234));
    }

    function test_ConstructorMayStartWithProposalAnalysisDisabled() public {
        GaugeValidator.Route[] memory routes = new GaugeValidator.Route[](0);
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](0);
        GaugeValidator disabled = new GaugeValidator(owner, address(0), routes, bindings);

        assertEq(disabled.proposalAnalysisModule(), address(0));
    }

    function test_ModuleFailuresAndMalformedReturnsFailClosed() public {
        for (uint256 mode = 1; mode <= 5; ++mode) {
            moduleA.setMode(MockValidationModule.Mode(mode));
            assertFalse(validator.validateGauge(address(gauge)));
        }
    }

    function test_ReturnDataBombCannotPreventLaterRouteFromMatching() public {
        moduleA.setMode(MockValidationModule.Mode.RETURN_DATA_BOMB);
        validator.addRoute(address(moduleB), METHOD_B);
        validator.setFactoryRoute(address(factoryB), address(moduleB), METHOD_B);
        moduleB.setFactory(address(gauge), METHOD_B, address(factoryB));

        assertTrue(validator.validateGauge(address(gauge)));
    }

    function test_InsufficientGasCannotValidateAfterOnlyRoutePrefix() public {
        validator.addRoute(address(moduleB), METHOD_B);
        validator.setFactoryRoute(address(factoryB), address(moduleB), METHOD_B);

        (bool success, bytes memory result) =
            address(validator).staticcall{gas: 300_000}(abi.encodeCall(GaugeValidator.validateGauge, (address(gauge))));

        assertTrue(success);
        assertFalse(abi.decode(result, (bool)));
    }

    function test_MaximumRouteSetOfGasBurningModulesFailsClosedWithinBound() public {
        GaugeValidator.Route[] memory routes = new GaugeValidator.Route[](validator.MAX_ROUTES());
        for (uint256 i; i < routes.length; ++i) {
            routes[i] = GaugeValidator.Route(address(moduleB), bytes32(i + 1));
        }
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](0);
        GaugeValidator maxValidator = _deploy(routes, bindings);
        moduleB.setMode(MockValidationModule.Mode.BURN_GAS);

        (bool success, bytes memory result) = address(maxValidator).staticcall{gas: 5_000_000}(
            abi.encodeCall(GaugeValidator.validateGauge, (address(gauge)))
        );

        assertTrue(success);
        assertFalse(abi.decode(result, (bool)));
    }

    function _addSecondMatch() private {
        validator.addRoute(address(moduleB), METHOD_B);
        validator.setFactoryRoute(address(factoryB), address(moduleB), METHOD_B);
        moduleB.setFactory(address(gauge), METHOD_B, address(factoryB));
    }

    function _deploy(GaugeValidator.Route[] memory routes, GaugeValidator.FactoryBinding[] memory bindings)
        private
        returns (GaugeValidator)
    {
        return new GaugeValidator(owner, address(proposalAnalyzerA), routes, bindings);
    }

    function _routeKey(address module, bytes32 validationId) private pure returns (bytes32) {
        return keccak256(abi.encode(module, validationId));
    }
}
