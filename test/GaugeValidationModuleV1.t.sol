// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {
    ConfigurableDependency,
    MockCurveFactory,
    MockPoolToken,
    MockProtocolGauge,
    MockTarget,
    NoncanonicalBoolFactory,
    NoncanonicalFactoryGauge,
    ReturnDataBombDependency,
    RevertingDependency
} from "./helpers/Mocks.sol";

contract GaugeValidationModuleV1Test is Test {
    bytes32 private constant UNKNOWN = "UNKNOWN";

    GaugeValidationModuleV1 private module;

    function setUp() public {
        module = new GaugeValidationModuleV1();
    }

    function test_DirectLpRequiresReciprocalFactoryLookup() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget lpToken = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(lpToken));

        assertEq(_resolve(address(gauge), module.DIRECT_LP()), address(0));

        factory.setGauge(address(lpToken), address(gauge));
        assertEq(_resolve(address(gauge), module.DIRECT_LP()), address(factory));

        factory.setGauge(address(lpToken), address(0x1234));
        assertEq(_resolve(address(gauge), module.DIRECT_LP()), address(0));
    }

    function test_DirectOrPoolLpAcceptsDirectLookup() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget lpToken = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(lpToken));
        factory.setGauge(address(lpToken), address(gauge));

        assertEq(_resolve(address(gauge), module.DIRECT_OR_POOL_LP()), address(factory));
    }

    function test_DirectOrPoolLpAcceptsPoolFallbackWithoutTokenRoundTrip() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget pool = new MockTarget();
        MockPoolToken lpToken = new MockPoolToken(address(pool));
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(lpToken));
        factory.setGauge(address(pool), address(gauge));

        assertEq(_resolve(address(gauge), module.DIRECT_OR_POOL_LP()), address(factory));
    }

    function test_DirectOrPoolLpRejectsSpoofedPoolRelationship() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget pool = new MockTarget();
        MockPoolToken lpToken = new MockPoolToken(address(pool));
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(lpToken));
        factory.setGauge(address(pool), address(0x1234));

        assertEq(_resolve(address(gauge), module.DIRECT_OR_POOL_LP()), address(0));
    }

    function test_VaultUsesOnlyGaugeForVaultMethod() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget vault = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(vault));
        factory.setVaultGauge(address(vault), address(gauge));

        assertEq(_resolve(address(gauge), module.VAULT()), address(factory));
        assertEq(_resolve(address(gauge), module.DIRECT_LP()), address(0));
    }

    function test_VaultRejectsNonreciprocalFactoryLookup() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget vault = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(vault));
        factory.setVaultGauge(address(vault), address(0x1234));

        assertEq(_resolve(address(gauge), module.VAULT()), address(0));
    }

    function test_FactoryIsValidGaugeNeedsNoFamilySpecificShapeCheck() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(0));
        factory.setValidGauge(address(gauge), true);

        assertEq(_resolve(address(gauge), module.FACTORY_IS_VALID_GAUGE()), address(factory));
    }

    function test_FactoryIsValidGaugeRejectsFactoryFalse() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(0));

        assertEq(_resolve(address(gauge), module.FACTORY_IS_VALID_GAUGE()), address(0));
    }

    function test_FactoryIsValidGaugeRequiresCanonicalTrueFromFactory() public {
        NoncanonicalBoolFactory factory = new NoncanonicalBoolFactory();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(0));

        assertEq(_resolve(address(gauge), module.FACTORY_IS_VALID_GAUGE()), address(0));
    }

    function test_UnknownValidationIdReturnsZero() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget lpToken = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(lpToken));
        factory.setGauge(address(lpToken), address(gauge));

        assertEq(_resolve(address(gauge), UNKNOWN), address(0));
    }

    function test_CodeLessGaugeAndSelfReportedFactoryAreInsufficient() public {
        assertEq(_resolve(address(0x1234), module.DIRECT_LP()), address(0));

        MockCurveFactory factory = new MockCurveFactory();
        MockTarget lpToken = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(lpToken));
        assertEq(_resolve(address(gauge), module.DIRECT_LP()), address(0));
    }

    function test_NoncanonicalAddressAndDependencyFailuresFailClosed() public {
        MockTarget lpToken = new MockTarget();
        NoncanonicalFactoryGauge malformedGauge = new NoncanonicalFactoryGauge(address(lpToken));
        assertEq(_resolve(address(malformedGauge), module.DIRECT_LP()), address(0));

        MockProtocolGauge revertingGauge = new MockProtocolGauge(address(new RevertingDependency()), address(lpToken));
        assertEq(_resolve(address(revertingGauge), module.DIRECT_LP()), address(0));

        MockProtocolGauge bombGauge = new MockProtocolGauge(address(new ReturnDataBombDependency()), address(lpToken));
        assertEq(_resolve(address(bombGauge), module.DIRECT_LP()), address(0));
    }

    function test_EveryFactoryDependencyFailureReturnsZeroForEveryMethod() public {
        MockTarget token = new MockTarget();

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            MockProtocolGauge gauge = new MockProtocolGauge(address(dependency), address(token));

            _assertAllMethodsZero(address(gauge));
        }
    }

    function test_EveryGaugeGetterFailureReturnsZero() public {
        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));

            _assertAllMethodsZero(address(dependency));
        }
    }

    function test_EveryLpTokenGetterFailureReturnsZero() public {
        MockCurveFactory factory = new MockCurveFactory();
        MockTarget token = new MockTarget();
        MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(token));
        bytes memory callData = abi.encodeWithSignature("lp_token()");

        vm.mockCallRevert(address(gauge), callData, bytes("failure"));
        _assertAllMethodsZero(address(gauge));
        vm.clearMockedCalls();

        vm.mockCall(address(gauge), callData, hex"01");
        _assertAllMethodsZero(address(gauge));
        vm.clearMockedCalls();

        vm.mockCall(address(gauge), callData, abi.encode(uint256(1) << 160));
        _assertAllMethodsZero(address(gauge));
    }

    function test_EveryPoolMinterDependencyFailureReturnsZero() public {
        MockCurveFactory factory = new MockCurveFactory();

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            MockProtocolGauge gauge = new MockProtocolGauge(address(factory), address(dependency));

            assertEq(_resolve(address(gauge), module.DIRECT_OR_POOL_LP()), address(0));
        }
    }

    function _assertAllMethodsZero(address gauge) private view {
        assertEq(_resolve(gauge, module.DIRECT_LP()), address(0));
        assertEq(_resolve(gauge, module.DIRECT_OR_POOL_LP()), address(0));
        assertEq(_resolve(gauge, module.VAULT()), address(0));
        assertEq(_resolve(gauge, module.FACTORY_IS_VALID_GAUGE()), address(0));
    }

    function _resolve(address gauge, bytes32 validationId) private view returns (address) {
        return module.factoryForGauge(gauge, validationId);
    }
}
