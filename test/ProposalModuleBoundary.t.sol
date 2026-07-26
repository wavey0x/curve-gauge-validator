// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {IProposalAnalysisModule} from "../src/interfaces/IProposalAnalysisModule.sol";
import {MockProposalAnalysisModule} from "./helpers/Mocks.sol";

contract ProposalModuleBoundaryTest is Test {
    MockProposalAnalysisModule private analyzerA;
    MockProposalAnalysisModule private analyzerB;
    GaugeValidator private validator;

    function setUp() public {
        analyzerA = new MockProposalAnalysisModule();
        analyzerB = new MockProposalAnalysisModule();

        GaugeValidator.Route[] memory routes = new GaugeValidator.Route[](0);
        GaugeValidator.FactoryBinding[] memory bindings = new GaugeValidator.FactoryBinding[](0);
        validator = new GaugeValidator(address(this), address(analyzerA), routes, bindings);
    }

    function test_ReplacementChangesProposalPolicy() public {
        _setSingleAddition(analyzerA, address(0xA), true);
        _setSingleAddition(analyzerB, address(0xB), false);

        IProposalAnalysisModule.ProposalGaugeAnalysis memory beforeResult = validator.analyzeProposalGaugeAdditions(1);
        assertEq(beforeResult.recognizedGaugeAdditions[0].gauge, address(0xA));
        assertTrue(beforeResult.allRecognizedGaugeAdditionsCurrentlyValid);

        validator.setProposalAnalysisModule(address(analyzerB));

        IProposalAnalysisModule.ProposalGaugeAnalysis memory afterResult = validator.analyzeProposalGaugeAdditions(1);
        assertEq(afterResult.recognizedGaugeAdditions[0].gauge, address(0xB));
        assertFalse(afterResult.allRecognizedGaugeAdditionsCurrentlyValid);
    }

    function test_DisabledAnalyzerReturnsUnavailable() public {
        validator.setProposalAnalysisModule(address(0));

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result = validator.analyzeProposalGaugeAdditions(1);

        assertEq(uint256(result.status), uint256(IProposalAnalysisModule.AnalysisStatus.UNAVAILABLE));
        assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 0);
    }

    function test_RevertingAndGasExhaustingAnalyzerReturnUnavailable() public {
        for (uint256 mode = 1; mode <= 2; ++mode) {
            analyzerA.setMode(MockProposalAnalysisModule.Mode(mode));

            IProposalAnalysisModule.ProposalGaugeAnalysis memory result = validator.analyzeProposalGaugeAdditions(1);

            assertEq(uint256(result.status), uint256(IProposalAnalysisModule.AnalysisStatus.UNAVAILABLE));
            assertFalse(result.allRecognizedGaugeAdditionsCurrentlyValid);
            assertEq(result.recognizedGaugeAdditions.length, 0);
        }
    }

    function test_CoreReturnsTrustedAnalyzerResultWithoutReimplementingPolicy() public {
        _setSingleAddition(analyzerA, address(0xA), true);

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result = validator.analyzeProposalGaugeAdditions(7);

        assertEq(uint256(result.status), uint256(IProposalAnalysisModule.AnalysisStatus.COMPLETE));
        assertTrue(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 1);
        assertEq(result.recognizedGaugeAdditions[0].gauge, address(0xA));
        assertTrue(result.recognizedGaugeAdditions[0].currentlyValid);
    }

    function _setSingleAddition(MockProposalAnalysisModule analyzer, address gauge, bool currentlyValid) private {
        IProposalAnalysisModule.GaugeAdditionAnalysis memory addition = IProposalAnalysisModule.GaugeAdditionAnalysis({
            gauge: gauge, gaugeType: int128(0), initialWeight: 0, currentlyValid: currentlyValid
        });

        analyzer.setResult(IProposalAnalysisModule.AnalysisStatus.COMPLETE, currentlyValid, true, addition);
    }
}
