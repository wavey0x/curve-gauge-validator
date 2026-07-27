// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GaugeValidator} from "./GaugeValidator.sol";
import {ICurve} from "./interfaces/ICurve.sol";
import {ICurveDAO} from "./interfaces/ICurveDAO.sol";

/// @notice Extracts canonical gauge additions from one Curve ownership proposal
///         and evaluates them with an immutable GaugeValidator.
contract ProposalGaugeValidator {
    bytes4 private constant CALLSCRIPT_ID = 0x00000001;

    uint256 private constant CALLSCRIPT_HEADER_LENGTH = 4;
    uint256 private constant CALL_HEADER_LENGTH = 24;
    uint256 private constant ADD_GAUGE_CALLDATA_LENGTH = 100;
    uint256 private constant EXECUTE_PAYLOAD_OFFSET = 96;
    uint256 private constant EXECUTE_PAYLOAD_START = 132;

    uint256 public constant MAX_GAUGES = 64;
    uint256 public constant DAO_CALL_GAS = 5_000_000;
    /// @dev Leaves the core enough headroom to forward its full 2M module budget.
    uint256 public constant GAUGE_VALIDATION_GAS = 2_100_000;

    ICurveDAO public immutable DAO;
    address public immutable AGENT;
    address public immutable GAUGE_CONTROLLER;
    GaugeValidator public immutable GAUGE_VALIDATOR;

    enum AnalysisStatus {
        UNAVAILABLE,
        CALLSCRIPT_REJECTED,
        COMPLETE
    }

    struct GaugeResult {
        address gauge;
        bool valid;
    }

    struct ProposalAnalysis {
        AnalysisStatus status;
        bool allValid;
        GaugeResult[] gauges;
    }

    struct ParsedCall {
        bool valid;
        bool isGaugeAddition;
        address gauge;
    }

    error ZeroAddress();
    error MissingCode(address target);

    constructor(ICurveDAO dao_, address agent_, address gaugeController_, GaugeValidator gaugeValidator_) {
        if (
            address(dao_) == address(0) || agent_ == address(0) || gaugeController_ == address(0)
                || address(gaugeValidator_) == address(0)
        ) revert ZeroAddress();

        _requireCode(address(dao_));
        _requireCode(agent_);
        _requireCode(gaugeController_);
        _requireCode(address(gaugeValidator_));

        DAO = dao_;
        AGENT = agent_;
        GAUGE_CONTROLLER = gaugeController_;
        GAUGE_VALIDATOR = gaugeValidator_;
    }

    /// @notice Returns parser status and one current-state boolean per gauge addition.
    function analyzeProposalGaugeAdditions(uint256 proposalId) public view returns (ProposalAnalysis memory result) {
        bytes memory script;
        try DAO.getVote{gas: DAO_CALL_GAS}(proposalId) returns (
            bool, bool, uint64, uint64, uint64, uint64, uint256, uint256, uint256, bytes memory voteScript
        ) {
            script = voteScript;
        } catch {
            return _emptyAnalysis(AnalysisStatus.UNAVAILABLE);
        }

        return _analyzeCallscript(script);
    }

    /// @notice Returns true only when analysis completes, recognizes at least one
    ///         gauge addition, and every recognized gauge currently validates.
    function allRecognizedGaugeAdditionsCurrentlyValid(uint256 proposalId) external view returns (bool) {
        ProposalAnalysis memory result = analyzeProposalGaugeAdditions(proposalId);
        return result.status == AnalysisStatus.COMPLETE && result.allValid;
    }

    function _analyzeCallscript(bytes memory script) private view returns (ProposalAnalysis memory result) {
        if (script.length < CALLSCRIPT_HEADER_LENGTH || _bytes4At(script, 0) != CALLSCRIPT_ID) {
            return _emptyAnalysis(AnalysisStatus.CALLSCRIPT_REJECTED);
        }

        GaugeResult[] memory gauges = new GaugeResult[](MAX_GAUGES);
        uint256 gaugeCount;
        uint256 offset = CALLSCRIPT_HEADER_LENGTH;
        bool allValid = true;

        while (offset < script.length) {
            if (script.length - offset < CALL_HEADER_LENGTH) {
                return _emptyAnalysis(AnalysisStatus.CALLSCRIPT_REJECTED);
            }

            address target = _packedAddressAt(script, offset);
            uint256 callDataLength = _uint32At(script, offset + 20);
            uint256 callDataOffset = offset + CALL_HEADER_LENGTH;
            if (callDataLength > script.length - callDataOffset) {
                return _emptyAnalysis(AnalysisStatus.CALLSCRIPT_REJECTED);
            }

            ParsedCall memory parsed = _parseCall(script, target, callDataOffset, callDataLength);
            if (!parsed.valid) return _emptyAnalysis(AnalysisStatus.CALLSCRIPT_REJECTED);

            if (parsed.isGaugeAddition) {
                if (gaugeCount == MAX_GAUGES) {
                    return _emptyAnalysis(AnalysisStatus.CALLSCRIPT_REJECTED);
                }

                bool valid = _validateGauge(parsed.gauge);
                gauges[gaugeCount] = GaugeResult({gauge: parsed.gauge, valid: valid});
                if (!valid) allValid = false;
                ++gaugeCount;
            }

            offset = callDataOffset + callDataLength;
        }

        assembly ("memory-safe") {
            mstore(gauges, gaugeCount)
        }

        result.status = AnalysisStatus.COMPLETE;
        result.allValid = gaugeCount != 0 && allValid;
        result.gauges = gauges;
    }

    function _parseCall(bytes memory data, address target, uint256 offset, uint256 length)
        private
        view
        returns (ParsedCall memory parsed)
    {
        bytes4 selector = length >= 4 ? _bytes4At(data, offset) : bytes4(0);

        if (target == GAUGE_CONTROLLER && selector == ICurve.add_gauge.selector) {
            return _parseAddGauge(data, offset, length);
        }

        if (selector == ICurve.execute.selector) {
            ParsedCall memory executeCall = _parseAgentExecute(data, offset, length);
            if (target == AGENT) return executeCall;

            if (executeCall.isGaugeAddition || _executePayloadStartsWithAddGauge(data, offset, length)) {
                return parsed;
            }
            return _unrelatedCall();
        }

        if (selector == ICurve.add_gauge.selector) return parsed;
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

        if (innerSelector == ICurve.add_gauge.selector) {
            if (innerTarget != GAUGE_CONTROLLER || value != 0) return parsed;
            return _parseAddGauge(data, payloadOffset, payloadLength);
        }

        return _unrelatedCall();
    }

    function _parseAddGauge(bytes memory data, uint256 offset, uint256 length)
        private
        pure
        returns (ParsedCall memory parsed)
    {
        if (length != ADD_GAUGE_CALLDATA_LENGTH) return parsed;

        (bool addressCanonical, address gauge) = _addressWordAt(data, offset + 4);
        if (!addressCanonical || !_int128WordIsCanonical(data, offset + 36)) return parsed;

        parsed.valid = true;
        parsed.isGaugeAddition = true;
        parsed.gauge = gauge;
    }

    function _executePayloadStartsWithAddGauge(bytes memory data, uint256 offset, uint256 length)
        private
        pure
        returns (bool)
    {
        if (length < EXECUTE_PAYLOAD_START) return false;
        if (_wordAt(data, offset + 68) != EXECUTE_PAYLOAD_OFFSET) return false;

        uint256 payloadLength = _wordAt(data, offset + 100);
        if (payloadLength < 4 || payloadLength > length - EXECUTE_PAYLOAD_START) return false;

        return _bytes4At(data, offset + EXECUTE_PAYLOAD_START) == ICurve.add_gauge.selector;
    }

    function _validateGauge(address gauge) private view returns (bool valid) {
        bytes4 selector = GaugeValidator.validateGauge.selector;
        uint256 word;
        uint256 returnSize;
        bool success;
        address validator = address(GAUGE_VALIDATOR);

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
        parsed.valid = true;
    }

    function _emptyAnalysis(AnalysisStatus status) private pure returns (ProposalAnalysis memory result) {
        result.status = status;
        result.gauges = new GaugeResult[](0);
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
