// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IGaugeValidationModule {
    /// @notice Returns whether `gauge` is reciprocally authenticated by
    ///         `factory` under the module-local `methodId`.
    function validateGauge(address gauge, address factory, uint8 methodId) external view returns (bool);
}
