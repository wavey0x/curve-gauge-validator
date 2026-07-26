// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGaugeValidationModule} from "./interfaces/IGaugeValidationModule.sol";
import {IProposalAnalysisModule} from "./interfaces/IProposalAnalysisModule.sol";

/// @notice Validates Curve gauge candidates through owner-configured policy
///         IDs and exposes replaceable gauge and proposal policy modules.
/// @dev Validation IDs are intentionally opaque to the core. Factory bindings
///      persist while an ID is disabled so governance can re-enable policy
///      without reconstructing configuration.
contract GaugeValidator {
    /// @notice Maximum number of simultaneously active validation IDs.
    uint256 public constant MAX_VALIDATION_IDS = 16;

    /// @notice Gas forwarded to each gauge-policy call.
    uint256 public constant MODULE_CALL_GAS = 200_000;

    /// @notice Gas forwarded to the active proposal analyzer.
    uint256 public constant PROPOSAL_ANALYSIS_CALL_GAS = 20_000_000;

    uint256 private constant VALIDATION_ID_GAS_RESERVE = MODULE_CALL_GAS + 20_000;
    uint256 private constant FINAL_RESULT_GAS_RESERVE = 25_000;

    address public owner;
    address public gaugeValidationModule;
    address public proposalAnalysisModule;

    struct FactoryBinding {
        address factory;
        bytes32 validationId;
    }

    bytes32[] private _validationIds;
    mapping(bytes32 validationId => uint256 indexPlusOne) private _validationIdIndexPlusOne;

    /// @notice Exact validation ID configured for each factory, or zero when disabled.
    mapping(address factory => bytes32 validationId) public validationIdForFactory;

    event ValidationIdAdded(bytes32 indexed validationId);
    event ValidationIdRemoved(bytes32 indexed validationId);
    event FactoryValidationIdSet(
        address indexed factory, bytes32 indexed previousValidationId, bytes32 indexed newValidationId
    );
    event GaugeValidationModuleSet(address indexed previousModule, address indexed newModule);
    event ProposalAnalysisModuleSet(address indexed previousModule, address indexed newModule);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner(address caller);
    error ZeroAddress();
    error MissingCode(address target);
    error ZeroValidationId();
    error ValidationIdLimitReached();

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function _checkOwner() private view {
        if (msg.sender != owner) revert NotOwner(msg.sender);
    }

    constructor(
        address owner_,
        address gaugeValidationModule_,
        address proposalAnalysisModule_,
        bytes32[] memory initialValidationIds,
        FactoryBinding[] memory initialBindings
    ) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (gaugeValidationModule_ != address(0)) _requireCode(gaugeValidationModule_);
        if (proposalAnalysisModule_ != address(0)) _requireCode(proposalAnalysisModule_);

        owner = owner_;
        gaugeValidationModule = gaugeValidationModule_;
        proposalAnalysisModule = proposalAnalysisModule_;

        emit OwnershipTransferred(address(0), owner_);
        emit GaugeValidationModuleSet(address(0), gaugeValidationModule_);
        emit ProposalAnalysisModuleSet(address(0), proposalAnalysisModule_);

        for (uint256 i; i < initialValidationIds.length; ++i) {
            _addValidationId(initialValidationIds[i]);
        }

        // Bindings are deliberately applied in order. Repeated factories use
        // the final entry, matching sequential governance configuration.
        for (uint256 i; i < initialBindings.length; ++i) {
            FactoryBinding memory binding = initialBindings[i];
            _setFactoryValidationId(binding.factory, binding.validationId);
        }
    }

    // ---------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------

    /// @notice Enables a validation ID. Enabling an active ID is a no-op.
    function addValidationId(bytes32 validationId) external onlyOwner {
        _addValidationId(validationId);
    }

    /// @notice Disables a validation ID without deleting factory bindings.
    ///         Disabling an inactive ID is a no-op.
    function removeValidationId(bytes32 validationId) external onlyOwner {
        uint256 indexPlusOne = _validationIdIndexPlusOne[validationId];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _validationIds.length - 1;
        if (index != lastIndex) {
            bytes32 moved = _validationIds[lastIndex];
            _validationIds[index] = moved;
            _validationIdIndexPlusOne[moved] = index + 1;
        }

        _validationIds.pop();
        delete _validationIdIndexPlusOne[validationId];

        emit ValidationIdRemoved(validationId);
    }

    /// @notice Binds a factory to one exact validation ID. The ID may be
    ///         inactive. Passing zero disables the factory binding.
    function setFactoryValidationId(address factory, bytes32 validationId) external onlyOwner {
        _setFactoryValidationId(factory, validationId);
    }

    /// @notice Replaces the gauge-policy module. Passing zero disables gauge validation.
    function setGaugeValidationModule(address newModule) external onlyOwner {
        address previousModule = gaugeValidationModule;
        if (previousModule == newModule) return;
        if (newModule != address(0)) _requireCode(newModule);

        gaugeValidationModule = newModule;
        emit GaugeValidationModuleSet(previousModule, newModule);
    }

    /// @notice Replaces the proposal analyzer. Passing zero disables analysis.
    function setProposalAnalysisModule(address newModule) external onlyOwner {
        address previousModule = proposalAnalysisModule;
        if (previousModule == newModule) return;
        if (newModule != address(0)) _requireCode(newModule);

        proposalAnalysisModule = newModule;
        emit ProposalAnalysisModuleSet(previousModule, newModule);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();

        address previousOwner = owner;
        if (previousOwner == newOwner) return;

        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    // ---------------------------------------------------------------------
    // Configuration views
    // ---------------------------------------------------------------------

    function validationIdCount() external view returns (uint256) {
        return _validationIds.length;
    }

    function validationIdAt(uint256 index) external view returns (bytes32) {
        return _validationIds[index];
    }

    function isValidationIdActive(bytes32 validationId) external view returns (bool) {
        return _validationIdIndexPlusOne[validationId] != 0;
    }

    // ---------------------------------------------------------------------
    // Validation and proposal analysis
    // ---------------------------------------------------------------------

    /// @notice Returns true only when exactly one active validation ID
    ///         authenticates the gauge through its exactly bound factory.
    function validateGauge(address gauge) external view returns (bool) {
        address module = gaugeValidationModule;
        if (module == address(0)) return false;
        return _gaugeMatchCount(module, gauge) == 1;
    }

    /// @notice Reports recognized gauge additions and their current validity.
    /// @dev Disabled or failing analysis returns a canonical UNAVAILABLE result.
    function analyzeProposalGaugeAdditions(uint256 proposalId)
        external
        view
        returns (IProposalAnalysisModule.ProposalGaugeAnalysis memory result)
    {
        address analyzer = proposalAnalysisModule;
        if (analyzer == address(0)) return _unavailableAnalysis();

        try IProposalAnalysisModule(analyzer).analyzeProposalGaugeAdditions{gas: PROPOSAL_ANALYSIS_CALL_GAS}(
            proposalId, address(this)
        ) returns (
            IProposalAnalysisModule.ProposalGaugeAnalysis memory analysis
        ) {
            return analysis;
        } catch {
            return _unavailableAnalysis();
        }
    }

    /// @dev Returns 0, 1, or 2 for no, unique, or ambiguous matches.
    ///      type(uint256).max represents insufficient gas and fails closed.
    function _gaugeMatchCount(address module, address gauge) private view returns (uint256 matchCount) {
        if (gauge == address(0) || gauge.code.length == 0) return 0;

        uint256 length = _validationIds.length;
        for (uint256 i; i < length; ++i) {
            uint256 remaining = length - i;
            if (gasleft() < remaining * VALIDATION_ID_GAS_RESERVE + FINAL_RESULT_GAS_RESERVE) {
                return type(uint256).max;
            }

            bytes32 validationId = _validationIds[i];
            (bool success, address factory) = _callModule(module, gauge, validationId);
            if (!success || factory == address(0)) continue;
            if (validationIdForFactory[factory] != validationId) continue;

            if (matchCount < 2) ++matchCount;
        }
    }

    function _unavailableAnalysis() private pure returns (IProposalAnalysisModule.ProposalGaugeAnalysis memory result) {
        result.status = IProposalAnalysisModule.AnalysisStatus.UNAVAILABLE;
        result.recognizedGaugeAdditions = new IProposalAnalysisModule.GaugeAdditionAnalysis[](0);
    }

    // ---------------------------------------------------------------------
    // Internal configuration and bounded module calls
    // ---------------------------------------------------------------------

    function _addValidationId(bytes32 validationId) private {
        if (validationId == bytes32(0)) revert ZeroValidationId();
        if (_validationIdIndexPlusOne[validationId] != 0) return;
        if (_validationIds.length == MAX_VALIDATION_IDS) revert ValidationIdLimitReached();

        _validationIds.push(validationId);
        _validationIdIndexPlusOne[validationId] = _validationIds.length;

        emit ValidationIdAdded(validationId);
    }

    function _setFactoryValidationId(address factory, bytes32 validationId) private {
        if (factory == address(0)) revert ZeroAddress();

        bytes32 previousValidationId = validationIdForFactory[factory];
        if (previousValidationId == validationId) return;
        if (validationId != bytes32(0)) _requireCode(factory);

        validationIdForFactory[factory] = validationId;
        emit FactoryValidationIdSet(factory, previousValidationId, validationId);
    }

    function _callModule(address module, address gauge, bytes32 validationId)
        private
        view
        returns (bool success, address factory)
    {
        bytes4 selector = IGaugeValidationModule.factoryForGauge.selector;
        uint256 word;
        uint256 returnSize;

        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, selector)
            mstore(add(pointer, 0x04), and(gauge, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(pointer, 0x24), validationId)
            success := staticcall(MODULE_CALL_GAS, module, pointer, 0x44, pointer, 0x20)
            returnSize := returndatasize()
            word := mload(pointer)
        }

        if (!success || returnSize != 32 || word >> 160 != 0) {
            return (false, address(0));
        }

        // The canonical-address check above proves the narrowing is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        factory = address(uint160(word));
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert MissingCode(target);
    }
}
