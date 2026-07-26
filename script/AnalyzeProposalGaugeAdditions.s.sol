// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {IProposalAnalysisModule} from "../src/interfaces/IProposalAnalysisModule.sol";

/// @notice Reads current-state gauge-addition analysis for one proposal.
contract AnalyzeProposalGaugeAdditions is Script {
    error MissingCode(address target);

    function run() external view {
        address validatorAddress = vm.envAddress("VALIDATOR");
        uint256 proposalId = vm.envUint("PROPOSAL_ID");
        if (validatorAddress.code.length == 0) revert MissingCode(validatorAddress);

        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            GaugeValidator(validatorAddress).analyzeProposalGaugeAdditions(proposalId);

        console2.log("proposal", proposalId);
        console2.log("analysis status", uint256(result.status));
        console2.log("all recognized gauge additions currently valid", result.allRecognizedGaugeAdditionsCurrentlyValid);
        console2.log("recognized gauge addition count", result.recognizedGaugeAdditions.length);

        for (uint256 i; i < result.recognizedGaugeAdditions.length; ++i) {
            IProposalAnalysisModule.GaugeAdditionAnalysis memory addition = result.recognizedGaugeAdditions[i];
            console2.log("addition", i);
            console2.log("gauge", addition.gauge);
            console2.log("currently valid", addition.currentlyValid);
            console2.logInt(addition.gaugeType);
            console2.log("initial weight", addition.initialWeight);
        }
    }
}
