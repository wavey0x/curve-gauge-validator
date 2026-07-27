// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IGaugeValidationModule {
    /// @notice Returns whether `gauge` is reciprocally authenticated by
    ///         `factory` under the module-local `validationId`.
    function validateGauge(address gauge, address factory, bytes32 validationId) external view returns (bool);
}
