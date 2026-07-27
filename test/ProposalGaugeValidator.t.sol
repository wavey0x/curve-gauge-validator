// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {ProposalGaugeValidator} from "../src/ProposalGaugeValidator.sol";
import {ICurveDAO} from "../src/interfaces/ICurveDAO.sol";
import {
    ConfigurableDependency,
    GasFloorValidationModule,
    MockCurveFactory,
    MockDAO,
    MockProtocolGauge,
    MockTarget
} from "./helpers/Mocks.sol";

contract ProposalGaugeValidatorTest is Test {
    bytes4 private constant ADD_GAUGE_SELECTOR = 0x18dfe921;
    bytes4 private constant AGENT_EXECUTE_SELECTOR = 0xb61d27f6;

    MockDAO private dao;
    MockTarget private agent;
    MockTarget private gaugeController;
    MockTarget private unrelatedTarget;
    MockCurveFactory private factory;
    MockProtocolGauge private gauge;
    GaugeValidator private gaugeValidator;
    ProposalGaugeValidator private proposalValidator;

    function setUp() public {
        dao = new MockDAO();
        agent = new MockTarget();
        gaugeController = new MockTarget();
        unrelatedTarget = new MockTarget();
        factory = new MockCurveFactory();
        gauge = new MockProtocolGauge(address(factory), address(0));
        GaugeValidationModuleV1 module = new GaugeValidationModuleV1();

        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](1);
        bindings[0] = GaugeValidator.FactoryBinding(address(factory), address(module), module.FACTORY_IS_VALID_GAUGE());
        gaugeValidator = new GaugeValidator(address(this), bindings);
        factory.setValidGauge(address(gauge), true);

        proposalValidator = new ProposalGaugeValidator(
            ICurveDAO(address(dao)), address(agent), address(gaugeController), gaugeValidator
        );
    }

    function test_DirectAdditionReturnsSimpleGaugeBoolean() public {
        uint256 proposalId =
            _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), -1, 123))));

        assertTrue(proposalValidator.validateProposalGauges(proposalId));
    }

    function test_ProposalAllowsNearTwoMillionGasModule() public {
        GasFloorValidationModule expensiveModule = new GasFloorValidationModule(address(factory), 1_900_000);
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](1);
        bindings[0] = GaugeValidator.FactoryBinding(address(factory), address(expensiveModule), 1);
        GaugeValidator expensiveValidator = new GaugeValidator(address(this), bindings);
        ProposalGaugeValidator expensiveProposalValidator = new ProposalGaugeValidator(
            ICurveDAO(address(dao)), address(agent), address(gaugeController), expensiveValidator
        );
        uint256 proposalId =
            _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), -1, 123))));

        assertTrue(expensiveProposalValidator.validateProposalGauges(proposalId));
    }

    function test_AgentWrappedAdditionIsAuthenticated() public {
        bytes memory payload = _addGauge(address(gauge), 7, type(uint256).max);
        uint256 proposalId =
            _push(_callscript(_scriptCall(address(agent), _execute(address(gaugeController), 0, payload))));

        assertTrue(proposalValidator.validateProposalGauges(proposalId));
    }

    function test_UnrelatedCallsAreIgnoredAndAllAdditionsAreChecked() public {
        MockProtocolGauge secondGauge = new MockProtocolGauge(address(factory), address(0));
        factory.setValidGauge(address(secondGauge), true);

        bytes memory calls = bytes.concat(
            _scriptCall(address(unrelatedTarget), hex"12345678"),
            _scriptCall(address(gaugeController), _addGauge(address(gauge), 1, 2)),
            _scriptCall(address(unrelatedTarget), bytes.concat(hex"12345678", _addGauge(address(0xDEAD), 0, 0))),
            _scriptCall(address(agent), _execute(address(gaugeController), 0, _addGauge(address(secondGauge), 3, 4)))
        );

        assertTrue(proposalValidator.validateProposalGauges(_push(_callscript(calls))));
    }

    function test_OneInvalidGaugeMakesProposalFalse() public {
        MockProtocolGauge invalidGauge = new MockProtocolGauge(address(factory), address(0));
        bytes memory calls = bytes.concat(
            _scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0)),
            _scriptCall(address(gaugeController), _addGauge(address(invalidGauge), 0, 0))
        );

        assertFalse(proposalValidator.validateProposalGauges(_push(_callscript(calls))));
    }

    function test_NoGaugeAdditionCreatesNoGaugeRisk() public {
        uint256 proposalId = _push(_callscript(_scriptCall(address(unrelatedTarget), hex"12345678")));
        assertTrue(proposalValidator.validateProposalGauges(proposalId));
    }

    function test_NonExecutableCallscriptsCreateNoGaugeRisk() public {
        assertTrue(_validate(hex""));
        assertTrue(_validate(bytes.concat(hex"00000001", hex"01")));

        bytes memory validScript = _callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0)));
        assertTrue(_validate(bytes.concat(validScript, hex"01")));
        assertTrue(
            _validate(
                bytes.concat(
                    hex"00000001",
                    abi.encodePacked(address(gaugeController), uint32(101), _addGauge(address(gauge), 0, 0))
                )
            )
        );
    }

    function test_UnknownScriptExecutorIsPessimisticallyFalse() public {
        assertFalse(_validate(hex"00000002"));
    }

    function test_GaugeShapedCallThroughWrongTargetIsIgnored() public {
        MockProtocolGauge invalidGauge = new MockProtocolGauge(address(factory), address(0));
        assertTrue(
            _validate(_callscript(_scriptCall(address(unrelatedTarget), _addGauge(address(invalidGauge), 0, 0))))
        );
    }

    function test_UnauthenticatedOrRevertingWrappedAdditionsAreIgnored() public {
        MockProtocolGauge invalidGauge = new MockProtocolGauge(address(factory), address(0));
        assertTrue(
            _validate(
                _callscript(
                    _scriptCall(
                        address(agent), _execute(address(unrelatedTarget), 0, _addGauge(address(invalidGauge), 0, 0))
                    )
                )
            )
        );
        assertTrue(
            _validate(
                _callscript(
                    _scriptCall(
                        address(agent), _execute(address(gaugeController), 1, _addGauge(address(invalidGauge), 0, 0))
                    )
                )
            )
        );
        assertTrue(
            _validate(
                _callscript(
                    _scriptCall(
                        address(unrelatedTarget),
                        _execute(address(gaugeController), 0, _addGauge(address(invalidGauge), 0, 0))
                    )
                )
            )
        );
    }

    function test_NoncanonicalAgentEncodingIsRejected() public {
        bytes memory badOffset = _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 0));
        _storeWord(badOffset, 68, 64);
        assertFalse(_validate(_callscript(_scriptCall(address(agent), badOffset))));

        bytes memory badAddress = _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 0));
        _storeWord(badAddress, 4, uint256(uint160(address(gaugeController))) | (uint256(1) << 160));
        assertFalse(_validate(_callscript(_scriptCall(address(agent), badAddress))));

        bytes memory badPadding = _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 0));
        badPadding[badPadding.length - 1] = bytes1(uint8(1));
        assertFalse(_validate(_callscript(_scriptCall(address(agent), badPadding))));
    }

    function test_NoncanonicalAddGaugeEncodingIsRejected() public {
        bytes memory badAddress = _addGauge(address(gauge), 0, 0);
        _storeWord(badAddress, 4, uint256(uint160(address(gauge))) | (uint256(1) << 160));
        assertFalse(_validate(_callscript(_scriptCall(address(gaugeController), badAddress))));

        bytes memory badInt = _addGauge(address(gauge), 1, 0);
        _storeWord(badInt, 36, (uint256(1) << 128) | 1);
        assertFalse(_validate(_callscript(_scriptCall(address(gaugeController), badInt))));

        bytes memory badLength = bytes.concat(_addGauge(address(gauge), 0, 0), bytes32(0));
        assertFalse(_validate(_callscript(_scriptCall(address(gaugeController), badLength))));
    }

    function test_LaterStructuralFailureMakesWholeProposalNonExecutable() public {
        MockProtocolGauge invalidGauge = new MockProtocolGauge(address(factory), address(0));
        bytes memory calls = bytes.concat(
            _scriptCall(address(gaugeController), _addGauge(address(invalidGauge), 0, 0)),
            abi.encodePacked(address(gaugeController), uint32(101), hex"1234")
        );
        assertTrue(_validate(_callscript(calls)));
    }

    function test_MalformedAgentCallIsFalseButCanonicalUnrelatedPayloadIsIgnored() public {
        bytes memory malformed = _execute(address(unrelatedTarget), 0, hex"12345678");
        _storeWord(malformed, 68, 64);
        assertFalse(_validate(_callscript(_scriptCall(address(agent), malformed))));

        assertTrue(
            _validate(_callscript(_scriptCall(address(agent), _execute(address(unrelatedTarget), 1, hex"12345678"))))
        );
    }

    function test_RecursiveAgentExecuteIsPessimisticallyFalse() public {
        bytes memory inner = _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 0));
        bytes memory outer = _execute(address(agent), 0, inner);
        assertFalse(_validate(_callscript(_scriptCall(address(agent), outer))));
    }

    function test_MissingProposalReverts() public {
        vm.expectRevert();
        proposalValidator.validateProposalGauges(0);
    }

    function test_EveryValidatorFailureModeMakesGaugeInvalid() public {
        uint256 proposalId = _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0))));

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            ProposalGaugeValidator candidate = new ProposalGaugeValidator(
                ICurveDAO(address(dao)), address(agent), address(gaugeController), GaugeValidator(address(dependency))
            );

            assertFalse(candidate.validateProposalGauges(proposalId));
        }
    }

    function test_MoreThanSixtyFourGaugesHaveNoAnalyzerCap() public {
        bytes memory calls;
        int128 gaugeType;
        for (uint256 i; i < 65; ++i) {
            calls = bytes.concat(calls, _scriptCall(address(gaugeController), _addGauge(address(gauge), gaugeType, i)));
            ++gaugeType;
        }

        assertTrue(_validate(_callscript(calls)));
    }

    function test_ConstructorRequiresContractDependencies() public {
        vm.expectRevert(ProposalGaugeValidator.ZeroAddress.selector);
        new ProposalGaugeValidator(ICurveDAO(address(0)), address(agent), address(gaugeController), gaugeValidator);

        vm.expectRevert(abi.encodeWithSelector(ProposalGaugeValidator.MissingCode.selector, address(0x1234)));
        new ProposalGaugeValidator(ICurveDAO(address(dao)), address(0x1234), address(gaugeController), gaugeValidator);
    }

    function _validate(bytes memory script) private returns (bool) {
        return proposalValidator.validateProposalGauges(_push(script));
    }

    function _push(bytes memory script) private returns (uint256) {
        return dao.pushVote(script);
    }

    function _addGauge(address gauge_, int128 gaugeType, uint256 initialWeight) private pure returns (bytes memory) {
        return abi.encodeWithSelector(ADD_GAUGE_SELECTOR, gauge_, gaugeType, initialWeight);
    }

    function _execute(address target, uint256 value, bytes memory payload) private pure returns (bytes memory) {
        return abi.encodeWithSelector(AGENT_EXECUTE_SELECTOR, target, value, payload);
    }

    function _callscript(bytes memory calls) private pure returns (bytes memory) {
        return bytes.concat(hex"00000001", calls);
    }

    function _scriptCall(address target, bytes memory callData) private pure returns (bytes memory) {
        return abi.encodePacked(target, uint32(callData.length), callData);
    }

    function _storeWord(bytes memory data, uint256 offset, uint256 value) private pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 0x20), offset), value)
        }
    }
}
