// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalValidationModuleV1} from "../src/ProposalValidationModuleV1.sol";
import {ICurveDAO} from "../src/interfaces/ICurveDAO.sol";

interface ICreateX {
    function deployCreate2(bytes32 salt, bytes memory initCode) external payable returns (address newContract);

    /// @dev `salt` must already be transformed by CreateX's guard.
    function computeCreate2Address(bytes32 salt, bytes32 initCodeHash) external view returns (address computedAddress);
}

/// @notice Deterministically deploys both policy modules and their stable
///         validator entry point through the canonical CreateX factory.
/// @dev CREATE2 binds each vanity address to exact init code and constructor
///      configuration. The prefixes identify the core (`999901`), gauge module
///      (`999902`), and proposal module (`999903`). Module addresses are fixed
///      first because the core init code embeds both of them.
contract DeployGaugeValidator is Script {
    uint256 public constant MAINNET_CHAIN_ID = 1;

    address public constant DEPLOYER = 0x2C2dc95F8C8060a7e3B354c1B9540881AEa1613C;
    address public constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    bytes32 public constant CREATE_X_RUNTIME_HASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    // Mined with https://github.com/HrikB/createXcrunch. Re-mine with
    // `--caller DEPLOYER --crosschain 1` whenever an init-code hash changes.
    // Each salt is permissioned and Ethereum-specific (the 21st byte is 0x01).
    bytes32 public constant VALIDATOR_SALT = 0x2c2dc95f8c8060a7e3b354c1b9540881aea1613c01f43d3cfa0a2d4000561fbe;
    bytes32 public constant GAUGE_MODULE_SALT = 0x2c2dc95f8c8060a7e3b354c1b9540881aea1613c011cc0121e214409019d3a6b;
    bytes32 public constant PROPOSAL_MODULE_SALT = 0x2c2dc95f8c8060a7e3b354c1b9540881aea1613c012d0bdba43f734d02d6de78;

    address public constant VALIDATOR_ADDRESS = 0x999901cd8568Caafeb8888F18C1F5B870B58b7F2;
    address public constant GAUGE_MODULE_ADDRESS = 0x999902533033Cc63c8128C501e307477932B742E;
    address public constant PROPOSAL_MODULE_ADDRESS = 0x9999032142B45AE92e11a5E10A45F49f58b67773;

    bytes32 public constant VALIDATOR_INIT_CODE_HASH =
        0x9bf642c270680a42db39f3b2d0ead80f8c6042582f16548639a043d3ca6108ff;
    bytes32 public constant GAUGE_MODULE_INIT_CODE_HASH =
        0x2a944782183c12811b036aa32e9bf7e1c982816bd72c160bcf88a1ed2dc8cbaf;
    bytes32 public constant PROPOSAL_MODULE_INIT_CODE_HASH =
        0x493b287f9317c13740bf28ac500015f5c0872bb46db115c98ed7489459564b12;

    bytes32 public constant VALIDATOR_RUNTIME_HASH = 0xe8e4a20207d33eecfc4751611432d207c3d3d7cdc8eb5598e4ce9e830ca4bec0;
    bytes32 public constant GAUGE_MODULE_RUNTIME_HASH =
        0xfc5562e86bbf44b97a41e6e1e1f578a396c0fd4a5aaac85805ef62630fca36ff;
    bytes32 public constant PROPOSAL_MODULE_RUNTIME_HASH =
        0x9d8da113c2b60b53fd7a94a2b364670a50fda7f2884dc351d822bf4fc9312621;

    error WrongChain(uint256 chainId);
    error InvalidSalt(bytes32 salt);
    error CreateXCodeHashMismatch(bytes32 actual);
    error InitCodeHashMismatch(bytes32 expected, bytes32 actual);
    error ComputedAddressMismatch(address expected, address actual);
    error RuntimeCodeHashMismatch(address target, bytes32 expected, bytes32 actual);
    error DeploymentInvariantFailed();

    function run()
        external
        returns (
            GaugeValidationModuleV1 gaugeModule,
            ProposalValidationModuleV1 proposalModule,
            GaugeValidator validator
        )
    {
        if (block.chainid != MAINNET_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }

        if (CREATE_X.codehash != CREATE_X_RUNTIME_HASH) {
            revert CreateXCodeHashMismatch(CREATE_X.codehash);
        }

        bytes memory gaugeModuleInitCode = type(GaugeValidationModuleV1).creationCode;
        bytes memory proposalModuleInitCode = abi.encodePacked(
            type(ProposalValidationModuleV1).creationCode,
            abi.encode(
                ICurveDAO(MainnetGaugeConfiguration.DAO),
                MainnetGaugeConfiguration.OWNER,
                MainnetGaugeConfiguration.GAUGE_CONTROLLER
            )
        );
        bytes memory validatorInitCode = abi.encodePacked(
            type(GaugeValidator).creationCode,
            abi.encode(
                MainnetGaugeConfiguration.OWNER,
                PROPOSAL_MODULE_ADDRESS,
                MainnetGaugeConfiguration.bindings(GAUGE_MODULE_ADDRESS)
            )
        );

        _assertArtifact(GAUGE_MODULE_SALT, gaugeModuleInitCode, GAUGE_MODULE_INIT_CODE_HASH, GAUGE_MODULE_ADDRESS);
        _assertArtifact(
            PROPOSAL_MODULE_SALT, proposalModuleInitCode, PROPOSAL_MODULE_INIT_CODE_HASH, PROPOSAL_MODULE_ADDRESS
        );
        _assertArtifact(VALIDATOR_SALT, validatorInitCode, VALIDATOR_INIT_CODE_HASH, VALIDATOR_ADDRESS);

        _assertRuntimeIfPresent(GAUGE_MODULE_ADDRESS, GAUGE_MODULE_RUNTIME_HASH);
        _assertRuntimeIfPresent(PROPOSAL_MODULE_ADDRESS, PROPOSAL_MODULE_RUNTIME_HASH);
        _assertRuntimeIfPresent(VALIDATOR_ADDRESS, VALIDATOR_RUNTIME_HASH);

        vm.startBroadcast(DEPLOYER);
        _deployIfMissing(GAUGE_MODULE_ADDRESS, GAUGE_MODULE_SALT, gaugeModuleInitCode, GAUGE_MODULE_RUNTIME_HASH);
        _deployIfMissing(
            PROPOSAL_MODULE_ADDRESS, PROPOSAL_MODULE_SALT, proposalModuleInitCode, PROPOSAL_MODULE_RUNTIME_HASH
        );
        _deployIfMissing(VALIDATOR_ADDRESS, VALIDATOR_SALT, validatorInitCode, VALIDATOR_RUNTIME_HASH);
        vm.stopBroadcast();

        gaugeModule = GaugeValidationModuleV1(GAUGE_MODULE_ADDRESS);
        proposalModule = ProposalValidationModuleV1(PROPOSAL_MODULE_ADDRESS);
        validator = GaugeValidator(VALIDATOR_ADDRESS);
        _assertDeployment(gaugeModule, proposalModule, validator);
    }

    function _assertArtifact(bytes32 salt, bytes memory initCode, bytes32 expectedHash, address expectedAddress)
        private
        view
    {
        // bytes20 intentionally selects CreateX's first 20 salt bytes.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(salt)) != DEPLOYER || salt[20] != 0x01) {
            revert InvalidSalt(salt);
        }

        bytes32 actualHash = keccak256(initCode);
        if (actualHash != expectedHash) {
            revert InitCodeHashMismatch(expectedHash, actualHash);
        }

        bytes32 guardedSalt = keccak256(abi.encode(DEPLOYER, MAINNET_CHAIN_ID, salt));
        address computedAddress = ICreateX(CREATE_X).computeCreate2Address(guardedSalt, actualHash);
        if (computedAddress != expectedAddress) {
            revert ComputedAddressMismatch(expectedAddress, computedAddress);
        }
    }

    function _assertRuntimeIfPresent(address target, bytes32 expectedRuntimeHash) private view {
        if (target.code.length != 0 && target.codehash != expectedRuntimeHash) {
            revert RuntimeCodeHashMismatch(target, expectedRuntimeHash, target.codehash);
        }
    }

    function _deployIfMissing(address expectedAddress, bytes32 salt, bytes memory initCode, bytes32 expectedRuntimeHash)
        private
    {
        if (expectedAddress.code.length != 0) return;

        address deployed = ICreateX(CREATE_X).deployCreate2(salt, initCode);
        if (deployed != expectedAddress) {
            revert ComputedAddressMismatch(expectedAddress, deployed);
        }
        if (deployed.codehash != expectedRuntimeHash) {
            revert RuntimeCodeHashMismatch(deployed, expectedRuntimeHash, deployed.codehash);
        }
    }

    function _assertDeployment(
        GaugeValidationModuleV1 gaugeModule,
        ProposalValidationModuleV1 proposalModule,
        GaugeValidator validator
    ) private view {
        if (
            address(gaugeModule) != GAUGE_MODULE_ADDRESS || address(proposalModule) != PROPOSAL_MODULE_ADDRESS
                || address(validator) != VALIDATOR_ADDRESS || address(gaugeModule).codehash != GAUGE_MODULE_RUNTIME_HASH
                || address(proposalModule).codehash != PROPOSAL_MODULE_RUNTIME_HASH
                || address(validator).codehash != VALIDATOR_RUNTIME_HASH
                || validator.owner() != MainnetGaugeConfiguration.OWNER
                || validator.proposalModule() != address(proposalModule)
                || address(proposalModule.DAO()) != MainnetGaugeConfiguration.DAO
                || proposalModule.AGENT() != MainnetGaugeConfiguration.OWNER
                || proposalModule.GAUGE_CONTROLLER() != MainnetGaugeConfiguration.GAUGE_CONTROLLER
        ) revert DeploymentInvariantFailed();

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings(address(gaugeModule));
        for (uint256 i; i < bindings.length; ++i) {
            (address module, uint8 methodId) = validator.policyForFactory(bindings[i].factory);
            if (module != bindings[i].module || methodId != bindings[i].methodId) {
                revert DeploymentInvariantFailed();
            }
        }
    }
}
