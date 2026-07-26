// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GaugeValidator} from "../src/GaugeValidator.sol";
import {GaugeValidationModuleV1} from "../src/GaugeValidationModuleV1.sol";
import {MainnetGaugeConfiguration} from "../src/MainnetGaugeConfiguration.sol";
import {ProposalAnalysisModuleV1} from "../src/ProposalAnalysisModuleV1.sol";
import {ICurveDAO} from "../src/interfaces/ICurveDAO.sol";
import {IProposalAnalysisModule} from "../src/interfaces/IProposalAnalysisModule.sol";

interface IFactoryAttestedGauge {
    function factory() external view returns (address);
    // Matches the deployed Vyper ABI.
    // forge-lint: disable-next-line(mixed-case-function)
    function lp_token() external view returns (address);
}

interface IFactoryGaugeRegistry {
    function owner() external view returns (address);
    // Matches the deployed Vyper ABI.
    // forge-lint: disable-next-line(mixed-case-function)
    function is_valid_gauge(address gauge) external view returns (bool);
}

interface ILendVaultV2 {
    function factory() external view returns (address);
}

contract MainnetGaugeValidationTest is Test {
    uint256 private constant CHAIN_ID = 1;
    uint256 private constant FORK_BLOCK = 25_619_622;
    uint256 private constant FORK_TIMESTAMP = 1_785_100_847;

    address private constant LEND_FACTORY = 0x8f6B56EC5ddF1F2691a1059f1D3cd97Ac9EaB0bd;
    address private constant LEND_V2_GAUGE_FACTORY = 0x64e1a69732fAC63F6790b3d8a34C5D713cC623E6;
    address private constant LEND_V2_VAULT_GAUGE = 0xbe0451815b546F705ef3f398B8179aE3AADDA14e;
    uint256 private constant AGENT_WRAPPED_PROPOSAL = 1406;
    uint256 private constant LEND_V2_ACTIVATION_PROPOSAL = 1461;
    address private constant PROPOSAL_1406_GAUGE = 0xA41eb3062FD68B6Fa9f11439C86503913806761D;
    address private constant LEGACY_EOA_DEPLOYED_GAUGE = 0x055be5DDB7A925BfEF3417FC157f53CA77cA7222;

    GaugeValidationModuleV1 private module;
    ProposalAnalysisModuleV1 private analyzer;
    GaugeValidator private validator;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL", string("http://wavey:8545")), FORK_BLOCK);

        module = new GaugeValidationModuleV1();
        analyzer = new ProposalAnalysisModuleV1(
            ICurveDAO(MainnetGaugeConfiguration.DAO),
            MainnetGaugeConfiguration.OWNER,
            MainnetGaugeConfiguration.GAUGE_CONTROLLER
        );
        validator = new GaugeValidator(
            MainnetGaugeConfiguration.OWNER,
            address(analyzer),
            MainnetGaugeConfiguration.routes(address(module)),
            MainnetGaugeConfiguration.bindings(address(module))
        );
    }

    function test_PinnedForkMetadata() public view {
        assertEq(block.chainid, CHAIN_ID);
        assertEq(block.number, FORK_BLOCK);
        assertEq(block.timestamp, FORK_TIMESTAMP);
    }

    function test_InitialRoutesAndAllFactoryBindings() public view {
        assertEq(validator.owner(), MainnetGaugeConfiguration.OWNER);
        assertEq(validator.proposalAnalysisModule(), address(analyzer));
        assertEq(validator.routeCount(), 4);

        GaugeValidator.FactoryBinding[] memory bindings = MainnetGaugeConfiguration.bindings(address(module));
        assertEq(bindings.length, 12);

        for (uint256 i; i < bindings.length; ++i) {
            bytes32 expectedKey = keccak256(abi.encode(bindings[i].module, bindings[i].validationId));
            assertGt(bindings[i].factory.code.length, 0);
            assertEq(validator.routeForFactory(bindings[i].factory), expectedKey);
        }

        assertEq(_factoryCount(module.DIRECT_LP()), 2);
        assertEq(_factoryCount(module.DIRECT_OR_POOL_LP()), 5);
        assertEq(_factoryCount(module.VAULT()), 1);
        assertEq(_factoryCount(module.FACTORY_IS_VALID_GAUGE()), 4);
    }

    function test_RepresentativeLiveFactoryGauges() public view {
        _assertGauge(
            0x004b865973CAbce8691CD0b9f5910246203a9eb4, 0x6A8cbed756804B16E05E741eDaBd5cB544AE21bf, module.DIRECT_LP()
        );
        _assertGauge(
            0x0e5bdb5afe132D1c6A6C67f6D8eB6133dD607e36, 0x4F8846Ae9380B90d2E71D5e3D042dff3E7ebb40d, module.DIRECT_LP()
        );
        _assertGauge(
            0x016831ace15582D81b50927D2755a4487aCf8082,
            0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F,
            module.DIRECT_OR_POOL_LP()
        );
        _assertGauge(
            0x009aCD89535DAbC270C93F9b39D3232105Fef453,
            0xF18056Bbd320E96A48e3Fbf8bC061322531aac99,
            module.DIRECT_OR_POOL_LP()
        );
        _assertGauge(
            0x0060E266c2AF65bfc4fd51b04c93d952DF805630,
            0xB9fC157394Af804a3578134A6585C0dc9cc990d4,
            module.DIRECT_OR_POOL_LP()
        );
        _assertGauge(
            0x1E4B83f6bFE9dbeB6d5b92a5237E5c18a44176f4,
            0x0c0e5f2fF0ff18a3be9b835635039256dC4B4963,
            module.DIRECT_OR_POOL_LP()
        );
        _assertGauge(
            0x0621982CdA4fD4041964e91AF4080583C5F099e1, 0xeA6876DDE9e3467564acBeE1Ed5bac88783205E0, module.VAULT()
        );
        _assertGauge(
            0x00F7d467ef51E44f11f52a0c0Bef2E56C271b264,
            0xabC000d88f23Bb45525E447528DBF656A9D55bf5,
            module.FACTORY_IS_VALID_GAUGE()
        );
        _assertGauge(
            0x070EBC9F46d0a6A523D31eb4aE7901C56AD97ae2,
            0xeF672bD94913CB6f1d2812a6e18c1fFdEd8eFf5c,
            module.FACTORY_IS_VALID_GAUGE()
        );
        _assertGauge(
            0x077999E08cbb3990b05d23F6ED7890D34b337771,
            0x306A45a1478A000dC701A6e1f7a569afb8D9DCD6,
            module.FACTORY_IS_VALID_GAUGE()
        );
        _assertGauge(LEND_V2_VAULT_GAUGE, LEND_V2_GAUGE_FACTORY, module.FACTORY_IS_VALID_GAUGE());
    }

    function test_LegacyEoaDeployedGaugeIsExplicitlyOutOfScope() public view {
        assertGt(LEGACY_EOA_DEPLOYED_GAUGE.code.length, 0);
        assertFalse(validator.validateGauge(LEGACY_EOA_DEPLOYED_GAUGE));
    }

    function test_Proposal1406ParsesAuthenticatedAgentWrapper() public view {
        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            validator.analyzeProposalGaugeAdditions(AGENT_WRAPPED_PROPOSAL);

        assertEq(uint256(result.status), uint256(IProposalAnalysisModule.AnalysisStatus.COMPLETE));
        assertTrue(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 1);
        assertEq(result.recognizedGaugeAdditions[0].gauge, PROPOSAL_1406_GAUGE);
        assertTrue(result.recognizedGaugeAdditions[0].currentlyValid);
    }

    function test_Proposal1461RecognizesFactoryAttestedLendV2VaultGauge() public view {
        IProposalAnalysisModule.ProposalGaugeAnalysis memory result =
            validator.analyzeProposalGaugeAdditions(LEND_V2_ACTIVATION_PROPOSAL);

        assertEq(uint256(result.status), uint256(IProposalAnalysisModule.AnalysisStatus.COMPLETE));
        assertTrue(result.allRecognizedGaugeAdditionsCurrentlyValid);
        assertEq(result.recognizedGaugeAdditions.length, 1);
        assertEq(result.recognizedGaugeAdditions[0].gauge, LEND_V2_VAULT_GAUGE);
        assertEq(result.recognizedGaugeAdditions[0].gaugeType, 0);
        assertEq(result.recognizedGaugeAdditions[0].initialWeight, 0);
        assertTrue(result.recognizedGaugeAdditions[0].currentlyValid);
    }

    function test_LendV2VaultGaugeUsesGovernanceOwnedFactoryAttestation() public view {
        IFactoryAttestedGauge gauge = IFactoryAttestedGauge(LEND_V2_VAULT_GAUGE);
        IFactoryGaugeRegistry factory = IFactoryGaugeRegistry(LEND_V2_GAUGE_FACTORY);

        assertEq(gauge.factory(), LEND_V2_GAUGE_FACTORY);
        assertTrue(factory.is_valid_gauge(LEND_V2_VAULT_GAUGE));
        assertEq(factory.owner(), MainnetGaugeConfiguration.OWNER);
        assertEq(ILendVaultV2(gauge.lp_token()).factory(), LEND_FACTORY);
        assertEq(validator.routeForFactory(LEND_FACTORY), bytes32(0));
    }

    function test_ValidationGasHeadroomForEveryLiveMethod() public view {
        _assertValidationGas(0x004b865973CAbce8691CD0b9f5910246203a9eb4, 300_000);
        _assertValidationGas(0x02C26E2013D7476E69aD3B453F025A43116B448D, 300_000);
        _assertValidationGas(0x0621982CdA4fD4041964e91AF4080583C5F099e1, 300_000);
        _assertValidationGas(0x02b8e750E68cb648dB2c2ac4BBb47A10A5c12588, 300_000);
        _assertValidationGas(LEND_V2_VAULT_GAUGE, 300_000);
    }

    function _assertGauge(address gauge, address factory, bytes32 validationId) private view {
        assertTrue(validator.validateGauge(gauge));
        assertEq(module.factoryForGauge(gauge, validationId), factory);
        assertEq(validator.routeForFactory(factory), keccak256(abi.encode(address(module), validationId)));
    }

    function _assertValidationGas(address gauge, uint256 maximum) private view {
        uint256 gasBefore = gasleft();
        bool valid = validator.validateGauge(gauge);
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(valid);
        assertLt(gasUsed, maximum);
    }

    function _factoryCount(bytes32 validationId) private view returns (uint256) {
        return validator.routeFactoryCount(keccak256(abi.encode(address(module), validationId)));
    }
}
