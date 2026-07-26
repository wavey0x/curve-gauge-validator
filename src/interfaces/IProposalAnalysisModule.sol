// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IProposalAnalysisModule {
    enum AnalysisStatus {
        UNAVAILABLE,
        CALLSCRIPT_REJECTED,
        COMPLETE
    }

    struct GaugeAdditionAnalysis {
        address gauge;
        int128 gaugeType;
        uint256 initialWeight;
        bool currentlyValid;
    }

    struct ProposalGaugeAnalysis {
        AnalysisStatus status;
        bool allRecognizedGaugeAdditionsCurrentlyValid;
        GaugeAdditionAnalysis[] recognizedGaugeAdditions;
    }

    function analyzeProposalGaugeAdditions(uint256 proposalId, address validator)
        external
        view
        returns (ProposalGaugeAnalysis memory result);
}
