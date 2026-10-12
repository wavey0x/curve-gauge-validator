// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";

/// @notice Reads live configuration for an explicit comma-separated FACTORIES list.
/// @dev This list should come from all FactoryPolicySet events, not just constructor defaults.
contract InspectGaugeValidator is Script {
    error MissingCode(address target);
    error InvalidPolicy(address factory);

    function run() external view {
        address validatorAddress = vm.envAddress("VALIDATOR");
        _requireCode(validatorAddress);
        GaugeValidator validator = GaugeValidator(validatorAddress);
        address proposalModule = validator.proposalModule();
        if (proposalModule != address(0)) _requireCode(proposalModule);

        console2.log("validator", validatorAddress);
        console2.log("owner", validator.owner());
        console2.log("proposal module", proposalModule);
        address[] memory factories = vm.envAddress("FACTORIES", ",");
        for (uint256 i; i < factories.length; ++i) {
            address factory = factories[i];
            (address module, uint8 methodId) = validator.policyForFactory(factory);
            if (factory == address(0) || (module == address(0)) != (methodId == 0)) revert InvalidPolicy(factory);
            if (module != address(0)) {
                _requireCode(factory);
                _requireCode(module);
            }
            console2.log("factory", factory);
            console2.log("module", module);
            console2.log("method ID", methodId);
        }
        address manager = vm.envOr("MANAGER", address(0));
        if (manager != address(0)) {
            console2.log("manager", manager);
            console2.log("enabled", validator.managers(manager));
        }
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert MissingCode(target);
    }
}
