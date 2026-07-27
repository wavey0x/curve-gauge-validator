// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IGaugeValidationModule {
    /// @notice Returns the factory that reciprocally authenticates `gauge`
    ///         under `validationId`, or zero when validation fails.
    function factoryForGauge(address gauge, bytes32 validationId) external view returns (address factory);
}
