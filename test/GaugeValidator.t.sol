// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {
    ConfigurableDependency,
    MockCurveFactory,
    MockPoolToken,
    MockProtocolGauge,
    MockTarget,
    MockValidationModule,
    NoncanonicalBoolFactory,
    NoncanonicalFactoryGauge
} from "./helpers/Mocks.sol";

contract GaugeValidatorTest is Test {
    address private constant USER = address(0xB0B);
    address private constant INITIAL_MANAGER = address(0xA11CE);
    uint8 private constant FUTURE_METHOD = type(uint8).max;

    event FactoryPolicySet(address indexed factory, address indexed module, uint8 methodId);
    event ProposalModuleSet(address indexed module);
    event ManagerSet(address indexed manager, bool enabled);

    GaugeValidationModuleV1 private module;

    function setUp() public {
        module = new GaugeValidationModuleV1();
    }

    function test_DirectLpRequiresReciprocalFactoryLookup() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget lpToken = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(lpToken));
        GaugeValidator validator = _deploy(address(factory), module.DIRECT_LP());

        assertFalse(validator.validateGauge(address(gauge)));

        factory.setGauge(address(lpToken), address(gauge));
        assertTrue(validator.validateGauge(address(gauge)));

        factory.setGauge(address(lpToken), address(0x1234));
        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_DirectOrPoolLpAcceptsBothFactoryLayouts() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget pool = new MockTarget();
        MockPoolToken lpToken = new MockPoolToken(address(pool));
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(lpToken));
        GaugeValidator validator = _deploy(address(factory), module.DIRECT_OR_POOL_LP());

        factory.setGauge(address(lpToken), address(gauge));
        assertTrue(validator.validateGauge(address(gauge)));

        factory.setGauge(address(lpToken), address(0));
        factory.setGauge(address(pool), address(gauge));
        assertTrue(validator.validateGauge(address(gauge)));

        factory.setGauge(address(lpToken), address(0x1234));
        assertFalse(validator.validateGauge(address(gauge)));

        factory.setGauge(address(lpToken), address(0));
        vm.mockCallRevert(
            address(factory), abi.encodeWithSignature("get_gauge(address)", address(lpToken)), bytes("failure")
        );
        assertFalse(validator.validateGauge(address(gauge)));
        vm.clearMockedCalls();

        factory.setGauge(address(pool), address(0x1234));
        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_VaultRequiresReciprocalFactoryLookup() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget vault = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(vault));
        GaugeValidator validator = _deploy(address(factory), module.VAULT());

        assertFalse(validator.validateGauge(address(gauge)));

        factory.setVaultGauge(address(vault), address(gauge));
        assertTrue(validator.validateGauge(address(gauge)));
    }

    function test_FactoryAttestationRequiresCanonicalTrue() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(0));
        GaugeValidator validator = _deploy(address(factory), module.FACTORY_IS_VALID_GAUGE());

        assertFalse(validator.validateGauge(address(gauge)));
        factory.setValidGauge(address(gauge), true);
        assertTrue(validator.validateGauge(address(gauge)));

        NoncanonicalBoolFactory malformedFactory = new NoncanonicalBoolFactory();
        gauge.setFactory(address(malformedFactory));
        validator.setFactoryPolicy(address(malformedFactory), address(module), module.FACTORY_IS_VALID_GAUGE());
        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_FactoryCanRebindToFutureModuleWithoutReplacingCore() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockCurveFactory wrongFactory = new MockCurveFactory();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(0));
        GaugeValidator validator = _deploy(address(factory), module.FACTORY_IS_VALID_GAUGE());
        MockValidationModule futureModule = new MockValidationModule();

        assertFalse(validator.validateGauge(address(gauge)));

        validator.setFactoryPolicy(address(factory), address(futureModule), FUTURE_METHOD);
        futureModule.setFactory(address(gauge), FUTURE_METHOD, address(wrongFactory));
        assertFalse(validator.validateGauge(address(gauge)));

        futureModule.setFactory(address(gauge), FUTURE_METHOD, address(factory));
        assertTrue(validator.validateGauge(address(gauge)));

        (address configuredModule, uint8 configuredId) = validator.policyForFactory(address(factory));
        assertEq(configuredModule, address(futureModule));
        assertEq(configuredId, FUTURE_METHOD);
    }

    function test_UnknownCurrentModuleMethodReturnsFalse() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(0));
        GaugeValidator validator = _deploy(address(factory), FUTURE_METHOD);

        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_UntrustedFactoryAndSelfReportReturnFalse() public {
        MockCurveFactory trustedFactory = new MockCurveFactory();
        MockCurveFactory untrustedFactory = new MockCurveFactory();
        MockTarget token = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(untrustedFactory), address(token));
        GaugeValidator validator = _deploy(address(trustedFactory), module.DIRECT_LP());

        untrustedFactory.setGauge(address(token), address(gauge));
        assertFalse(validator.validateGauge(address(gauge)));

        gauge.setFactory(address(trustedFactory));
        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_ZeroCodeLessAndMalformedGaugeReturnFalse() public {
        MockCurveFactory factory = new MockCurveFactory();
        GaugeValidator validator = _deploy(address(factory), module.DIRECT_LP());

        assertFalse(validator.validateGauge(address(0)));
        assertFalse(validator.validateGauge(address(0x1234)));

        NoncanonicalFactoryGauge malformed = new NoncanonicalFactoryGauge(address(0));
        assertFalse(validator.validateGauge(address(malformed)));

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            assertFalse(validator.validateGauge(address(dependency)));
        }
    }

    function test_EveryModuleFailureAndMalformedReturnReturnsFalse() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(0));

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            GaugeValidator validator = _deploy(address(factory), address(dependency), FUTURE_METHOD);
            assertFalse(validator.validateGauge(address(gauge)));
        }
    }

    function test_EveryFactoryDependencyFailureReturnsFalseForEveryMethod() public {
        MockTarget token = new MockTarget();

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            MockProtocolGauge gauge = new MockProtocolGauge(address(dependency), address(token));

            _assertFalseWithMethod(address(gauge), address(dependency), module.DIRECT_LP());
            _assertFalseWithMethod(address(gauge), address(dependency), module.DIRECT_OR_POOL_LP());
            _assertFalseWithMethod(address(gauge), address(dependency), module.VAULT());
            _assertFalseWithMethod(address(gauge), address(dependency), module.FACTORY_IS_VALID_GAUGE());
        }
    }

    function test_EveryLpAndMinterFailureReturnsFalse() public {
        MockCurveFactory factory = new MockCurveFactory();

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            MockProtocolGauge candidateGauge = new MockProtocolGauge(address(factory), address(dependency));

            _assertFalseWithMethod(address(candidateGauge), address(factory), module.DIRECT_OR_POOL_LP());
            _assertFalseWithMethod(address(candidateGauge), address(factory), module.VAULT());
        }

        MockTarget token = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(token));
        bytes memory callData = abi.encodeWithSignature("lp_token()");

        GaugeValidator direct = _deploy(address(factory), module.DIRECT_LP());
        vm.mockCallRevert(address(gauge), callData, bytes("failure"));
        assertFalse(direct.validateGauge(address(gauge)));
        vm.clearMockedCalls();

        vm.mockCall(address(gauge), callData, hex"01");
        assertFalse(direct.validateGauge(address(gauge)));
        vm.clearMockedCalls();

        vm.mockCall(address(gauge), callData, abi.encode(uint256(1) << 160));
        assertFalse(direct.validateGauge(address(gauge)));
    }

    function test_OwnerCanSetRemovePolicyAndTransferOwnership() public {
        MockCurveFactory factory = new MockCurveFactory();
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](0);
        GaugeValidator validator = new GaugeValidator(address(this), INITIAL_MANAGER, address(0), bindings);

        vm.expectEmit(true, true, false, true, address(validator));
        emit FactoryPolicySet(address(factory), address(module), module.DIRECT_LP());
        validator.setFactoryPolicy(address(factory), address(module), module.DIRECT_LP());

        (address configuredModule, uint8 configuredId) = validator.policyForFactory(address(factory));
        assertEq(configuredModule, address(module));
        assertEq(configuredId, module.DIRECT_LP());

        vm.expectEmit(true, true, false, true, address(validator));
        emit FactoryPolicySet(address(factory), address(0), 0);
        validator.setFactoryPolicy(address(factory), address(0), 0);
        (configuredModule, configuredId) = validator.policyForFactory(address(factory));
        assertEq(configuredModule, address(0));
        assertEq(configuredId, 0);

        vm.expectEmit(true, false, false, true, address(validator));
        emit ProposalModuleSet(address(module));
        validator.setProposalModule(address(module));
        assertEq(validator.proposalModule(), address(module));

        vm.expectEmit(true, false, false, true, address(validator));
        emit ProposalModuleSet(address(0));
        validator.setProposalModule(address(0));
        assertEq(validator.proposalModule(), address(0));

        vm.expectRevert(GaugeValidator.ProposalModuleUnavailable.selector);
        validator.getActiveProposals();
        vm.expectRevert(GaugeValidator.ProposalModuleUnavailable.selector);
        validator.validateProposalGauges(0);
        vm.expectRevert(GaugeValidator.ProposalModuleUnavailable.selector);
        validator.analyzeProposalGauges(0);

        validator.transferOwnership(USER);
        assertEq(validator.owner(), USER);

        vm.prank(USER);
        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        validator.transferOwnership(address(0));
    }

    function test_InvalidOrUnauthorizedConfigurationReverts() public {
        MockCurveFactory factory = new MockCurveFactory();
        uint8 directLp = module.DIRECT_LP();
        GaugeValidator validator = _deploy(address(factory), directLp);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwnerOrManager.selector, USER));
        validator.setFactoryPolicy(address(factory), address(0), 0);

        vm.expectRevert(GaugeValidator.InvalidPolicy.selector);
        validator.setFactoryPolicy(address(factory), address(module), 0);

        vm.expectRevert(GaugeValidator.InvalidPolicy.selector);
        validator.setFactoryPolicy(address(factory), address(0), directLp);

        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        validator.setFactoryPolicy(address(0), address(module), directLp);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        validator.setFactoryPolicy(address(0x1234), address(module), directLp);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        validator.setFactoryPolicy(address(factory), address(0x1234), directLp);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, USER));
        validator.setProposalModule(address(module));

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        validator.setProposalModule(address(0x1234));

        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](0);
        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        new GaugeValidator(address(0), INITIAL_MANAGER, address(0), bindings);

        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        new GaugeValidator(address(this), address(0), address(0), bindings);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        new GaugeValidator(address(this), INITIAL_MANAGER, address(0x1234), bindings);
    }

    function test_ConstructorAppointsInitialManagerWhoCanManageFactoriesUntilRevoked() public {
        MockCurveFactory factory = new MockCurveFactory();
        uint8 directLp = module.DIRECT_LP();
        vm.expectEmit(true, false, false, true);
        emit ManagerSet(INITIAL_MANAGER, true);
        GaugeValidator validator = _deploy(address(factory), directLp);
        assertEq(validator.owner(), address(this));
        assertTrue(validator.managers(INITIAL_MANAGER));

        vm.prank(INITIAL_MANAGER);
        validator.setFactoryPolicy(address(factory), address(0), 0);
        (address policy, uint8 method) = validator.policyForFactory(address(factory));
        assertEq(policy, address(0));
        assertEq(method, 0);

        validator.setManager(INITIAL_MANAGER, false);
        vm.prank(INITIAL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwnerOrManager.selector, INITIAL_MANAGER));
        validator.setFactoryPolicy(address(factory), address(module), directLp);
    }

    function test_MultipleManagersCanImmediatelyManageAnyFactoryAndModule() public {
        MockCurveFactory firstFactory = new MockCurveFactory();
        MockCurveFactory secondFactory = new MockCurveFactory();
        MockProtocolGauge gauge = new MockProtocolGauge(address(secondFactory), address(0));
        MockValidationModule replacement = new MockValidationModule();
        replacement.setFactory(address(gauge), FUTURE_METHOD, address(secondFactory));
        GaugeValidator validator = _deploy(address(firstFactory), module.DIRECT_LP());
        address secondManager = address(0xCAFE);
        validator.setManager(USER, true);
        validator.setManager(secondManager, true);

        vm.prank(USER);
        validator.setFactoryPolicy(address(secondFactory), address(replacement), FUTURE_METHOD);
        assertTrue(validator.validateGauge(address(gauge)));

        vm.prank(secondManager);
        validator.setFactoryPolicy(address(secondFactory), address(0), 0);
        assertFalse(validator.validateGauge(address(gauge)));

        vm.prank(USER);
        validator.setFactoryPolicy(address(secondFactory), address(replacement), FUTURE_METHOD);
        vm.prank(secondManager);
        validator.setFactoryPolicy(address(firstFactory), address(replacement), FUTURE_METHOD);
        assertTrue(validator.validateGauge(address(gauge)));
        (address policy, uint8 method) = validator.policyForFactory(address(firstFactory));
        assertEq(policy, address(replacement));
        assertEq(method, FUTURE_METHOD);

        validator.setManager(USER, false);
        assertFalse(validator.managers(USER));
        assertTrue(validator.managers(secondManager));
        assertTrue(validator.validateGauge(address(gauge)));
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwnerOrManager.selector, USER));
        validator.setFactoryPolicy(address(secondFactory), address(0), 0);
        vm.prank(secondManager);
        validator.setFactoryPolicy(address(secondFactory), address(0), 0);
        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_ManagersCannotUseOwnerPowers() public {
        GaugeValidator validator = _deploy(address(new MockCurveFactory()), module.DIRECT_LP());
        assertFalse(validator.managers(USER));
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, USER));
        validator.setManager(USER, true);
        validator.setManager(USER, true);

        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, USER));
        validator.setManager(address(0xCAFE), true);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, USER));
        validator.setManager(USER, false);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, USER));
        validator.setProposalModule(address(module));
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, USER));
        validator.transferOwnership(USER);
        vm.stopPrank();
    }

    function test_ManagerEventsAndSingleStepOwnershipTransferPreserveAppointments() public {
        MockCurveFactory factory = new MockCurveFactory();
        GaugeValidator validator = _deploy(address(factory), module.DIRECT_LP());
        vm.expectEmit(true, false, false, true, address(validator));
        emit ManagerSet(USER, true);
        validator.setManager(USER, true);
        address nextOwner = address(0xCAFE);
        validator.transferOwnership(nextOwner);
        assertEq(validator.owner(), nextOwner);
        assertTrue(validator.managers(USER));
        assertTrue(validator.managers(INITIAL_MANAGER));
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, address(this)));
        validator.setManager(USER, false);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwnerOrManager.selector, address(this)));
        validator.setFactoryPolicy(address(factory), address(0), 0);
        vm.prank(USER);
        validator.setFactoryPolicy(address(factory), address(0), 0);
        vm.prank(nextOwner);
        vm.expectEmit(true, false, false, true, address(validator));
        emit ManagerSet(USER, false);
        validator.setManager(USER, false);
        assertFalse(validator.managers(USER));
    }

    function test_ManagerUpdatesRejectZeroAddress() public {
        GaugeValidator validator = _deploy(address(new MockCurveFactory()), module.DIRECT_LP());
        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        validator.setManager(address(0), true);
        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        validator.setManager(address(0), false);
    }

    function _assertFalseWithMethod(address gauge, address factory, uint8 methodId) private {
        GaugeValidator validator = _deploy(factory, methodId);
        assertFalse(validator.validateGauge(gauge));
    }

    function _deploy(address factory, uint8 methodId) private returns (GaugeValidator) {
        return _deploy(factory, address(module), methodId);
    }

    function _deploy(address factory, address policyModule, uint8 methodId) private returns (GaugeValidator) {
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](1);
        bindings[0] = GaugeValidator.FactoryBinding(factory, policyModule, methodId);
        return new GaugeValidator(address(this), INITIAL_MANAGER, address(0), bindings);
    }
}
