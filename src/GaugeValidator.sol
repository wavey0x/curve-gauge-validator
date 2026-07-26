// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICurve} from "./interfaces/ICurve.sol";

/// @notice Pessimistically answers whether a gauge was deployed by a trusted factory.
contract GaugeValidator {
    uint256 public constant DEPENDENCY_CALL_GAS = 30_000;

    enum Proof {
        NONE,
        DIRECT_LP,
        DIRECT_OR_POOL_LP,
        VAULT,
        FACTORY_IS_VALID_GAUGE
    }

    struct FactoryBinding {
        address factory;
        Proof proof;
    }

    address public owner;

    /// @notice The reciprocal proof for a trusted factory. NONE means untrusted.
    mapping(address factory => Proof proof) public proofForFactory;

    event FactoryTrustSet(address indexed factory, Proof previousProof, Proof newProof);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner(address caller);
    error ZeroAddress();
    error MissingCode(address target);

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function _checkOwner() private view {
        if (msg.sender != owner) revert NotOwner(msg.sender);
    }

    constructor(address owner_, FactoryBinding[] memory initialBindings) {
        if (owner_ == address(0)) revert ZeroAddress();

        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);

        for (uint256 i; i < initialBindings.length; ++i) {
            FactoryBinding memory binding = initialBindings[i];
            _setFactoryTrust(binding.factory, binding.proof);
        }
    }

    /// @notice Sets the reciprocal proof for a factory. NONE removes trust.
    function setFactoryTrust(address factory, Proof proof) external onlyOwner {
        _setFactoryTrust(factory, proof);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();

        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @notice Returns true only when a configured factory reciprocally authenticates the gauge.
    function validateGauge(address gauge) external view returns (bool) {
        if (gauge == address(0) || gauge.code.length == 0) return false;

        (bool success, address factory) = _readAddress(gauge, ICurve.factory.selector);
        if (!success || factory == address(0)) return false;

        Proof proof = proofForFactory[factory];
        if (proof == Proof.NONE) return false;
        if (proof == Proof.DIRECT_LP) return _directLp(gauge, factory);
        if (proof == Proof.DIRECT_OR_POOL_LP) return _directOrPoolLp(gauge, factory);
        if (proof == Proof.VAULT) return _vault(gauge, factory);
        if (proof == Proof.FACTORY_IS_VALID_GAUGE) return _factoryAttestation(gauge, factory);

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

    function _setFactoryTrust(address factory, Proof proof) private {
        if (factory == address(0)) revert ZeroAddress();
        if (proof != Proof.NONE && factory.code.length == 0) revert MissingCode(factory);

        Proof previousProof = proofForFactory[factory];
        proofForFactory[factory] = proof;
        emit FactoryTrustSet(factory, previousProof, proof);
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
