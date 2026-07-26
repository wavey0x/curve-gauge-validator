// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalGaugeValidator} from "../src/ProposalGaugeValidator.sol";
import {ICurveDAO} from "../src/interfaces/ICurveDAO.sol";

/// @notice Deploys the gauge predicate and its proposal consumer in two transactions.
contract DeployGaugeValidator is Script {
    uint256 public constant MAINNET_CHAIN_ID = 1;

    error WrongChain(uint256 chainId);
    error DeploymentInvariantFailed();

    function run() external returns (GaugeValidator validator, ProposalGaugeValidator proposalValidator) {
        if (block.chainid != MAINNET_CHAIN_ID) revert WrongChain(block.chainid);

        vm.startBroadcast();
        validator = new GaugeValidator(MainnetGaugeConfiguration.OWNER, MainnetGaugeConfiguration.bindings());
        proposalValidator = new ProposalGaugeValidator(
            ICurveDAO(MainnetGaugeConfiguration.DAO),
            MainnetGaugeConfiguration.OWNER,
            MainnetGaugeConfiguration.GAUGE_CONTROLLER,
            validator
        );
        vm.stopBroadcast();

        _assertDeployment(validator, proposalValidator);
    }

    function _assertDeployment(GaugeValidator validator, ProposalGaugeValidator proposalValidator) private view {
        if (
            validator.owner() != MainnetGaugeConfiguration.OWNER
                || address(proposalValidator.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalValidator.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalValidator.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
                || address(proposalValidator.GAUGE_VALIDATOR()) != address(validator)
        ) revert DeploymentInvariantFailed();

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings();
        for (uint256 i; i < bindings.length; ++i) {
            if (validator.proofForFactory(bindings[i].factory) != bindings[i].proof) {
                revert DeploymentInvariantFailed();
            }
        }
    }
}
