// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGaugeValidationModule} from "./interfaces/IGaugeValidationModule.sol";
import {ICurve} from "./interfaces/ICurve.sol";

/// @notice Stateless implementation of the four current reciprocal factory proofs.
contract GaugeValidationModuleV1 is IGaugeValidationModule {
    bytes32 public constant DIRECT_LP = "DIRECT_LP";
    bytes32 public constant DIRECT_OR_POOL_LP = "DIRECT_OR_POOL_LP";
    bytes32 public constant VAULT = "VAULT";
    bytes32 public constant FACTORY_IS_VALID_GAUGE = "FACTORY_IS_VALID_GAUGE";

    uint256 public constant DEPENDENCY_CALL_GAS = 30_000;

    function validateGauge(address gauge, address factory, bytes32 validationId) external view returns (bool) {
        if (gauge == address(0) || gauge.code.length == 0 || factory == address(0)) return false;

        if (validationId == DIRECT_LP) return _directLp(gauge, factory);
        if (validationId == DIRECT_OR_POOL_LP) return _directOrPoolLp(gauge, factory);
        if (validationId == VAULT) return _vault(gauge, factory);
        if (validationId == FACTORY_IS_VALID_GAUGE) return _factoryAttestation(gauge, factory);

        return false;
    }

    function _directLp(address gauge, address factory) private view returns (bool) {
        (bool success, address lpToken) = _readAddress(gauge, ICurve.lp_token.selector);
        if (!success || lpToken == address(0)) return false;

        address reverseGauge;
        (success, reverseGauge) = _readAddress(factory, ICurve.get_gauge.selector, lpToken);
        return success && reverseGauge == gauge;
    }

    function _directOrPoolLp(address gauge, address factory) private view returns (bool) {
        (bool success, address lpToken) = _readAddress(gauge, ICurve.lp_token.selector);
        if (!success || lpToken == address(0)) return false;

        address reverseGauge;
        (success, reverseGauge) = _readAddress(factory, ICurve.get_gauge.selector, lpToken);
        if (!success) return false;
        if (reverseGauge != address(0)) return reverseGauge == gauge;

        address pool;
        (success, pool) = _readAddress(lpToken, ICurve.minter.selector);
        if (!success || pool == address(0)) return false;

        (success, reverseGauge) = _readAddress(factory, ICurve.get_gauge.selector, pool);
        return success && reverseGauge == gauge;
    }

    function _vault(address gauge, address factory) private view returns (bool) {
        (bool success, address vault) = _readAddress(gauge, ICurve.lp_token.selector);
        if (!success || vault == address(0)) return false;

        address reverseGauge;
        (success, reverseGauge) = _readAddress(factory, ICurve.gauge_for_vault.selector, vault);
        return success && reverseGauge == gauge;
    }

    function _factoryAttestation(address gauge, address factory) private view returns (bool) {
        (bool success, bool valid) = _readBool(factory, ICurve.is_valid_gauge.selector, gauge);
        return success && valid;
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

        if (!success || returnSize != 32 || word >> 160 != 0) return (false, address(0));

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

        if (!success || returnSize != 32 || word >> 160 != 0) return (false, address(0));

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
