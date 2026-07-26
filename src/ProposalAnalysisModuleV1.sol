// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICurveDAO} from "./interfaces/ICurveDAO.sol";
import {IGaugeValidatorView} from "./interfaces/IGaugeValidatorView.sol";
import {IProposalAnalysisModule} from "./interfaces/IProposalAnalysisModule.sol";

/// @notice Extracts canonical Curve gauge additions from ownership proposals
///         and reports each gauge's validity at the current block.
/// @dev Unrelated actions are ignored. Proposal-created future state is not
///      modeled; it belongs in fork simulation.
contract ProposalAnalysisModuleV1 is IProposalAnalysisModule {
    bytes4 private constant CALLSCRIPT_ID = 0x00000001;
    bytes4 private constant ADD_GAUGE_SELECTOR = 0x18dfe921;
    bytes4 private constant AGENT_EXECUTE_SELECTOR = 0xb61d27f6;

    uint256 private constant CALLSCRIPT_HEADER_LENGTH = 4;
    uint256 private constant CALL_HEADER_LENGTH = 24;
    uint256 private constant ADD_GAUGE_CALLDATA_LENGTH = 100;
    uint256 private constant EXECUTE_PAYLOAD_OFFSET = 96;
    uint256 private constant EXECUTE_PAYLOAD_START = 132;

    uint256 public constant MAX_RECOGNIZED_GAUGE_ADDITIONS = 64;
    uint256 public constant DAO_CALL_GAS = 5_000_000;

    ICurveDAO public immutable DAO;
    address public immutable AGENT;
    address public immutable GAUGE_CONTROLLER;

    struct ParsedGaugeAddition {
        address gauge;
        int128 gaugeType;
        uint256 initialWeight;
    }

    struct ParsedCall {
        bool valid;
        bool isGaugeAddition;
        ParsedGaugeAddition addition;
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

    function analyzeProposalGaugeAdditions(uint256 proposalId, address validator)
        external
        view
        returns (ProposalGaugeAnalysis memory result)
    {
        if (validator == address(0) || validator.code.length == 0) {
            return _unavailableAnalysis();
        }

        bytes memory script;
        try DAO.getVote{gas: DAO_CALL_GAS}(proposalId) returns (
            bool, bool, uint64, uint64, uint64, uint64, uint256, uint256, uint256, bytes memory voteScript
        ) {
            script = voteScript;
        } catch {
            return _unavailableAnalysis();
        }

        return _analyzeCallscript(script, validator);
    }

    function _analyzeCallscript(bytes memory script, address validator)
        private
        view
        returns (ProposalGaugeAnalysis memory result)
    {
        if (script.length < CALLSCRIPT_HEADER_LENGTH || _bytes4At(script, 0) != CALLSCRIPT_ID) {
            return _rejectedAnalysis();
        }

        GaugeAdditionAnalysis[] memory additions = new GaugeAdditionAnalysis[](MAX_RECOGNIZED_GAUGE_ADDITIONS);

        uint256 additionCount;
        uint256 offset = CALLSCRIPT_HEADER_LENGTH;
        bool allCurrentlyValid = true;

        while (offset < script.length) {
            if (script.length - offset < CALL_HEADER_LENGTH) return _rejectedAnalysis();

            address target = _packedAddressAt(script, offset);
            uint256 callDataLength = _uint32At(script, offset + 20);
            uint256 callDataOffset = offset + CALL_HEADER_LENGTH;
            if (callDataLength > script.length - callDataOffset) return _rejectedAnalysis();

            ParsedCall memory parsed = _parseCall(script, target, callDataOffset, callDataLength);
            if (!parsed.valid) return _rejectedAnalysis();

            if (parsed.isGaugeAddition) {
                if (additionCount == MAX_RECOGNIZED_GAUGE_ADDITIONS) {
                    return _rejectedAnalysis();
                }

                bool currentlyValid;
                try IGaugeValidatorView(validator).validateGauge(parsed.addition.gauge) returns (bool valid) {
                    currentlyValid = valid;
                } catch {
                    currentlyValid = false;
                }

                additions[additionCount] = GaugeAdditionAnalysis({
                    gauge: parsed.addition.gauge,
                    gaugeType: parsed.addition.gaugeType,
                    initialWeight: parsed.addition.initialWeight,
                    currentlyValid: currentlyValid
                });

                if (!currentlyValid) allCurrentlyValid = false;
                ++additionCount;
            }

            offset = callDataOffset + callDataLength;
        }

        assembly ("memory-safe") {
            mstore(additions, additionCount)
        }

        result.status = AnalysisStatus.COMPLETE;
        result.allRecognizedGaugeAdditionsCurrentlyValid = additionCount != 0 && allCurrentlyValid;
        result.recognizedGaugeAdditions = additions;
    }

    // ---------------------------------------------------------------------
    // Strict recognized-action parser
    // ---------------------------------------------------------------------

    function _parseCall(bytes memory data, address target, uint256 offset, uint256 length)
        private
        view
        returns (ParsedCall memory parsed)
    {
        bytes4 selector = length >= 4 ? _bytes4At(data, offset) : bytes4(0);

        if (target == GAUGE_CONTROLLER && selector == ADD_GAUGE_SELECTOR) {
            return _parseAddGauge(data, offset, length);
        }

        if (selector == AGENT_EXECUTE_SELECTOR) {
            ParsedCall memory executeCall = _parseAgentExecute(data, offset, length);
            if (target == AGENT) return executeCall;

            if (executeCall.isGaugeAddition || _executePayloadStartsWithAddGauge(data, offset, length)) {
                return parsed;
            }
            return _unrelatedCall();
        }

        if (target == GAUGE_CONTROLLER) return _unrelatedCall();
        if (selector == ADD_GAUGE_SELECTOR) return parsed;
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
        if (innerSelector == AGENT_EXECUTE_SELECTOR) return parsed;

        if (innerSelector == ADD_GAUGE_SELECTOR) {
            if (innerTarget != GAUGE_CONTROLLER || value != 0) return parsed;
            return _parseAddGauge(data, payloadOffset, payloadLength);
        }

        return _unrelatedCall();
    }

    function _executePayloadStartsWithAddGauge(bytes memory data, uint256 offset, uint256 length)
        private
        pure
        returns (bool)
    {
        if (length < EXECUTE_PAYLOAD_START) return false;
        if (_wordAt(data, offset + 68) != EXECUTE_PAYLOAD_OFFSET) return false;

        uint256 payloadLength = _wordAt(data, offset + 100);
        if (payloadLength < 4 || payloadLength > length - EXECUTE_PAYLOAD_START) {
            return false;
        }

        return _bytes4At(data, offset + EXECUTE_PAYLOAD_START) == ADD_GAUGE_SELECTOR;
    }

    function _parseAddGauge(bytes memory data, uint256 offset, uint256 length)
        private
        pure
        returns (ParsedCall memory parsed)
    {
        if (length != ADD_GAUGE_CALLDATA_LENGTH) return parsed;

        (bool addressCanonical, address gauge) = _addressWordAt(data, offset + 4);
        if (!addressCanonical) return parsed;

        (bool intCanonical, int128 gaugeType) = _int128WordAt(data, offset + 36);
        if (!intCanonical) return parsed;

        parsed.valid = true;
        parsed.isGaugeAddition = true;
        parsed.addition =
            ParsedGaugeAddition({gauge: gauge, gaugeType: gaugeType, initialWeight: _wordAt(data, offset + 68)});
    }

    function _unrelatedCall() private pure returns (ParsedCall memory parsed) {
        parsed.valid = true;
    }

    function _unavailableAnalysis() private pure returns (ProposalGaugeAnalysis memory result) {
        result.status = AnalysisStatus.UNAVAILABLE;
        result.recognizedGaugeAdditions = new GaugeAdditionAnalysis[](0);
    }

    function _rejectedAnalysis() private pure returns (ProposalGaugeAnalysis memory result) {
        result.status = AnalysisStatus.CALLSCRIPT_REJECTED;
        result.recognizedGaugeAdditions = new GaugeAdditionAnalysis[](0);
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert MissingCode(target);
    }

    // ---------------------------------------------------------------------
    // Memory readers with caller-established bounds
    // ---------------------------------------------------------------------

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

    function _int128WordAt(bytes memory data, uint256 offset) private pure returns (bool canonical, int128 value) {
        uint256 word = _wordAt(data, offset);
        uint256 upper = word >> 128;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 lower = uint128(word);
        bool negative = lower >> 127 == 1;

        canonical = negative ? upper == type(uint128).max : upper == 0;
        assembly ("memory-safe") {
            value := lower
        }
    }
}
