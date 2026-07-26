// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ICurveDAO {
    function getVote(uint256 voteId)
        external
        view
        returns (
            bool open,
            bool executed,
            uint64 startDate,
            uint64 snapshotBlock,
            uint64 supportRequired,
            uint64 minAcceptQuorum,
            uint256 yea,
            uint256 nay,
            uint256 votingPower,
            bytes memory script
        );
}
