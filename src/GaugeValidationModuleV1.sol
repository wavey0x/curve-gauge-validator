// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGaugeValidationModule} from "./interfaces/IGaugeValidationModule.sol";

/// @notice Immutable implementation of the four initial Curve gauge
///         validation methods.
contract GaugeValidationModuleV1 is IGaugeValidationModule {
    bytes32 public constant DIRECT_LP = "DIRECT_LP";
    bytes32 public constant DIRECT_OR_POOL_LP = "DIRECT_OR_POOL_LP";
    bytes32 public constant VAULT = "VAULT";
    bytes32 public constant FACTORY_IS_VALID_GAUGE = "FACTORY_IS_VALID_GAUGE";

    uint256 public constant DEPENDENCY_CALL_GAS = 30_000;

    bytes4 private constant FACTORY_SELECTOR = bytes4(keccak256("factory()"));
    bytes4 private constant LP_TOKEN_SELECTOR = bytes4(keccak256("lp_token()"));
    bytes4 private constant GET_GAUGE_SELECTOR = bytes4(keccak256("get_gauge(address)"));
    bytes4 private constant MINTER_TOKEN_SELECTOR = bytes4(keccak256("minter()"));
    bytes4 private constant GAUGE_FOR_VAULT_SELECTOR = bytes4(keccak256("gauge_for_vault(address)"));
    bytes4 private constant IS_VALID_GAUGE_SELECTOR = bytes4(keccak256("is_valid_gauge(address)"));

    function factoryForGauge(address gauge, bytes32 validationId) external view returns (address factory) {
        if (gauge == address(0) || gauge.code.length == 0) return address(0);

        if (validationId == DIRECT_LP) return _directLp(gauge);
        if (validationId == DIRECT_OR_POOL_LP) return _directOrPoolLp(gauge);
        if (validationId == VAULT) return _vault(gauge);
        if (validationId == FACTORY_IS_VALID_GAUGE) return _factoryIsValidGauge(gauge);

        return address(0);
    }

    function _directLp(address gauge) private view returns (address factory) {
        (bool success, address candidateFactory) = _readAddress(gauge, FACTORY_SELECTOR);
        if (!success || candidateFactory == address(0)) return address(0);

        address lpToken;
        (success, lpToken) = _readAddress(gauge, LP_TOKEN_SELECTOR);
        if (!success || lpToken == address(0)) return address(0);

        address reverseGauge;
        (success, reverseGauge) = _readAddress(candidateFactory, GET_GAUGE_SELECTOR, lpToken);
        if (!success || reverseGauge != gauge) return address(0);

        return candidateFactory;
    }

    function _directOrPoolLp(address gauge) private view returns (address factory) {
        (bool success, address candidateFactory) = _readAddress(gauge, FACTORY_SELECTOR);
        if (!success || candidateFactory == address(0)) return address(0);

        address lpToken;
        (success, lpToken) = _readAddress(gauge, LP_TOKEN_SELECTOR);
        if (!success || lpToken == address(0)) return address(0);

        address reverseGauge;
        (success, reverseGauge) = _readAddress(candidateFactory, GET_GAUGE_SELECTOR, lpToken);
        if (success && reverseGauge == gauge) return candidateFactory;

        address pool;
        (success, pool) = _readAddress(lpToken, MINTER_TOKEN_SELECTOR);
        if (!success || pool == address(0)) return address(0);

        (success, reverseGauge) = _readAddress(candidateFactory, GET_GAUGE_SELECTOR, pool);
        if (!success || reverseGauge != gauge) return address(0);

        return candidateFactory;
    }

    function _vault(address gauge) private view returns (address factory) {
        (bool success, address candidateFactory) = _readAddress(gauge, FACTORY_SELECTOR);
        if (!success || candidateFactory == address(0)) return address(0);

        address vault;
        (success, vault) = _readAddress(gauge, LP_TOKEN_SELECTOR);
        if (!success || vault == address(0)) return address(0);

        address reverseGauge;
        (success, reverseGauge) = _readAddress(candidateFactory, GAUGE_FOR_VAULT_SELECTOR, vault);
        if (!success || reverseGauge != gauge) return address(0);

        return candidateFactory;
    }

    function _factoryIsValidGauge(address gauge) private view returns (address factory) {
        (bool success, address candidateFactory) = _readAddress(gauge, FACTORY_SELECTOR);
        if (!success || candidateFactory == address(0)) return address(0);

        bool valid;
        (success, valid) = _readBool(candidateFactory, IS_VALID_GAUGE_SELECTOR, gauge);
        if (!success || !valid) return address(0);

        return candidateFactory;
    }

    function _readAddress(address target, bytes4 selector) private view returns (bool success, address value) {
        uint256 word;
        uint256 returnSize;

        assembly ("memory-safe") {
            mstore(0x00, selector)
            success := staticcall(DEPENDENCY_CALL_GAS, target, 0x00, 0x04, 0x00, 0x20)
            returnSize := returndatasize()
            word := mload(0x00)
        }

        if (!success || returnSize != 32 || word >> 160 != 0) {
            return (false, address(0));
        }
        // The canonical-address check above proves the narrowing is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        value = address(uint160(word));
    }

    function _readAddress(address target, bytes4 selector, address argument)
        private
        view
        returns (bool success, address value)
    {
        uint256 word;
        uint256 returnSize;

        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x04, and(argument, 0xffffffffffffffffffffffffffffffffffffffff))
            success := staticcall(DEPENDENCY_CALL_GAS, target, 0x00, 0x24, 0x00, 0x20)
            returnSize := returndatasize()
            word := mload(0x00)
        }

        if (!success || returnSize != 32 || word >> 160 != 0) {
            return (false, address(0));
        }
        // The canonical-address check above proves the narrowing is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        value = address(uint160(word));
    }

    function _readBool(address target, bytes4 selector, address argument)
        private
        view
        returns (bool success, bool value)
    {
        uint256 word;
        uint256 returnSize;

        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x04, and(argument, 0xffffffffffffffffffffffffffffffffffffffff))
            success := staticcall(DEPENDENCY_CALL_GAS, target, 0x00, 0x24, 0x00, 0x20)
            returnSize := returndatasize()
            word := mload(0x00)
        }

        if (!success || returnSize != 32 || word > 1) return (false, false);
        value = word == 1;
    }
}
