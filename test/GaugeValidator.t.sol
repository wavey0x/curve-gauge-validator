// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {
    ConfigurableDependency,
    MockCurveFactory,
    MockPoolToken,
    MockProtocolGauge,
    MockTarget,
    NoncanonicalBoolFactory,
    NoncanonicalFactoryGauge
} from "./helpers/Mocks.sol";

contract GaugeValidatorTest is Test {
    address private constant USER = address(0xB0B);

    function test_DirectLpRequiresReciprocalFactoryLookup() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget lpToken = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(lpToken));
        GaugeValidator validator = _deploy(address(factory), GaugeValidator.Proof.DIRECT_LP);

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
        GaugeValidator validator = _deploy(address(factory), GaugeValidator.Proof.DIRECT_OR_POOL_LP);

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
        GaugeValidator validator = _deploy(address(factory), GaugeValidator.Proof.VAULT);

        assertFalse(validator.validateGauge(address(gauge)));

        factory.setVaultGauge(address(vault), address(gauge));
        assertTrue(validator.validateGauge(address(gauge)));
    }

    function test_FactoryAttestationRequiresCanonicalTrue() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(0));
        GaugeValidator validator = _deploy(address(factory), GaugeValidator.Proof.FACTORY_IS_VALID_GAUGE);

        assertFalse(validator.validateGauge(address(gauge)));
        factory.setValidGauge(address(gauge), true);
        assertTrue(validator.validateGauge(address(gauge)));

        NoncanonicalBoolFactory malformedFactory = new NoncanonicalBoolFactory();
        gauge.setFactory(address(malformedFactory));
        validator.setFactoryTrust(address(malformedFactory), GaugeValidator.Proof.FACTORY_IS_VALID_GAUGE);
        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_UntrustedFactoryAndSelfReportReturnFalse() public {
        MockCurveFactory trustedFactory = new MockCurveFactory();
        MockCurveFactory untrustedFactory = new MockCurveFactory();
        MockTarget token = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(untrustedFactory), address(token));
        GaugeValidator validator = _deploy(address(trustedFactory), GaugeValidator.Proof.DIRECT_LP);

        untrustedFactory.setGauge(address(token), address(gauge));
        assertFalse(validator.validateGauge(address(gauge)));

        gauge.setFactory(address(trustedFactory));
        assertFalse(validator.validateGauge(address(gauge)));
    }

    function test_ZeroCodeLessAndMalformedGaugeReturnFalse() public {
        MockCurveFactory factory = new MockCurveFactory();
        GaugeValidator validator = _deploy(address(factory), GaugeValidator.Proof.DIRECT_LP);

        assertFalse(validator.validateGauge(address(0)));
        assertFalse(validator.validateGauge(address(0x1234)));

        NoncanonicalFactoryGauge malformed = new NoncanonicalFactoryGauge(address(0));
        assertFalse(validator.validateGauge(address(malformed)));

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            assertFalse(validator.validateGauge(address(dependency)));
        }
    }

    function test_EveryFactoryDependencyFailureReturnsFalseForEveryProof() public {
        MockTarget token = new MockTarget();

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            MockProtocolGauge gauge = new MockProtocolGauge(address(dependency), address(token));

            _assertFalseWithProof(address(gauge), address(dependency), GaugeValidator.Proof.DIRECT_LP);
            _assertFalseWithProof(address(gauge), address(dependency), GaugeValidator.Proof.DIRECT_OR_POOL_LP);
            _assertFalseWithProof(address(gauge), address(dependency), GaugeValidator.Proof.VAULT);
            _assertFalseWithProof(address(gauge), address(dependency), GaugeValidator.Proof.FACTORY_IS_VALID_GAUGE);
        }
    }

    function test_EveryLpAndMinterFailureReturnsFalse() public {
        MockCurveFactory factory = new MockCurveFactory();

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            MockProtocolGauge candidateGauge = new MockProtocolGauge(address(factory), address(dependency));

            _assertFalseWithProof(address(candidateGauge), address(factory), GaugeValidator.Proof.DIRECT_OR_POOL_LP);
            _assertFalseWithProof(address(candidateGauge), address(factory), GaugeValidator.Proof.VAULT);
        }

        MockTarget token = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(token));
        bytes memory callData = abi.encodeWithSignature("lp_token()");

        GaugeValidator direct = _deploy(address(factory), GaugeValidator.Proof.DIRECT_LP);
        vm.mockCallRevert(address(gauge), callData, bytes("failure"));
        assertFalse(direct.validateGauge(address(gauge)));
        vm.clearMockedCalls();

        vm.mockCall(address(gauge), callData, hex"01");
        assertFalse(direct.validateGauge(address(gauge)));
        vm.clearMockedCalls();

        vm.mockCall(address(gauge), callData, abi.encode(uint256(1) << 160));
        assertFalse(direct.validateGauge(address(gauge)));
    }

    function test_OwnerCanSetRemoveTrustAndTransferOwnership() public {
        MockCurveFactory factory = new MockCurveFactory();
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](0);
        GaugeValidator validator = new GaugeValidator(address(this), bindings);

        validator.setFactoryTrust(address(factory), GaugeValidator.Proof.DIRECT_LP);
        assertEq(uint256(validator.proofForFactory(address(factory))), uint256(GaugeValidator.Proof.DIRECT_LP));

        validator.setFactoryTrust(address(factory), GaugeValidator.Proof.NONE);
        assertEq(uint256(validator.proofForFactory(address(factory))), uint256(GaugeValidator.Proof.NONE));

        validator.transferOwnership(USER);
        assertEq(validator.owner(), USER);

        vm.prank(USER);
        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        validator.transferOwnership(address(0));
    }

    function test_InvalidOrUnauthorizedConfigurationReverts() public {
        MockCurveFactory factory = new MockCurveFactory();
        GaugeValidator validator = _deploy(address(factory), GaugeValidator.Proof.DIRECT_LP);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.NotOwner.selector, USER));
        validator.setFactoryTrust(address(factory), GaugeValidator.Proof.NONE);

        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        validator.setFactoryTrust(address(0), GaugeValidator.Proof.DIRECT_LP);

        vm.expectRevert(abi.encodeWithSelector(GaugeValidator.MissingCode.selector, address(0x1234)));
        validator.setFactoryTrust(address(0x1234), GaugeValidator.Proof.DIRECT_LP);

        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](0);
        vm.expectRevert(GaugeValidator.ZeroAddress.selector);
        new GaugeValidator(address(0), bindings);
    }

    function _assertFalseWithProof(address gauge, address factory, GaugeValidator.Proof proof) private {
        GaugeValidator validator = _deploy(factory, proof);
        assertFalse(validator.validateGauge(gauge));
    }

    function _deploy(address factory, GaugeValidator.Proof proof) private returns (GaugeValidator) {
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](1);
        bindings[0] = GaugeValidator.FactoryBinding(factory, proof);
        return new GaugeValidator(address(this), bindings);
    }
}
