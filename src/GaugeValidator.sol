// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGaugeValidationModule} from "./interfaces/IGaugeValidationModule.sol";
import {IProposalValidationModule} from "./interfaces/IProposalValidationModule.sol";
import {ICurve} from "./interfaces/ICurve.sol";

/// @notice Stable entry point for trusted-factory gauge validation and
///         replaceable proposal validation.
contract GaugeValidator {
    uint256 public constant FACTORY_READ_GAS = 30_000;
    uint256 public constant MODULE_CALL_GAS = 2_000_000;

    struct FactoryPolicy {
        address module;
        uint8 methodId;
    }

    struct FactoryBinding {
        address factory;
        address module;
        uint8 methodId;
    }

    address public owner;
    address public proposalModule;

    /// @notice Exact policy for each trusted factory. A zero module means untrusted.
    mapping(address factory => FactoryPolicy policy) public policyForFactory;

    /// @notice Fully trusted accounts that may manage any factory policy.
    mapping(address manager => bool enabled) public managers;

    event FactoryPolicySet(address indexed factory, address indexed module, uint8 methodId);
    event ProposalModuleSet(address indexed module);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ManagerSet(address indexed manager, bool enabled);

    error NotOwner(address caller);
    error NotOwnerOrManager(address caller);
    error ZeroAddress();
    error InvalidPolicy();
    error MissingCode(address target);
    error ProposalModuleUnavailable();

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier onlyOwnerOrManager() {
        if (msg.sender != owner && !managers[msg.sender]) revert NotOwnerOrManager(msg.sender);
        _;
    }

    function _checkOwner() private view {
        if (msg.sender != owner) revert NotOwner(msg.sender);
    }

    constructor(
        address owner_,
        address initialManager_,
        address proposalModule_,
        FactoryBinding[] memory initialBindings
    ) {
        if (owner_ == address(0) || initialManager_ == address(0)) revert ZeroAddress();

        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        managers[initialManager_] = true;
        emit ManagerSet(initialManager_, true);
        _setProposalModule(proposalModule_);

        for (uint256 i; i < initialBindings.length; ++i) {
            FactoryBinding memory binding = initialBindings[i];
            _setFactoryPolicy(binding.factory, binding.module, binding.methodId);
        }
    }

    /// @notice Sets one factory's policy. A zero module removes trust.
    function setFactoryPolicy(address factory, address module, uint8 methodId) external onlyOwnerOrManager {
        _setFactoryPolicy(factory, module, methodId);
    }

    /// @notice Appoints or revokes a manager immediately. Existing policies remain intact.
    function setManager(address manager, bool enabled) external onlyOwner {
        if (manager == address(0)) revert ZeroAddress();
        managers[manager] = enabled;
        emit ManagerSet(manager, enabled);
    }

    /// @notice Replaces the proposal parser used by this stable entry point.
    ///         A zero address disables proposal validation.
    function setProposalModule(address module) external onlyOwner {
        _setProposalModule(module);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();

        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @notice Returns true only when the gauge names a trusted factory and
    ///         passes that factory's exact module policy.
    function validateGauge(address gauge) external view returns (bool) {
        if (gauge == address(0) || gauge.code.length == 0) return false;

        (bool success, address factory) = _readAddress(gauge, ICurve.factory.selector);
        if (!success || factory == address(0)) return false;

        FactoryPolicy memory policy = policyForFactory[factory];
        if (policy.module == address(0)) return false;

        (bool moduleCall, bool valid) = _callModule(policy.module, gauge, factory, policy.methodId);
        return moduleCall && valid;
    }

    /// @notice Returns every currently open proposal in the configured DAO,
    ///         preserving proposal order.
    /// @dev Proposal module and DAO read failures revert.
    function getActiveProposals() external view returns (uint256[] memory proposalIds) {
        address module = _proposalModule();
        return IProposalValidationModule(module).getActiveProposals();
    }

    /// @notice Returns whether all authenticated gauge additions in one
    ///         proposal are standard and currently valid.
    /// @dev Proposal module and DAO read failures revert.
    function validateProposalGauges(uint256 proposalId) external view returns (bool) {
        address module = _proposalModule();
        return IProposalValidationModule(module).validateProposalGauges(proposalId);
    }

    /// @notice Returns the aggregate result and one ordered result for every
    ///         safely decoded authenticated gauge addition.
    /// @dev Proposal module and DAO read failures revert.
    function analyzeProposalGauges(uint256 proposalId)
        external
        view
        returns (bool allValid, IProposalValidationModule.GaugeResult[] memory results)
    {
        address module = _proposalModule();
        return IProposalValidationModule(module).analyzeProposalGauges(proposalId);
    }

    function _setFactoryPolicy(address factory, address module, uint8 methodId) private {
        if (factory == address(0)) revert ZeroAddress();
        if (module == address(0)) {
            if (methodId != 0) revert InvalidPolicy();
            delete policyForFactory[factory];
        } else {
            if (methodId == 0) revert InvalidPolicy();
            _requireCode(factory);
            _requireCode(module);
            policyForFactory[factory] = FactoryPolicy({module: module, methodId: methodId});
        }

        emit FactoryPolicySet(factory, module, methodId);
    }

    function _setProposalModule(address module) private {
        if (module != address(0)) _requireCode(module);
        proposalModule = module;
        emit ProposalModuleSet(module);
    }

    function _proposalModule() private view returns (address module) {
        module = proposalModule;
        if (module == address(0)) revert ProposalModuleUnavailable();
    }

    function _readAddress(address target, bytes4 selector) private view returns (bool success, address value) {
        uint256 word;
        uint256 returnSize;

        assembly ("memory-safe") {
            mstore(0x00, selector)
            success := staticcall(FACTORY_READ_GAS, target, 0x00, 0x04, 0x00, 0x20)
            returnSize := returndatasize()
            word := mload(0x00)
        }

        if (!success || returnSize != 32 || word >> 160 != 0) return (false, address(0));

        // The canonical-address check above proves the narrowing is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        value = address(uint160(word));
    }

    function _callModule(address module, address gauge, address factory, uint8 methodId)
        private
        view
        returns (bool success, bool valid)
    {
        bytes4 selector = IGaugeValidationModule.validateGauge.selector;
        uint256 word;
        uint256 returnSize;

        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, selector)
            mstore(add(pointer, 0x04), and(gauge, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(pointer, 0x24), and(factory, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(pointer, 0x44), methodId)
            success := staticcall(MODULE_CALL_GAS, module, pointer, 0x64, pointer, 0x20)
            returnSize := returndatasize()
            word := mload(pointer)
        }

        if (!success || returnSize != 32 || word > 1) return (false, false);
        valid = word == 1;
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert MissingCode(target);
    }
}
