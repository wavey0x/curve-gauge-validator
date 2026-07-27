// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {ProposalValidationModuleV1} from "../src/ProposalValidationModuleV1.sol";
import {ICurveDAO} from "../src/interfaces/ICurveDAO.sol";
import {IProposalValidationModule} from "../src/interfaces/IProposalValidationModule.sol";
import {
    ConfigurableDependency,
    GasFloorValidationModule,
    MockCurveFactory,
    MockDAO,
    MockProtocolGauge,
    MockTarget
} from "./helpers/Mocks.sol";

contract ProposalValidationModuleTest is Test {
    bytes4 private constant ADD_GAUGE_DEFAULT_WEIGHT_SELECTOR = bytes4(keccak256("add_gauge(address,int128)"));
    bytes4 private constant ADD_GAUGE_SELECTOR = 0x18dfe921;
    bytes4 private constant AGENT_EXECUTE_SELECTOR = 0xb61d27f6;

    MockDAO private dao;
    MockTarget private agent;
    MockTarget private gaugeController;
    MockTarget private unrelatedTarget;
    MockCurveFactory private factory;
    MockProtocolGauge private gauge;
    GaugeValidator private gaugeValidator;
    ProposalValidationModuleV1 private proposalModule;

    function setUp() public {
        dao = new MockDAO();
        agent = new MockTarget();
        gaugeController = new MockTarget();
        unrelatedTarget = new MockTarget();
        factory = new MockCurveFactory();
        gauge = new MockProtocolGauge(address(factory), address(0));
        GaugeValidationModuleV1 module = new GaugeValidationModuleV1();
        proposalModule =
            new ProposalValidationModuleV1(ICurveDAO(address(dao)), address(agent), address(gaugeController));

        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](1);
        bindings[0] = GaugeValidator.FactoryBinding(address(factory), address(module), module.FACTORY_IS_VALID_GAUGE());
        gaugeValidator = new GaugeValidator(address(this), address(proposalModule), bindings);
        factory.setValidGauge(address(gauge), true);
    }

    function test_DirectAdditionReturnsSimpleGaugeBoolean() public {
        uint256 proposalId = _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), -1, 0))));

        assertTrue(gaugeValidator.validateProposalGauges(proposalId));
    }

    function test_ProposalAllowsNearTwoMillionGasModule() public {
        GasFloorValidationModule expensiveModule = new GasFloorValidationModule(address(factory), 1_900_000);
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](1);
        bindings[0] = GaugeValidator.FactoryBinding(address(factory), address(expensiveModule), 1);
        GaugeValidator expensiveValidator = new GaugeValidator(address(this), address(proposalModule), bindings);
        uint256 proposalId = _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), -1, 0))));

        assertTrue(expensiveValidator.validateProposalGauges(proposalId));
    }

    function test_AgentWrappedAdditionIsAuthenticated() public {
        bytes memory payload = _addGauge(address(gauge), 7, 0);
        uint256 proposalId =
            _push(_callscript(_scriptCall(address(agent), _execute(address(gaugeController), 0, payload))));

        assertTrue(gaugeValidator.validateProposalGauges(proposalId));
    }

    function test_DefaultWeightAdditionValidatesGauge() public {
        MockProtocolGauge invalidGauge = new MockProtocolGauge(address(factory), address(0));

        assertTrue(
            _validate(_callscript(_scriptCall(address(gaugeController), _addGaugeDefaultWeight(address(gauge), 0))))
        );
        assertFalse(
            _validate(
                _callscript(_scriptCall(address(gaugeController), _addGaugeDefaultWeight(address(invalidGauge), 0)))
            )
        );
        assertTrue(
            _validate(
                _callscript(
                    _scriptCall(
                        address(agent), _execute(address(gaugeController), 0, _addGaugeDefaultWeight(address(gauge), 0))
                    )
                )
            )
        );
        assertFalse(
            _validate(
                _callscript(
                    _scriptCall(
                        address(agent),
                        _execute(address(gaugeController), 0, _addGaugeDefaultWeight(address(invalidGauge), 0))
                    )
                )
            )
        );
    }

    function test_NonzeroInitialWeightIsRejected() public {
        assertFalse(_validate(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 1)))));
        assertFalse(
            _validate(
                _callscript(
                    _scriptCall(address(agent), _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 1)))
                )
            )
        );
    }

    function test_UnrelatedCallsAreIgnoredAndAllAdditionsAreChecked() public {
        MockProtocolGauge secondGauge = new MockProtocolGauge(address(factory), address(0));
        factory.setValidGauge(address(secondGauge), true);

        bytes memory calls = bytes.concat(
            _scriptCall(address(unrelatedTarget), hex"12345678"),
            _scriptCall(address(gaugeController), _addGauge(address(gauge), 1, 0)),
            _scriptCall(address(unrelatedTarget), bytes.concat(hex"12345678", _addGauge(address(0xDEAD), 0, 0))),
            _scriptCall(address(agent), _execute(address(gaugeController), 0, _addGauge(address(secondGauge), 3, 0)))
        );

        assertTrue(gaugeValidator.validateProposalGauges(_push(_callscript(calls))));
    }

    function test_OneInvalidGaugeMakesProposalFalse() public {
        MockProtocolGauge invalidGauge = new MockProtocolGauge(address(factory), address(0));
        bytes memory calls = bytes.concat(
            _scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0)),
            _scriptCall(address(gaugeController), _addGauge(address(invalidGauge), 0, 0))
        );

        assertFalse(gaugeValidator.validateProposalGauges(_push(_callscript(calls))));
    }

    function test_DetailedAnalysisReturnsTwoOfThreeOrderedGaugeResults() public {
        MockProtocolGauge invalidGauge = new MockProtocolGauge(address(factory), address(0));
        MockProtocolGauge secondValidGauge = new MockProtocolGauge(address(factory), address(0));
        factory.setValidGauge(address(secondValidGauge), true);

        bytes memory calls = bytes.concat(
            _scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0)),
            _scriptCall(address(gaugeController), _addGaugeDefaultWeight(address(invalidGauge), 1)),
            _scriptCall(
                address(agent), _execute(address(gaugeController), 0, _addGauge(address(secondValidGauge), 2, 0))
            )
        );

        (bool allValid, IProposalValidationModule.GaugeResult[] memory results) = _analyze(_callscript(calls));

        assertFalse(allValid);
        assertEq(results.length, 3);
        assertEq(results[0].gauge, address(gauge));
        assertTrue(results[0].valid);
        assertEq(results[1].gauge, address(invalidGauge));
        assertFalse(results[1].valid);
        assertEq(results[2].gauge, address(secondValidGauge));
        assertTrue(results[2].valid);
    }

    function test_DetailedAnalysisAttributesNonzeroWeightToDecodedGauge() public {
        (bool allValid, IProposalValidationModule.GaugeResult[] memory results) = _analyze(
            _callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), 0, type(uint256).max)))
        );

        assertFalse(allValid);
        assertEq(results.length, 1);
        assertEq(results[0].gauge, address(gauge));
        assertFalse(results[0].valid);
    }

    function test_DetailedAnalysisDoesNotInventGaugeForUnattributableFailure() public {
        bytes memory badAddress = _addGauge(address(gauge), 0, 0);
        _storeWord(badAddress, 4, uint256(uint160(address(gauge))) | (uint256(1) << 160));

        (bool allValid, IProposalValidationModule.GaugeResult[] memory results) =
            _analyze(_callscript(_scriptCall(address(gaugeController), badAddress)));

        assertFalse(allValid);
        assertEq(results.length, 0);
    }

    function test_DetailedAnalysisReturnsEmptyWhenNoGaugeCanExecute() public {
        (bool noGaugeRisk, IProposalValidationModule.GaugeResult[] memory noGaugeResults) =
            _analyze(_callscript(_scriptCall(address(unrelatedTarget), hex"12345678")));
        assertTrue(noGaugeRisk);
        assertEq(noGaugeResults.length, 0);

        (bool unknownExecutor, IProposalValidationModule.GaugeResult[] memory unknownResults) = _analyze(hex"00000002");
        assertFalse(unknownExecutor);
        assertEq(unknownResults.length, 0);

        MockProtocolGauge invalidGauge = new MockProtocolGauge(address(factory), address(0));
        bytes memory structurallyInvalid = _callscript(
            bytes.concat(
                _scriptCall(address(gaugeController), _addGauge(address(invalidGauge), 0, 0)),
                abi.encodePacked(address(gaugeController), uint32(101), hex"1234")
            )
        );
        (bool executableRisk, IProposalValidationModule.GaugeResult[] memory discardedResults) =
            _analyze(structurallyInvalid);
        assertTrue(executableRisk);
        assertEq(discardedResults.length, 0);
    }

    function test_ProposalModuleCanBeReplacedWithoutChangingEntrypoint() public {
        MockProtocolGauge invalidGauge = new MockProtocolGauge(address(factory), address(0));
        uint256 oldProposalId =
            _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(invalidGauge), 0, 0))));
        assertFalse(gaugeValidator.validateProposalGauges(oldProposalId));

        MockDAO replacementDao = new MockDAO();
        uint256 replacementProposalId =
            replacementDao.pushVote(_callscript(_scriptCall(address(unrelatedTarget), hex"12345678")));
        ProposalValidationModuleV1 replacement = new ProposalValidationModuleV1(
            ICurveDAO(address(replacementDao)), address(agent), address(gaugeController)
        );

        address entrypoint = address(gaugeValidator);
        gaugeValidator.setProposalModule(address(replacement));

        assertEq(address(gaugeValidator), entrypoint);
        assertEq(gaugeValidator.proposalModule(), address(replacement));
        assertTrue(gaugeValidator.validateProposalGauges(replacementProposalId));
        assertTrue(gaugeValidator.validateGauge(address(gauge)));
    }

    function test_NoGaugeAdditionCreatesNoGaugeRisk() public {
        uint256 proposalId = _push(_callscript(_scriptCall(address(unrelatedTarget), hex"12345678")));
        assertTrue(gaugeValidator.validateProposalGauges(proposalId));
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

        bytes memory badDefaultWeightAddress = _addGaugeDefaultWeight(address(gauge), 0);
        _storeWord(badDefaultWeightAddress, 4, uint256(uint160(address(gauge))) | (uint256(1) << 160));
        assertFalse(_validate(_callscript(_scriptCall(address(gaugeController), badDefaultWeightAddress))));

        bytes memory badInt = _addGauge(address(gauge), 1, 0);
        _storeWord(badInt, 36, (uint256(1) << 128) | 1);
        assertFalse(_validate(_callscript(_scriptCall(address(gaugeController), badInt))));

        bytes memory badDefaultWeightInt = _addGaugeDefaultWeight(address(gauge), 1);
        _storeWord(badDefaultWeightInt, 36, (uint256(1) << 128) | 1);
        assertFalse(_validate(_callscript(_scriptCall(address(gaugeController), badDefaultWeightInt))));

        bytes memory badLength = bytes.concat(_addGauge(address(gauge), 0, 0), bytes32(0));
        assertFalse(_validate(_callscript(_scriptCall(address(gaugeController), badLength))));

        bytes memory badDefaultWeightLength = bytes.concat(_addGaugeDefaultWeight(address(gauge), 0), bytes32(0));
        assertFalse(_validate(_callscript(_scriptCall(address(gaugeController), badDefaultWeightLength))));
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
        gaugeValidator.validateProposalGauges(0);
    }

    function test_EveryValidatorFailureModeMakesGaugeInvalid() public {
        uint256 proposalId = _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0))));

        for (uint256 mode; mode <= uint256(ConfigurableDependency.Mode.RETURN_DATA_BOMB); ++mode) {
            ConfigurableDependency dependency = new ConfigurableDependency(ConfigurableDependency.Mode(mode));
            GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](1);
            bindings[0] = GaugeValidator.FactoryBinding(address(factory), address(dependency), 1);
            GaugeValidator candidate = new GaugeValidator(address(this), address(proposalModule), bindings);

            assertFalse(candidate.validateProposalGauges(proposalId));
        }
    }

    function test_MoreThanSixtyFourGaugesHaveNoAnalyzerCap() public {
        bytes memory calls;
        int128 gaugeType;
        for (uint256 i; i < 65; ++i) {
            calls = bytes.concat(calls, _scriptCall(address(gaugeController), _addGauge(address(gauge), gaugeType, 0)));
            ++gaugeType;
        }

        (bool allValid, IProposalValidationModule.GaugeResult[] memory results) = _analyze(_callscript(calls));
        assertTrue(allValid);
        assertEq(results.length, 65);
        assertEq(results[0].gauge, address(gauge));
        assertEq(results[64].gauge, address(gauge));
        assertTrue(results[0].valid);
        assertTrue(results[64].valid);
    }

    function test_ConstructorRequiresContractDependencies() public {
        vm.expectRevert(ProposalValidationModuleV1.ZeroAddress.selector);
        new ProposalValidationModuleV1(ICurveDAO(address(0)), address(agent), address(gaugeController));

        vm.expectRevert(abi.encodeWithSelector(ProposalValidationModuleV1.MissingCode.selector, address(0x1234)));
        new ProposalValidationModuleV1(ICurveDAO(address(dao)), address(0x1234), address(gaugeController));
    }

    function _validate(bytes memory script) private returns (bool) {
        return gaugeValidator.validateProposalGauges(_push(script));
    }

    function _analyze(bytes memory script)
        private
        returns (bool allValid, IProposalValidationModule.GaugeResult[] memory results)
    {
        return gaugeValidator.analyzeProposalGauges(_push(script));
    }

    function _push(bytes memory script) private returns (uint256) {
        return dao.pushVote(script);
    }

    function _addGauge(address gauge_, int128 gaugeType, uint256 initialWeight) private pure returns (bytes memory) {
        return abi.encodeWithSelector(ADD_GAUGE_SELECTOR, gauge_, gaugeType, initialWeight);
    }

    function _addGaugeDefaultWeight(address gauge_, int128 gaugeType) private pure returns (bytes memory) {
        return abi.encodeWithSelector(ADD_GAUGE_DEFAULT_WEIGHT_SELECTOR, gauge_, gaugeType);
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
