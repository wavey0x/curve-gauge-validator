// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGaugeValidationModule} from "../../src/interfaces/IGaugeValidationModule.sol";
import {IProposalAnalysisModule} from "../../src/interfaces/IProposalAnalysisModule.sol";

contract MockTarget {}

contract MockDAO {
    struct Vote {
        bytes script;
    }

    Vote[] private _votes;

    function pushVote(bytes memory script) external returns (uint256 voteId) {
        voteId = _votes.length;
        _votes.push(Vote({script: script}));
    }

    function getVote(uint256 voteId)
        external
        view
        returns (bool, bool, uint64, uint64, uint64, uint64, uint256, uint256, uint256, bytes memory script)
    {
        script = _votes[voteId].script;
        return (false, false, 0, 0, 0, 0, 0, 0, 0, script);
    }
}

contract MockGauge {}

contract MockValidationModule is IGaugeValidationModule {
    enum Mode {
        NORMAL,
        REVERT,
        BURN_GAS,
        SHORT_RETURN,
        LONG_RETURN,
        NONCANONICAL_ADDRESS,
        RETURN_DATA_BOMB
    }

    mapping(bytes32 validationId => mapping(address gauge => address factory)) public factories;
    mapping(bytes32 validationId => Mode mode) public validationIdModes;
    mapping(bytes32 validationId => bool configured) public hasValidationIdMode;
    Mode public mode;

    function setFactory(address gauge, bytes32 validationId, address factory) external {
        factories[validationId][gauge] = factory;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setValidationIdMode(bytes32 validationId, Mode mode_) external {
        validationIdModes[validationId] = mode_;
        hasValidationIdMode[validationId] = true;
    }

    function factoryForGauge(address gauge, bytes32 validationId) external view returns (address factory) {
        Mode currentMode = hasValidationIdMode[validationId] ? validationIdModes[validationId] : mode;
        if (currentMode == Mode.REVERT) revert();
        if (currentMode == Mode.BURN_GAS) {
            assembly {
                for {} 1 {} {}
            }
        }

        factory = factories[validationId][gauge];
        if (currentMode == Mode.SHORT_RETURN) {
            assembly ("memory-safe") {
                mstore(0x00, factory)
                return(0x00, 0x1f)
            }
        }
        if (currentMode == Mode.LONG_RETURN) {
            assembly ("memory-safe") {
                mstore(0x00, factory)
                mstore(0x20, 0)
                return(0x00, 0x40)
            }
        }
        if (currentMode == Mode.NONCANONICAL_ADDRESS) {
            assembly ("memory-safe") {
                mstore(0x00, or(factory, shl(160, 1)))
                return(0x00, 0x20)
            }
        }
        if (currentMode == Mode.RETURN_DATA_BOMB) {
            assembly ("memory-safe") {
                mstore(0x00, factory)
                return(0x00, 0x100000)
            }
        }
    }
}

contract MockProposalAnalysisModule is IProposalAnalysisModule {
    enum Mode {
        NORMAL,
        REVERT,
        BURN_GAS
    }

    Mode public mode;
    AnalysisStatus public status;
    bool public allRecognizedGaugeAdditionsCurrentlyValid;
    bool public includeAddition;
    GaugeAdditionAnalysis private _addition;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setResult(
        AnalysisStatus status_,
        bool allRecognizedGaugeAdditionsCurrentlyValid_,
        bool includeAddition_,
        GaugeAdditionAnalysis memory addition_
    ) external {
        status = status_;
        allRecognizedGaugeAdditionsCurrentlyValid = allRecognizedGaugeAdditionsCurrentlyValid_;
        includeAddition = includeAddition_;
        _addition = addition_;
    }

    function analyzeProposalGaugeAdditions(uint256, address)
        external
        view
        returns (ProposalGaugeAnalysis memory result)
    {
        Mode currentMode = mode;
        if (currentMode == Mode.REVERT) revert();
        if (currentMode == Mode.BURN_GAS) {
            assembly {
                for {} 1 {} {}
            }
        }

        result.status = status;
        result.allRecognizedGaugeAdditionsCurrentlyValid = allRecognizedGaugeAdditionsCurrentlyValid;
        result.recognizedGaugeAdditions = new GaugeAdditionAnalysis[](includeAddition ? 1 : 0);
        if (includeAddition) result.recognizedGaugeAdditions[0] = _addition;
    }
}

contract MockProtocolGauge {
    address public factory;
    // Protocol-compatible Vyper getter.
    // forge-lint: disable-next-line(mixed-case-variable)
    address public lp_token;

    constructor(address factory_, address lpToken_) {
        factory = factory_;
        lp_token = lpToken_;
    }

    function setFactory(address factory_) external {
        factory = factory_;
    }

    function setLpToken(address lpToken_) external {
        lp_token = lpToken_;
    }
}

contract MockPoolToken {
    address public minter;

    constructor(address minter_) {
        minter = minter_;
    }
}

contract MockCurveFactory {
    // Protocol-compatible Vyper getters.
    // forge-lint: disable-next-line(mixed-case-variable)
    mapping(address => address) public get_gauge;
    // forge-lint: disable-next-line(mixed-case-variable)
    mapping(address => address) public gauge_for_vault;
    // forge-lint: disable-next-line(mixed-case-variable)
    mapping(address => bool) public is_valid_gauge;

    function setGauge(address tokenOrPool, address gauge) external {
        get_gauge[tokenOrPool] = gauge;
    }

    function setVaultGauge(address vault, address gauge) external {
        gauge_for_vault[vault] = gauge;
    }

    function setValidGauge(address gauge, bool valid) external {
        is_valid_gauge[gauge] = valid;
    }
}

contract NoncanonicalFactoryGauge {
    // Protocol-compatible Vyper getter.
    // forge-lint: disable-next-line(mixed-case-variable)
    address public lp_token;

    constructor(address lpToken_) {
        lp_token = lpToken_;
    }

    function factory() external pure returns (address) {
        assembly ("memory-safe") {
            mstore(0x00, or(0x1234, shl(160, 1)))
            return(0x00, 0x20)
        }
    }
}

contract NoncanonicalBoolFactory {
    // Protocol-compatible Vyper method.
    // forge-lint: disable-next-line(mixed-case-function)
    function is_valid_gauge(address) external pure returns (bool) {
        assembly ("memory-safe") {
            mstore(0x00, 2)
            return(0x00, 0x20)
        }
    }
}

contract RevertingDependency {
    fallback() external {
        revert();
    }
}

contract ReturnDataBombDependency {
    fallback() external {
        assembly ("memory-safe") {
            return(0x00, 0x100000)
        }
    }
}

contract ConfigurableDependency {
    enum Mode {
        REVERT,
        BURN_GAS,
        SHORT_RETURN,
        LONG_RETURN,
        NONCANONICAL_WORD,
        RETURN_DATA_BOMB
    }

    Mode public immutable MODE;

    constructor(Mode mode_) {
        MODE = mode_;
    }

    fallback() external {
        Mode currentMode = MODE;
        if (currentMode == Mode.REVERT) revert();
        if (currentMode == Mode.BURN_GAS) {
            assembly {
                for {} 1 {} {}
            }
        }
        if (currentMode == Mode.SHORT_RETURN) {
            assembly ("memory-safe") {
                mstore(0x00, 1)
                return(0x00, 0x1f)
            }
        }
        if (currentMode == Mode.LONG_RETURN) {
            assembly ("memory-safe") {
                mstore(0x00, 1)
                mstore(0x20, 0)
                return(0x00, 0x40)
            }
        }
        if (currentMode == Mode.NONCANONICAL_WORD) {
            assembly ("memory-safe") {
                mstore(0x00, or(1, shl(160, 1)))
                return(0x00, 0x20)
            }
        }

        assembly ("memory-safe") {
            mstore(0x00, 1)
            return(0x00, 0x100000)
        }
    }
}
