// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IGaugeValidationModule {
    function factoryForGauge(address gauge, bytes32 validationId) external view returns (address factory);
}
