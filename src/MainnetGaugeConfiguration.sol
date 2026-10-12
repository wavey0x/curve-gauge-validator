// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GaugeValidator} from "./GaugeValidator.sol";

/// @notice Compile-time manifest for mainnet deployment and configuration
///         readback.
/// @dev The internal constants and functions are inlined into deployment
///      scripts, inspection scripts, and tests. This library is not deployed,
///      linked, or consulted during runtime validation. The GaugeValidator
///      constructor copies these initial bindings into its own storage, after
///      which the owner and managers manage them through setFactoryPolicy. Editing this
///      file cannot change an existing deployment.
library MainnetGaugeConfiguration {
    address internal constant DAO = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356;
    address internal constant OWNER = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address internal constant INITIAL_MANAGER = 0xc0DE00005F21Fa7846BA0EA2E3F2FC4F048a72C9; // yrisk.eth
    address internal constant GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;
    address internal constant GAUGE_MODULE = 0x999902533033Cc63c8128C501e307477932B742E;
    address internal constant PROPOSAL_MODULE = 0x999903ff5AC376e8CEc3F9055Ed3a1A7E71f3ab7;
    address internal constant REGULAR_GAUGE_FACTORY = 0x6A8cbed756804B16E05E741eDaBd5cB544AE21bf;
    address internal constant CRVUSD_STABLESWAP_FACTORY = 0x4F8846Ae9380B90d2E71D5e3D042dff3E7ebb40d;
    address internal constant TWOCRYPTO_NG_FACTORY = 0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F;
    address internal constant LEGACY_TWOCRYPTO_FACTORY = 0xF18056Bbd320E96A48e3Fbf8bC061322531aac99;
    address internal constant METAPOOL_FACTORY = 0xB9fC157394Af804a3578134A6585C0dc9cc990d4;
    address internal constant TRICRYPTO_FACTORY = 0x0c0e5f2fF0ff18a3be9b835635039256dC4B4963;
    address internal constant LENDING_GAUGE_FACTORY = 0xeA6876DDE9e3467564acBeE1Ed5bac88783205E0;
    address internal constant BRIDGE_GAUGE_FACTORY = 0xabC000d88f23Bb45525E447528DBF656A9D55bf5;
    address internal constant FRAXTAL_GAUGE_FACTORY = 0xeF672bD94913CB6f1d2812a6e18c1fFdEd8eFf5c;
    address internal constant ROOT_GAUGE_FACTORY = 0x306A45a1478A000dC701A6e1f7a569afb8D9DCD6;
    address internal constant LEND_V2_GAUGE_FACTORY = 0x64e1a69732fAC63F6790b3d8a34C5D713cC623E6;
    address internal constant LM_CALLBACK_FACTORY = 0x2191718CD32d02B8E60BAdFFeA33E4B5DD9A0A0D;

    uint8 internal constant DIRECT_LP = 1;
    uint8 internal constant DIRECT_OR_POOL_LP = 2;
    uint8 internal constant VAULT = 3;
    uint8 internal constant FACTORY_IS_VALID_GAUGE = 4;

    /// @notice Returns the expected initial factory policies for mainnet.
    function bindings(address module) internal pure returns (GaugeValidator.FactoryBinding[] memory values) {
        values = new GaugeValidator.FactoryBinding[](12);

        values[0] = _binding(REGULAR_GAUGE_FACTORY, module, DIRECT_LP);
        values[1] = _binding(CRVUSD_STABLESWAP_FACTORY, module, DIRECT_LP);
        values[2] = _binding(TWOCRYPTO_NG_FACTORY, module, DIRECT_OR_POOL_LP);
        values[3] = _binding(LEGACY_TWOCRYPTO_FACTORY, module, DIRECT_OR_POOL_LP);
        values[4] = _binding(METAPOOL_FACTORY, module, DIRECT_OR_POOL_LP);
        values[5] = _binding(TRICRYPTO_FACTORY, module, DIRECT_OR_POOL_LP);
        values[6] = _binding(LENDING_GAUGE_FACTORY, module, VAULT);
        values[7] = _binding(BRIDGE_GAUGE_FACTORY, module, FACTORY_IS_VALID_GAUGE);
        values[8] = _binding(FRAXTAL_GAUGE_FACTORY, module, FACTORY_IS_VALID_GAUGE);
        values[9] = _binding(ROOT_GAUGE_FACTORY, module, FACTORY_IS_VALID_GAUGE);
        values[10] = _binding(LEND_V2_GAUGE_FACTORY, module, FACTORY_IS_VALID_GAUGE);
        values[11] = _binding(LM_CALLBACK_FACTORY, module, FACTORY_IS_VALID_GAUGE);
    }

    function _binding(address factory, address module, uint8 methodId)
        private
        pure
        returns (GaugeValidator.FactoryBinding memory)
    {
        return GaugeValidator.FactoryBinding(factory, module, methodId);
    }
}
