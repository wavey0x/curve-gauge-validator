// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {IProposalValidationModule} from "../src/interfaces/IProposalValidationModule.sol";

/// @notice Reads current-state gauge validation for one ownership proposal.
contract AnalyzeProposal is Script {
    error MissingCode(address target);

    function run() external view {
        address validatorAddress = vm.envAddress("VALIDATOR");
        uint256 proposalId = vm.envUint("PROPOSAL_ID");
        if (validatorAddress.code.length == 0) revert MissingCode(validatorAddress);

        (bool allValid, IProposalValidationModule.GaugeResult[] memory results) =
            GaugeValidator(validatorAddress).analyzeProposalGauges(proposalId);

        console2.log("proposal", proposalId);
        console2.log("all valid", allValid);
        for (uint256 i; i < results.length; ++i) {
            console2.log("gauge", results[i].gauge);
            console2.log("valid", results[i].valid);
        }
    }
}
