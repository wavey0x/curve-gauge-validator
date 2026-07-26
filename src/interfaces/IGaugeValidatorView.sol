// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IGaugeValidatorView {
    function validateGauge(address gauge) external view returns (bool);
}
