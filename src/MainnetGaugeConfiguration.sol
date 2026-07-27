// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GaugeValidator} from "./GaugeValidator.sol";

library MainnetGaugeConfiguration {
    address internal constant DAO = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356;
    address internal constant OWNER = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address internal constant GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;
    address internal constant LEND_V2_GAUGE_FACTORY = 0x64e1a69732fAC63F6790b3d8a34C5D713cC623E6;

    bytes32 internal constant DIRECT_LP = "DIRECT_LP";
    bytes32 internal constant DIRECT_OR_POOL_LP = "DIRECT_OR_POOL_LP";
    bytes32 internal constant VAULT = "VAULT";
    bytes32 internal constant FACTORY_IS_VALID_GAUGE = "FACTORY_IS_VALID_GAUGE";

    function bindings(address module) internal pure returns (GaugeValidator.FactoryBinding[] memory values) {
        values = new GaugeValidator.FactoryBinding[](12);

        values[0] = _binding(0x6A8cbed756804B16E05E741eDaBd5cB544AE21bf, module, DIRECT_LP);
        values[1] = _binding(0x4F8846Ae9380B90d2E71D5e3D042dff3E7ebb40d, module, DIRECT_LP);
        values[2] = _binding(0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F, module, DIRECT_OR_POOL_LP);
        values[3] = _binding(0xF18056Bbd320E96A48e3Fbf8bC061322531aac99, module, DIRECT_OR_POOL_LP);
        values[4] = _binding(0xB9fC157394Af804a3578134A6585C0dc9cc990d4, module, DIRECT_OR_POOL_LP);
        values[5] = _binding(0x855cC906dA8271Dd53879929bd226711247D5f17, module, DIRECT_OR_POOL_LP);
        values[6] = _binding(0x0c0e5f2fF0ff18a3be9b835635039256dC4B4963, module, DIRECT_OR_POOL_LP);
        values[7] = _binding(0xeA6876DDE9e3467564acBeE1Ed5bac88783205E0, module, VAULT);
        values[8] = _binding(0xabC000d88f23Bb45525E447528DBF656A9D55bf5, module, FACTORY_IS_VALID_GAUGE);
        values[9] = _binding(0xeF672bD94913CB6f1d2812a6e18c1fFdEd8eFf5c, module, FACTORY_IS_VALID_GAUGE);
        values[10] = _binding(0x306A45a1478A000dC701A6e1f7a569afb8D9DCD6, module, FACTORY_IS_VALID_GAUGE);
        values[11] = _binding(LEND_V2_GAUGE_FACTORY, module, FACTORY_IS_VALID_GAUGE);
    }

    function _binding(address factory, address module, bytes32 validationId)
        private
        pure
        returns (GaugeValidator.FactoryBinding memory)
    {
        return GaugeValidator.FactoryBinding(factory, module, validationId);
    }
}
