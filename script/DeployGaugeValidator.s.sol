// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalValidationModuleV1} from "../src/ProposalValidationModuleV1.sol";

interface ICreateX {
    function deployCreate2(bytes32 salt, bytes memory initCode) external payable returns (address newContract);

    /// @dev `salt` must already be transformed by CreateX's guard.
    function computeCreate2Address(bytes32 salt, bytes32 initCodeHash) external view returns (address computedAddress);
}

/// @notice Deploys only the new core, reusing the verified mainnet proof and proposal modules.
/// @dev The salt is permissioned to DEPLOYER and protected for Ethereum chain ID 1.
contract DeployGaugeValidator is Script {
    address public constant DEPLOYER = 0x2C2dc95F8C8060a7e3B354c1B9540881AEa1613C;
    address public constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    bytes32 public constant CREATE_X_RUNTIME_HASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    bytes32 public constant VALIDATOR_SALT = 0x2c2dc95f8c8060a7e3b354c1b9540881aea1613c010000000000000000000001;
    address public constant VALIDATOR_ADDRESS = 0x956418112dEceC17042854599dF6375E6ec70414;
    address public constant GAUGE_MODULE_ADDRESS = MainnetGaugeConfiguration.GAUGE_MODULE;
    address public constant PROPOSAL_MODULE_ADDRESS = MainnetGaugeConfiguration.PROPOSAL_MODULE;

    bytes32 public constant VALIDATOR_INIT_CODE_HASH =
        0x83c9225f5be347b0fcd4c076c7aeecaaf2c172b80887622be042bbc74eef4f45;
    bytes32 public constant VALIDATOR_RUNTIME_HASH = 0x2d684822a3f2bf6f99f902474289219041443a9d9cc94cbc28505050185016cd;
    // These hashes identify the reused onchain modules, including their original metadata.
    bytes32 public constant GAUGE_MODULE_RUNTIME_HASH =
        0xfc5562e86bbf44b97a41e6e1e1f578a396c0fd4a5aaac85805ef62630fca36ff;
    bytes32 public constant PROPOSAL_MODULE_RUNTIME_HASH =
        0xd49b4f008c10caa5c87d86e9daf22c1db5c9bef8cada3f49a0c92218c98db3f1;

    error InvalidSalt(bytes32 salt);
    error CreateXCodeHashMismatch(bytes32 actual);
    error InitCodeHashMismatch(bytes32 expected, bytes32 actual);
    error ComputedAddressMismatch(address expected, address actual);
    error RuntimeCodeHashMismatch(address target, bytes32 expected, bytes32 actual);
    error DeploymentInvariantFailed();

    function run() external returns (GaugeValidator validator) {
        if (CREATE_X.codehash != CREATE_X_RUNTIME_HASH) revert CreateXCodeHashMismatch(CREATE_X.codehash);
        _assertRuntime(GAUGE_MODULE_ADDRESS, GAUGE_MODULE_RUNTIME_HASH);
        _assertRuntime(PROPOSAL_MODULE_ADDRESS, PROPOSAL_MODULE_RUNTIME_HASH);

        ProposalValidationModuleV1 proposalModule = ProposalValidationModuleV1(PROPOSAL_MODULE_ADDRESS);
        if (
            address(proposalModule.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalModule.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalModule.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
        ) revert DeploymentInvariantFailed();

        bytes memory initCode = abi.encodePacked(
            type(GaugeValidator).creationCode,
            abi.encode(
                MainnetGaugeConfiguration.OWNER,
                MainnetGaugeConfiguration.INITIAL_MANAGER,
                PROPOSAL_MODULE_ADDRESS,
                MainnetGaugeConfiguration.bindings(GAUGE_MODULE_ADDRESS)
            )
        );
        _assertArtifact(initCode);

        if (VALIDATOR_ADDRESS.code.length == 0) {
            vm.startBroadcast(DEPLOYER);
            address deployed = ICreateX(CREATE_X).deployCreate2(VALIDATOR_SALT, initCode);
            vm.stopBroadcast();
            if (deployed != VALIDATOR_ADDRESS) revert ComputedAddressMismatch(VALIDATOR_ADDRESS, deployed);
        }
        _assertRuntime(VALIDATOR_ADDRESS, VALIDATOR_RUNTIME_HASH);

        validator = GaugeValidator(VALIDATOR_ADDRESS);
        if (
            validator.owner() != MainnetGaugeConfiguration.OWNER
                || !validator.managers(MainnetGaugeConfiguration.INITIAL_MANAGER)
                || validator.proposalModule() != PROPOSAL_MODULE_ADDRESS
        ) revert DeploymentInvariantFailed();

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings(GAUGE_MODULE_ADDRESS);
        for (uint256 i; i < bindings.length; ++i) {
            (address module, uint8 methodId) = validator.policyForFactory(bindings[i].factory);
            if (module != bindings[i].module || methodId != bindings[i].methodId) {
                revert DeploymentInvariantFailed();
            }
        }
    }

    function _assertArtifact(bytes memory initCode) private view {
        // bytes20 intentionally selects CreateX's first 20 salt bytes.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(VALIDATOR_SALT)) != DEPLOYER || VALIDATOR_SALT[20] != 0x01) {
            revert InvalidSalt(VALIDATOR_SALT);
        }
        bytes32 actualHash = keccak256(initCode);
        if (actualHash != VALIDATOR_INIT_CODE_HASH) {
            revert InitCodeHashMismatch(VALIDATOR_INIT_CODE_HASH, actualHash);
        }
        bytes32 guardedSalt = keccak256(abi.encode(DEPLOYER, uint256(1), VALIDATOR_SALT));
        address computedAddress = ICreateX(CREATE_X).computeCreate2Address(guardedSalt, actualHash);
        if (computedAddress != VALIDATOR_ADDRESS) revert ComputedAddressMismatch(VALIDATOR_ADDRESS, computedAddress);
    }

    function _assertRuntime(address target, bytes32 expectedHash) private view {
        if (target.code.length == 0 || target.codehash != expectedHash) {
            revert RuntimeCodeHashMismatch(target, expectedHash, target.codehash);
        }
    }
}
