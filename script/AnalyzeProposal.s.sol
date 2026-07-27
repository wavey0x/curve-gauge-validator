// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ProposalGaugeValidator} from "../src/ProposalGaugeValidator.sol";

/// @notice Reads current-state gauge validation for one ownership proposal.
contract AnalyzeProposal is Script {
    error MissingCode(address target);

    function run() external view {
        address proposalValidatorAddress = vm.envAddress("PROPOSAL_VALIDATOR");
        uint256 proposalId = vm.envUint("PROPOSAL_ID");
        if (proposalValidatorAddress.code.length == 0) revert MissingCode(proposalValidatorAddress);

        ProposalGaugeValidator.ProposalAnalysis memory result =
            ProposalGaugeValidator(proposalValidatorAddress).analyzeProposalGaugeAdditions(proposalId);

        console2.log("proposal", proposalId);
        console2.log("status", uint256(result.status));
        console2.log("all valid", result.allValid);
        console2.log("gauge count", result.gauges.length);

        for (uint256 i; i < result.gauges.length; ++i) {
            console2.log("gauge", result.gauges[i].gauge);
            console2.log("valid", result.gauges[i].valid);
        }
    }
}
