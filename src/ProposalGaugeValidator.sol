// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GaugeValidator} from "./GaugeValidator.sol";
import {ICurve} from "./interfaces/ICurve.sol";
import {ICurveDAO} from "./interfaces/ICurveDAO.sol";

/// @notice Extracts canonical gauge additions from one Curve ownership proposal
///         and evaluates them with an immutable GaugeValidator.
contract ProposalGaugeValidator {
    bytes4 private constant CALLSCRIPT_ID = 0x00000001;
    bytes4 private constant ADD_GAUGE_DEFAULT_WEIGHT_SELECTOR = bytes4(keccak256("add_gauge(address,int128)"));

    uint256 private constant CALLSCRIPT_HEADER_LENGTH = 4;
    uint256 private constant CALL_HEADER_LENGTH = 24;
    uint256 private constant ADD_GAUGE_DEFAULT_WEIGHT_CALLDATA_LENGTH = 68;
    uint256 private constant ADD_GAUGE_EXPLICIT_WEIGHT_CALLDATA_LENGTH = 100;
    uint256 private constant EXECUTE_PAYLOAD_OFFSET = 96;
    uint256 private constant EXECUTE_PAYLOAD_START = 132;

    uint256 public constant DAO_CALL_GAS = 5_000_000;
    /// @dev Leaves the core enough headroom to forward its full 2M module budget.
    uint256 public constant GAUGE_VALIDATION_GAS = 2_100_000;

    ICurveDAO public immutable DAO;
    address public immutable AGENT;
    address public immutable GAUGE_CONTROLLER;
    GaugeValidator public immutable GAUGE_VALIDATOR;

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

    /// @notice Returns false when an authenticated gauge addition fails validation,
    ///         uses a nonzero initial weight, or cannot be decoded safely.
    ///         DAO read failures revert.
    function validateProposalGauges(uint256 proposalId) external view returns (bool) {
        (,,,,,,,,, bytes memory script) = DAO.getVote{gas: DAO_CALL_GAS}(proposalId);
        return _validateCallscript(script);
    }

    function _validateCallscript(bytes memory script) private view returns (bool valid) {
        // A truncated callscript cannot execute. An unknown script executor may.
        if (script.length < CALLSCRIPT_HEADER_LENGTH) return true;
        if (_bytes4At(script, 0) != CALLSCRIPT_ID) return false;

        valid = true;
        uint256 offset = CALLSCRIPT_HEADER_LENGTH;

        while (offset < script.length) {
            // Structural failure reverts the entire callscript, including any
            // earlier calls, so it creates no executable gauge risk.
            if (script.length - offset < CALL_HEADER_LENGTH) {
                return true;
            }

            address target = _packedAddressAt(script, offset);
            uint256 callDataLength = _uint32At(script, offset + 20);
            uint256 callDataOffset = offset + CALL_HEADER_LENGTH;
            if (callDataLength > script.length - callDataOffset) {
                return true;
            }

            ParsedCall memory parsed = _parseCall(script, target, callDataOffset, callDataLength);
            if (!parsed.valid || (parsed.isGaugeAddition && !_validateGauge(parsed.gauge))) valid = false;

            offset = callDataOffset + callDataLength;
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
        if (selector == ADD_GAUGE_DEFAULT_WEIGHT_SELECTOR) {
            if (length != ADD_GAUGE_DEFAULT_WEIGHT_CALLDATA_LENGTH) return parsed;
        } else if (
            selector != ICurve.add_gauge.selector || length != ADD_GAUGE_EXPLICIT_WEIGHT_CALLDATA_LENGTH
                || _wordAt(data, offset + 68) != 0
        ) {
            return parsed;
        }

        (bool addressCanonical, address gauge) = _addressWordAt(data, offset + 4);
        if (!addressCanonical || !_int128WordIsCanonical(data, offset + 36)) return parsed;

        parsed.valid = true;
        parsed.isGaugeAddition = true;
        parsed.gauge = gauge;
    }

    function _isAddGaugeSelector(bytes4 selector) private pure returns (bool) {
        return selector == ADD_GAUGE_DEFAULT_WEIGHT_SELECTOR || selector == ICurve.add_gauge.selector;
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
