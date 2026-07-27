// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IProposalValidationModule {
    struct GaugeResult {
        address gauge;
        bool valid;
    }

    /// @notice Returns every currently open proposal in the configured DAO,
    ///         preserving proposal order.
    function getActiveProposals() external view returns (uint256[] memory proposalIds);

    /// @notice Returns whether every safely decoded gauge addition is standard
    ///         and currently passes the calling validator's gauge policy.
    function validateProposalGauges(uint256 proposalId) external view returns (bool);

    /// @notice Returns the aggregate result and one ordered result for every
    ///         safely decoded gauge addition.
    function analyzeProposalGauges(uint256 proposalId)
        external
        view
        returns (bool allValid, GaugeResult[] memory results);
}
