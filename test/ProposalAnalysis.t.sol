// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {ProposalAnalysisModuleV1} from "../src/ProposalAnalysisModuleV1.sol";
import {ICurveDAO} from "../src/interfaces/ICurveDAO.sol";
import {IProposalAnalysisModule} from "../src/interfaces/IProposalAnalysisModule.sol";
import {MockDAO, MockGauge, MockTarget, MockValidationModule} from "./helpers/Mocks.sol";

contract ProposalAnalysisTest is Test {
    bytes4 private constant ADD_GAUGE_SELECTOR = 0x18dfe921;
    bytes4 private constant AGENT_EXECUTE_SELECTOR = 0xb61d27f6;
    bytes4 private constant SET_BORROW_CAP_SELECTOR = 0x1d89f9bf;
    bytes32 private constant METHOD_A = "METHOD_A";
    bytes32 private constant METHOD_B = "METHOD_B";

    MockDAO private dao;
    MockTarget private agent;
    MockTarget private gaugeController;
    MockTarget private unrelatedTarget;
    MockTarget private configurator;
    MockValidationModule private moduleA;
    MockTarget private factoryA;
    MockGauge private gauge;
    ProposalAnalysisModuleV1 private analyzer;
    GaugeValidator private validator;

    function setUp() public {
        dao = new MockDAO();
        agent = new MockTarget();
        gaugeController = new MockTarget();
        unrelatedTarget = new MockTarget();
        configurator = new MockTarget();
        moduleA = new MockValidationModule();
        factoryA = new MockTarget();
        gauge = new MockGauge();

        GaugeValidator.Route[] memory routes = new GaugeValidator.Route[](1);
        routes[0] = GaugeValidator.Route(address(moduleA), METHOD_A);

        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](1);
        bindings[0] = GaugeValidator.FactoryBinding(address(factoryA), address(moduleA), METHOD_A);

        analyzer = new ProposalAnalysisModuleV1(ICurveDAO(address(dao)), address(agent), address(gaugeController));
        validator = new GaugeValidator(address(this), address(analyzer), routes, bindings);
        moduleA.setFactory(address(gauge), METHOD_A, address(factoryA));
    }

    function test_DirectGaugeControllerAdditionIsParsedAndEvaluated() public {
        uint256 proposalId =
            _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), int128(-1), 123))));

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            validator.analyzeProposalGaugeAdditions(proposalId);

        _assertComplete(result);
        assertTrue(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 1);
        assertEq(result.recognizedGaugeAdditions[0].gauge, address(gauge));
        assertEq(result.recognizedGaugeAdditions[0].gaugeType, -1);
        assertEq(result.recognizedGaugeAdditions[0].initialWeight, 123);
        assertTrue(result.recognizedGaugeAdditions[0].currentlyValid);
    }

    function test_AgentWrappedAdditionIsParsedAndEvaluated() public {
        bytes memory payload = _addGauge(address(gauge), 7, type(uint256).max);
        uint256 proposalId =
            _push(_callscript(_scriptCall(address(agent), _execute(address(gaugeController), 0, payload))));

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            validator.analyzeProposalGaugeAdditions(proposalId);

        _assertComplete(result);
        assertTrue(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 1);
        assertEq(result.recognizedGaugeAdditions[0].gaugeType, 7);
        assertEq(result.recognizedGaugeAdditions[0].initialWeight, type(uint256).max);
    }

    function test_UnrelatedCallsAreIgnoredAndAdditionOrderIsPreserved() public {
        MockGauge secondGauge = new MockGauge();
        moduleA.setFactory(address(secondGauge), METHOD_A, address(factoryA));

        bytes memory calls = bytes.concat(
            _scriptCall(address(unrelatedTarget), hex"12345678"),
            _scriptCall(address(gaugeController), _addGauge(address(gauge), 1, 2)),
            _scriptCall(address(unrelatedTarget), bytes.concat(hex"12345678", _addGauge(address(0xDEAD), 0, 0))),
            _scriptCall(address(agent), _execute(address(gaugeController), 0, _addGauge(address(secondGauge), 3, 4)))
        );

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            validator.analyzeProposalGaugeAdditions(_push(_callscript(calls)));

        _assertComplete(result);
        assertTrue(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 2);
        assertEq(result.recognizedGaugeAdditions[0].gauge, address(gauge));
        assertEq(result.recognizedGaugeAdditions[1].gauge, address(secondGauge));
    }

    function test_MarketActivationIsIgnoredAndDoesNotCreateGaugeValidity() public {
        MockGauge proposedGauge = new MockGauge();
        bytes memory setBorrowCap =
            abi.encodeWithSelector(SET_BORROW_CAP_SELECTOR, address(unrelatedTarget), uint256(1_000_000e18));

        bytes memory calls = bytes.concat(
            _scriptCall(address(agent), _execute(address(configurator), 0, setBorrowCap)),
            _scriptCall(address(gaugeController), _addGauge(address(proposedGauge), 0, 0))
        );

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            validator.analyzeProposalGaugeAdditions(_push(_callscript(calls)));

        _assertComplete(result);
        assertEq(result.recognizedGaugeAdditions.length, 1);
        assertEq(result.recognizedGaugeAdditions[0].gauge, address(proposedGauge));
        assertFalse(result.recognizedGaugeAdditions[0].currentlyValid);
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
    }

    function test_CompleteCallscriptWithNoRecognizedAdditionsHasFalseAggregate() public {
        IProposalAnalysisModule.ProposalGaugeAnalysis memory result = validator.analyzeProposalGaugeAdditions(
            _push(_callscript(_scriptCall(address(unrelatedTarget), hex"12345678")))
        );

        _assertComplete(result);
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 0);
    }

    function test_InvalidCurrentGaugeIsReportedWithoutRouteMetadata() public {
        moduleA.setFactory(address(gauge), METHOD_A, address(0));

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result = validator.analyzeProposalGaugeAdditions(
            _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0))))
        );

        _assertComplete(result);
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 1);
        assertFalse(result.recognizedGaugeAdditions[0].currentlyValid);
    }

    function test_AmbiguousCurrentGaugeIsReportedInvalid() public {
        MockValidationModule moduleB = new MockValidationModule();
        MockTarget factoryB = new MockTarget();
        validator.addRoute(address(moduleB), METHOD_B);
        validator.setFactoryRoute(address(factoryB), address(moduleB), METHOD_B);
        moduleB.setFactory(address(gauge), METHOD_B, address(factoryB));

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result = validator.analyzeProposalGaugeAdditions(
            _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0))))
        );

        _assertComplete(result);
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertFalse(result.recognizedGaugeAdditions[0].currentlyValid);
    }

    function test_RejectsWrongCallscriptIdentifierAndTrailingFragments() public {
        _assertRejected(hex"00000002");

        bytes memory validScript = _callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0)));
        _assertRejected(bytes.concat(validScript, hex"01"));
    }

    function test_RejectsTruncatedCallHeaderAndCalldata() public {
        _assertRejected(bytes.concat(hex"00000001", hex"01"));
        _assertRejected(
            bytes.concat(
                hex"00000001", abi.encodePacked(address(gaugeController), uint32(101), _addGauge(address(gauge), 0, 0))
            )
        );
    }

    function test_RejectsGaugeShapedCallThroughWrongTarget() public {
        _assertRejected(_callscript(_scriptCall(address(unrelatedTarget), _addGauge(address(gauge), 0, 0))));
    }

    function test_RejectsWrappedGaugeAdditionWithWrongTargetOrValue() public {
        _assertRejected(
            _callscript(
                _scriptCall(address(agent), _execute(address(unrelatedTarget), 0, _addGauge(address(gauge), 0, 0)))
            )
        );
        _assertRejected(
            _callscript(
                _scriptCall(address(agent), _execute(address(gaugeController), 1, _addGauge(address(gauge), 0, 0)))
            )
        );
    }

    function test_RejectsGaugeWrapperThroughWrongOuterTarget() public {
        _assertRejected(
            _callscript(
                _scriptCall(
                    address(unrelatedTarget), _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 0))
                )
            )
        );
        _assertRejected(
            _callscript(
                _scriptCall(
                    address(gaugeController), _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 0))
                )
            )
        );
    }

    function test_RejectsNoncanonicalAgentOffsetAddressAndPadding() public {
        bytes memory badOffset = _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 0));
        _storeWord(badOffset, 68, 64);
        _assertRejected(_callscript(_scriptCall(address(agent), badOffset)));

        bytes memory badAddress = _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 0));
        _storeWord(badAddress, 4, uint256(uint160(address(gaugeController))) | (uint256(1) << 160));
        _assertRejected(_callscript(_scriptCall(address(agent), badAddress)));

        bytes memory badPadding = _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 0));
        badPadding[badPadding.length - 1] = bytes1(uint8(1));
        _assertRejected(_callscript(_scriptCall(address(agent), badPadding)));
    }

    function test_RejectsNoncanonicalGaugeAddressAndSignedInteger() public {
        bytes memory badAddress = _addGauge(address(gauge), 0, 0);
        _storeWord(badAddress, 4, uint256(uint160(address(gauge))) | (uint256(1) << 160));
        _assertRejected(_callscript(_scriptCall(address(gaugeController), badAddress)));

        bytes memory badInt = _addGauge(address(gauge), 1, 0);
        _storeWord(badInt, 36, (uint256(1) << 128) | 1);
        _assertRejected(_callscript(_scriptCall(address(gaugeController), badInt)));
    }

    function test_RejectsNoncanonicalAddGaugeLength() public {
        bytes memory callData = bytes.concat(_addGauge(address(gauge), 0, 0), bytes32(0));
        _assertRejected(_callscript(_scriptCall(address(gaugeController), callData)));
    }

    function test_LaterMalformedCallDiscardsEarlierAddition() public {
        bytes memory calls = bytes.concat(
            _scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0)),
            abi.encodePacked(address(gaugeController), uint32(101), hex"1234")
        );
        _assertRejected(_callscript(calls));
    }

    function test_MalformedAgentExecuteIsRejectedEvenWithUnrelatedPayload() public {
        bytes memory execute = _execute(address(unrelatedTarget), 0, hex"12345678");
        _storeWord(execute, 68, 64);
        _assertRejected(_callscript(_scriptCall(address(agent), execute)));
    }

    function test_CanonicalAgentExecuteWithUnrelatedPayloadIsIgnored() public {
        IProposalAnalysisModule.ProposalGaugeAnalysis memory result = validator.analyzeProposalGaugeAdditions(
            _push(_callscript(_scriptCall(address(agent), _execute(address(unrelatedTarget), 1, hex"12345678"))))
        );

        _assertComplete(result);
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 0);
    }

    function test_RejectsRecursiveAgentExecute() public {
        bytes memory inner = _execute(address(gaugeController), 0, _addGauge(address(gauge), 0, 0));
        bytes memory outer = _execute(address(agent), 0, inner);
        _assertRejected(_callscript(_scriptCall(address(agent), outer)));
    }

    function test_EmptyCallscriptIsCompleteButContainsNoAdditions() public {
        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            validator.analyzeProposalGaugeAdditions(_push(hex"00000001"));

        _assertComplete(result);
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 0);
    }

    function test_MissingProposalIsUnavailable() public view {
        IProposalAnalysisModule.ProposalGaugeAnalysis memory result = validator.analyzeProposalGaugeAdditions(0);

        assertEq(uint256(result.status), uint256(IProposalAnalysisModule.AnalysisStatus.UNAVAILABLE));
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 0);
    }

    function test_DirectAnalyzerCallWithInvalidValidatorIsUnavailable() public {
        uint256 proposalId = _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0))));

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            analyzer.analyzeProposalGaugeAdditions(proposalId, address(0));

        assertEq(uint256(result.status), uint256(IProposalAnalysisModule.AnalysisStatus.UNAVAILABLE));
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 0);
    }

    function test_FailedValidatorQueryMakesOnlyTheAdditionInvalid() public {
        uint256 proposalId = _push(_callscript(_scriptCall(address(gaugeController), _addGauge(address(gauge), 0, 0))));

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            analyzer.analyzeProposalGaugeAdditions(proposalId, address(unrelatedTarget));

        _assertComplete(result);
        assertEq(result.recognizedGaugeAdditions.length, 1);
        assertFalse(result.recognizedGaugeAdditions[0].currentlyValid);
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
    }

    function test_AnalyzerConstructorRequiresCanonicalDependencies() public {
        vm.expectRevert(ProposalAnalysisModuleV1.ZeroAddress.selector);
        new ProposalAnalysisModuleV1(ICurveDAO(address(0)), address(agent), address(gaugeController));

        vm.expectRevert(abi.encodeWithSelector(ProposalAnalysisModuleV1.MissingCode.selector, address(0x1234)));
        new ProposalAnalysisModuleV1(ICurveDAO(address(dao)), address(0x1234), address(gaugeController));
    }

    function test_RecognizedAdditionCapAcceptsSixtyFourAndRejectsSixtyFive() public {
        bytes memory calls;
        int128 gaugeType;
        for (uint256 i; i < analyzer.MAX_RECOGNIZED_GAUGE_ADDITIONS(); ++i) {
            calls = bytes.concat(calls, _scriptCall(address(gaugeController), _addGauge(address(gauge), gaugeType, i)));
            ++gaugeType;
        }

        IProposalAnalysisModule.ProposalGaugeAnalysis memory atCap =
            validator.analyzeProposalGaugeAdditions(_push(_callscript(calls)));
        _assertComplete(atCap);
        assertTrue(atCap.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(atCap.recognizedGaugeAdditions.length, analyzer.MAX_RECOGNIZED_GAUGE_ADDITIONS());

        calls = bytes.concat(
            calls, _scriptCall(address(gaugeController), _addGauge(address(gauge), int128(64), uint256(64)))
        );
        _assertRejected(_callscript(calls));
    }

    function _assertComplete(IProposalAnalysisModule.ProposalGaugeAnalysis memory result) private pure {
        assertEq(uint256(result.status), uint256(IProposalAnalysisModule.AnalysisStatus.COMPLETE));
    }

    function _assertRejected(bytes memory script) private {
        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            validator.analyzeProposalGaugeAdditions(_push(script));

        assertEq(uint256(result.status), uint256(IProposalAnalysisModule.AnalysisStatus.CALLSCRIPT_REJECTED));
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 0);
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
