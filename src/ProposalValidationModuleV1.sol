// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GaugeValidator} from "./GaugeValidator.sol";
import {ICurve} from "./interfaces/ICurve.sol";
import {ICurveDAO} from "./interfaces/ICurveDAO.sol";
import {IProposalValidationModule} from "./interfaces/IProposalValidationModule.sol";

/// @notice Read-only discovery and canonical gauge-addition analysis for Curve
///         ownership proposals.
/// @dev The calling GaugeValidator is used to validate each decoded gauge.
contract ProposalValidationModuleV1 is IProposalValidationModule {
    bytes4 private constant CALLSCRIPT_ID = 0x00000001;
    bytes4 private constant ADD_GAUGE_DEFAULT_WEIGHT_SELECTOR = bytes4(keccak256("add_gauge(address,int128)"));

    uint256 private constant CALLSCRIPT_HEADER_LENGTH = 4;
    uint256 private constant CALL_HEADER_LENGTH = 24;
    uint256 private constant ADD_GAUGE_DEFAULT_WEIGHT_CALLDATA_LENGTH = 68;
    uint256 private constant ADD_GAUGE_EXPLICIT_WEIGHT_CALLDATA_LENGTH = 100;
    uint256 private constant MIN_GAUGE_ADDITION_CALL_LENGTH =
        CALL_HEADER_LENGTH + ADD_GAUGE_DEFAULT_WEIGHT_CALLDATA_LENGTH;
    uint256 private constant EXECUTE_PAYLOAD_OFFSET = 96;
    uint256 private constant EXECUTE_PAYLOAD_START = 132;

    uint256 public constant DAO_CALL_GAS = 5_000_000;
    /// @dev Leaves the core enough headroom to forward its full 2M gauge-module budget.
    uint256 public constant GAUGE_VALIDATION_GAS = 2_100_000;

    ICurveDAO public immutable DAO;
    address public immutable AGENT;
    address public immutable GAUGE_CONTROLLER;

    struct ParsedCall {
        bool wellFormed;
        bool isGaugeAddition;
        bool standard;
        address gauge;
    }

    error ZeroAddress();
    error MissingCode(address target);

    constructor(ICurveDAO dao_, address agent_, address gaugeController_) {
        if (address(dao_) == address(0) || agent_ == address(0) || gaugeController_ == address(0)) {
            revert ZeroAddress();
        }

        _requireCode(address(dao_));
        _requireCode(agent_);
        _requireCode(gaugeController_);

        DAO = dao_;
        AGENT = agent_;
        GAUGE_CONTROLLER = gaugeController_;
    }

    /// @inheritdoc IProposalValidationModule
    function getActiveProposals() external view returns (uint256[] memory proposalIds) {
        uint256 voteCount = DAO.votesLength{gas: DAO_CALL_GAS}();
        if (voteCount == 0) return new uint256[](0);

        uint256 duration = DAO.voteTime{gas: DAO_CALL_GAS}();
        uint256 firstCandidate = voteCount;
        uint256 activeCount;

        // Curve ownership proposal IDs are chronological. Bound discovery to
        // the current voting window without allocating for historical votes.
        while (firstCandidate != 0) {
            (bool open,, uint64 startDate,,,,,,,) = DAO.getVote{gas: DAO_CALL_GAS}(firstCandidate - 1);
            if (uint256(startDate) + duration <= block.timestamp) break;
            if (open) ++activeCount;
            --firstCandidate;
        }

        proposalIds = new uint256[](activeCount);
        uint256 resultIndex;
        for (uint256 proposalId = firstCandidate; proposalId < voteCount; ++proposalId) {
            (bool open,,,,,,,,,) = DAO.getVote{gas: DAO_CALL_GAS}(proposalId);
            if (open) proposalIds[resultIndex++] = proposalId;
        }
    }

    /// @inheritdoc IProposalValidationModule
    function validateProposalGauges(uint256 proposalId) external view returns (bool allValid) {
        (allValid,) = _analyzeProposalGauges(proposalId, msg.sender);
    }

    /// @inheritdoc IProposalValidationModule
    function analyzeProposalGauges(uint256 proposalId)
        external
        view
        returns (bool allValid, GaugeResult[] memory results)
    {
        return _analyzeProposalGauges(proposalId, msg.sender);
    }

    function _analyzeProposalGauges(uint256 proposalId, address validator)
        private
        view
        returns (bool allValid, GaugeResult[] memory results)
    {
        (,,,,,,,,, bytes memory script) = DAO.getVote{gas: DAO_CALL_GAS}(proposalId);
        return _analyzeCallscript(script, validator);
    }

    function _analyzeCallscript(bytes memory script, address validator)
        private
        view
        returns (bool allValid, GaugeResult[] memory results)
    {
        // A truncated callscript cannot execute. An unknown script executor may.
        if (script.length < CALLSCRIPT_HEADER_LENGTH) return (true, new GaugeResult[](0));
        if (_bytes4At(script, 0) != CALLSCRIPT_ID) return (false, new GaugeResult[](0));

        uint256 maximumResults = (script.length - CALLSCRIPT_HEADER_LENGTH) / MIN_GAUGE_ADDITION_CALL_LENGTH;
        results = new GaugeResult[](maximumResults);
        allValid = true;
        uint256 resultCount;
        uint256 offset = CALLSCRIPT_HEADER_LENGTH;

        while (offset < script.length) {
            // Structural failure reverts the entire callscript, including any
            // earlier calls, so it creates no executable gauge risk.
            if (script.length - offset < CALL_HEADER_LENGTH) {
                return (true, new GaugeResult[](0));
            }

            address target = _packedAddressAt(script, offset);
            uint256 callDataLength = _uint32At(script, offset + 20);
            uint256 callDataOffset = offset + CALL_HEADER_LENGTH;
            if (callDataLength > script.length - callDataOffset) {
                return (true, new GaugeResult[](0));
            }

            ParsedCall memory parsed = _parseCall(script, target, callDataOffset, callDataLength);
            if (!parsed.wellFormed) allValid = false;

            if (parsed.isGaugeAddition) {
                bool valid = parsed.standard && _validateGauge(validator, parsed.gauge);
                results[resultCount++] = GaugeResult({gauge: parsed.gauge, valid: valid});
                if (!valid) allValid = false;
            }

            offset = callDataOffset + callDataLength;
        }

        assembly ("memory-safe") {
            mstore(results, resultCount)
        }
    }

    function _parseCall(bytes memory data, address target, uint256 offset, uint256 length)
        private
        view
        returns (ParsedCall memory parsed)
    {
        bytes4 selector = length >= 4 ? _bytes4At(data, offset) : bytes4(0);

        if (target == GAUGE_CONTROLLER && _isAddGaugeSelector(selector)) {
            return _parseAddGauge(data, offset, length, selector);
        }

        if (target == AGENT && selector == ICurve.execute.selector) {
            return _parseAgentExecute(data, offset, length);
        }

        return _unrelatedCall();
    }

    function _parseAgentExecute(bytes memory data, uint256 offset, uint256 length)
        private
        view
        returns (ParsedCall memory parsed)
    {
        if (length < EXECUTE_PAYLOAD_START) return parsed;

        (bool targetCanonical, address innerTarget) = _addressWordAt(data, offset + 4);
        if (!targetCanonical) return parsed;

        uint256 value = _wordAt(data, offset + 36);
        if (_wordAt(data, offset + 68) != EXECUTE_PAYLOAD_OFFSET) return parsed;

        uint256 payloadLength = _wordAt(data, offset + 100);
        uint256 available = length - EXECUTE_PAYLOAD_START;
        if (payloadLength > available) return parsed;

        uint256 paddedLength = (payloadLength + 31) & ~uint256(31);
        if (length != EXECUTE_PAYLOAD_START + paddedLength) return parsed;

        uint256 payloadOffset = offset + EXECUTE_PAYLOAD_START;
        for (uint256 i = payloadLength; i < paddedLength; ++i) {
            if (data[payloadOffset + i] != bytes1(0)) return parsed;
        }

        bytes4 innerSelector = payloadLength >= 4 ? _bytes4At(data, payloadOffset) : bytes4(0);
        if (innerSelector == ICurve.execute.selector) return parsed;

        if (_isAddGaugeSelector(innerSelector)) {
            if (innerTarget != GAUGE_CONTROLLER || value != 0) return _unrelatedCall();
            return _parseAddGauge(data, payloadOffset, payloadLength, innerSelector);
        }

        return _unrelatedCall();
    }

    function _parseAddGauge(bytes memory data, uint256 offset, uint256 length, bytes4 selector)
        private
        pure
        returns (ParsedCall memory parsed)
    {
        bool standard;
        if (selector == ADD_GAUGE_DEFAULT_WEIGHT_SELECTOR) {
            if (length != ADD_GAUGE_DEFAULT_WEIGHT_CALLDATA_LENGTH) return parsed;
            standard = true;
        } else {
            if (selector != ICurve.add_gauge.selector || length != ADD_GAUGE_EXPLICIT_WEIGHT_CALLDATA_LENGTH) {
                return parsed;
            }
            standard = _wordAt(data, offset + 68) == 0;
        }

        (bool addressCanonical, address gauge) = _addressWordAt(data, offset + 4);
        if (!addressCanonical || !_int128WordIsCanonical(data, offset + 36)) return parsed;

        parsed.wellFormed = true;
        parsed.isGaugeAddition = true;
        parsed.standard = standard;
        parsed.gauge = gauge;
    }

    function _isAddGaugeSelector(bytes4 selector) private pure returns (bool) {
        return selector == ADD_GAUGE_DEFAULT_WEIGHT_SELECTOR || selector == ICurve.add_gauge.selector;
    }

    function _validateGauge(address validator, address gauge) private view returns (bool valid) {
        bytes4 selector = GaugeValidator.validateGauge.selector;
        uint256 word;
        uint256 returnSize;
        bool success;

        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, selector)
            mstore(add(pointer, 0x04), and(gauge, 0xffffffffffffffffffffffffffffffffffffffff))
            success := staticcall(GAUGE_VALIDATION_GAS, validator, pointer, 0x24, pointer, 0x20)
            returnSize := returndatasize()
            word := mload(pointer)
        }

        valid = success && returnSize == 32 && word == 1;
    }

    function _unrelatedCall() private pure returns (ParsedCall memory parsed) {
        parsed.wellFormed = true;
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert MissingCode(target);
    }

    function _bytes4At(bytes memory data, uint256 offset) private pure returns (bytes4 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _packedAddressAt(bytes memory data, uint256 offset) private pure returns (address value) {
        assembly ("memory-safe") {
            value := shr(96, mload(add(add(data, 0x20), offset)))
        }
    }

    function _uint32At(bytes memory data, uint256 offset) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := shr(224, mload(add(add(data, 0x20), offset)))
        }
    }

    function _wordAt(bytes memory data, uint256 offset) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _addressWordAt(bytes memory data, uint256 offset) private pure returns (bool canonical, address value) {
        uint256 word = _wordAt(data, offset);
        canonical = word >> 160 == 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        value = address(uint160(word));
    }

    function _int128WordIsCanonical(bytes memory data, uint256 offset) private pure returns (bool) {
        uint256 word = _wordAt(data, offset);
        uint256 upper = word >> 128;
        // forge-lint: disable-next-line(unsafe-typecast)
        bool negative = uint128(word) >> 127 == 1;
        return negative ? upper == type(uint128).max : upper == 0;
    }
}
