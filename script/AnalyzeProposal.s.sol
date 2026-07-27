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

        bool valid = ProposalGaugeValidator(proposalValidatorAddress).validateProposalGauges(proposalId);

        console2.log("proposal", proposalId);
        console2.log("valid", valid);
    }
}
