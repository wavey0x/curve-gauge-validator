// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGaugeValidationModule} from "./interfaces/IGaugeValidationModule.sol";
import {IProposalAnalysisModule} from "./interfaces/IProposalAnalysisModule.sol";

/// @notice Validates Curve gauge candidates through owner-configured policy
///         routes and exposes one replaceable proposal analyzer.
/// @dev Validation IDs and module policy are intentionally opaque to the core.
contract GaugeValidator {
    /// @notice Maximum number of simultaneously active gauge-policy routes.
    uint256 public constant MAX_ROUTES = 16;

    /// @notice Gas forwarded to each gauge-policy call.
    uint256 public constant MODULE_CALL_GAS = 200_000;

    /// @notice Gas forwarded to the active proposal analyzer.
    uint256 public constant PROPOSAL_ANALYSIS_CALL_GAS = 20_000_000;

    uint256 private constant ROUTE_GAS_RESERVE = MODULE_CALL_GAS + 20_000;
    uint256 private constant FINAL_RESULT_GAS_RESERVE = 25_000;

    address public owner;
    address public proposalAnalysisModule;

    struct Route {
        address module;
        bytes32 validationId;
    }

    struct FactoryBinding {
        address factory;
        address module;
        bytes32 validationId;
    }

    Route[] private _routes;
    mapping(bytes32 routeKey => uint256 indexPlusOne) private _routeIndexPlusOne;

    /// @notice Number of configured factories bound to each route.
    mapping(bytes32 routeKey => uint256 factoryCount) public routeFactoryCount;

    /// @notice Exact route key configured for each factory, or zero if absent.
    mapping(address factory => bytes32 routeKey) public routeForFactory;

    event RouteAdded(bytes32 indexed routeKey, address indexed module, bytes32 indexed validationId);
    event RouteRemoved(bytes32 indexed routeKey, address indexed module, bytes32 indexed validationId);
    event FactoryRouteSet(address indexed factory, bytes32 indexed previousRouteKey, bytes32 indexed newRouteKey);
    event ProposalAnalysisModuleSet(address indexed previousModule, address indexed newModule);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner(address caller);
    error ZeroAddress();
    error MissingCode(address target);
    error ZeroValidationId();
    error DuplicateRoute(bytes32 routeKey);
    error UnknownRoute(bytes32 routeKey);
    error RouteLimitReached();
    error RouteStillInUse(bytes32 routeKey, uint256 factoryCount);
    error InvalidRevocation();
    error DuplicateFactoryBinding(address factory);

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function _checkOwner() private view {
        if (msg.sender != owner) revert NotOwner(msg.sender);
    }

    constructor(
        address owner_,
        address proposalAnalysisModule_,
        Route[] memory initialRoutes,
        FactoryBinding[] memory initialBindings
    ) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (proposalAnalysisModule_ != address(0)) _requireCode(proposalAnalysisModule_);

        owner = owner_;
        proposalAnalysisModule = proposalAnalysisModule_;

        emit OwnershipTransferred(address(0), owner_);
        emit ProposalAnalysisModuleSet(address(0), proposalAnalysisModule_);

        for (uint256 i; i < initialRoutes.length; ++i) {
            _addRoute(initialRoutes[i].module, initialRoutes[i].validationId);
        }

        for (uint256 i; i < initialBindings.length; ++i) {
            FactoryBinding memory binding = initialBindings[i];
            if (routeForFactory[binding.factory] != bytes32(0)) {
                revert DuplicateFactoryBinding(binding.factory);
            }
            _setFactoryRoute(binding.factory, binding.module, binding.validationId);
        }
    }

    // ---------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------

    function addRoute(address module, bytes32 validationId) external onlyOwner {
        _addRoute(module, validationId);
    }

    function removeRoute(address module, bytes32 validationId) external onlyOwner {
        bytes32 key = _routeKey(module, validationId);
        uint256 indexPlusOne = _routeIndexPlusOne[key];
        if (indexPlusOne == 0) revert UnknownRoute(key);

        uint256 factoryCount = routeFactoryCount[key];
        if (factoryCount != 0) revert RouteStillInUse(key, factoryCount);

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _routes.length - 1;
        if (index != lastIndex) {
            Route memory moved = _routes[lastIndex];
            _routes[index] = moved;
            _routeIndexPlusOne[_routeKey(moved.module, moved.validationId)] = index + 1;
        }

        _routes.pop();
        delete _routeIndexPlusOne[key];

        emit RouteRemoved(key, module, validationId);
    }

    /// @notice Binds a factory to an exact route. Passing zero for both route
    ///         fields revokes the factory's existing binding.
    function setFactoryRoute(address factory, address module, bytes32 validationId) external onlyOwner {
        _setFactoryRoute(factory, module, validationId);
    }

    /// @notice Replaces the proposal analyzer. Passing zero disables analysis.
    function setProposalAnalysisModule(address newModule) external onlyOwner {
        if (newModule != address(0)) _requireCode(newModule);

        address previousModule = proposalAnalysisModule;
        proposalAnalysisModule = newModule;

        emit ProposalAnalysisModuleSet(previousModule, newModule);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();

        address previousOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(previousOwner, newOwner);
    }

    // ---------------------------------------------------------------------
    // Configuration views
    // ---------------------------------------------------------------------

    function routeCount() external view returns (uint256) {
        return _routes.length;
    }

    function routeAt(uint256 index) external view returns (address module, bytes32 validationId) {
        Route storage route = _routes[index];
        return (route.module, route.validationId);
    }

    // ---------------------------------------------------------------------
    // Validation and proposal analysis
    // ---------------------------------------------------------------------

    /// @notice Returns true only when exactly one configured route
    ///         authenticates the gauge through its bound factory.
    function validateGauge(address gauge) external view returns (bool) {
        return _gaugeMatchCount(gauge) == 1;
    }

    /// @notice Reports recognized gauge additions and their current validity.
    /// @dev The active analyzer is trusted policy. Disabled or reverting
    ///      analysis returns a canonical UNAVAILABLE result.
    function analyzeProposalGaugeAdditions(uint256 proposalId)
        external
        view
        returns (IProposalAnalysisModule.ProposalGaugeAnalysis memory result)
    {
        address analyzer = proposalAnalysisModule;
        if (analyzer == address(0)) return _unavailableAnalysis();

        try IProposalAnalysisModule(analyzer).analyzeProposalGaugeAdditions{gas: PROPOSAL_ANALYSIS_CALL_GAS}(
            proposalId, address(this)
        ) returns (
            IProposalAnalysisModule.ProposalGaugeAnalysis memory analysis
        ) {
            return analysis;
        } catch {
            return _unavailableAnalysis();
        }
    }

    /// @dev Returns 0, 1, or 2 for no, unique, or ambiguous matches.
    ///      type(uint256).max represents insufficient gas and therefore fails
    ///      closed at the boolean entrypoint.
    function _gaugeMatchCount(address gauge) private view returns (uint256 matchCount) {
        if (gauge == address(0) || gauge.code.length == 0) return 0;

        uint256 length = _routes.length;
        for (uint256 i; i < length; ++i) {
            uint256 remaining = length - i;
            if (gasleft() < remaining * ROUTE_GAS_RESERVE + FINAL_RESULT_GAS_RESERVE) {
                return type(uint256).max;
            }

            Route storage route = _routes[i];
            (bool success, address factory) = _callModule(route.module, gauge, route.validationId);
            if (!success || factory == address(0)) continue;
            if (routeForFactory[factory] != _routeKey(route.module, route.validationId)) continue;

            if (matchCount < 2) ++matchCount;
        }
    }

    function _unavailableAnalysis() private pure returns (IProposalAnalysisModule.ProposalGaugeAnalysis memory result) {
        result.status = IProposalAnalysisModule.AnalysisStatus.UNAVAILABLE;
        result.recognizedGaugeAdditions = new IProposalAnalysisModule.GaugeAdditionAnalysis[](0);
    }

    // ---------------------------------------------------------------------
    // Internal configuration and bounded module calls
    // ---------------------------------------------------------------------

    function _addRoute(address module, bytes32 validationId) private {
        if (module == address(0)) revert ZeroAddress();
        if (validationId == bytes32(0)) revert ZeroValidationId();
        _requireCode(module);
        if (_routes.length == MAX_ROUTES) revert RouteLimitReached();

        bytes32 key = _routeKey(module, validationId);
        if (_routeIndexPlusOne[key] != 0) revert DuplicateRoute(key);

        _routes.push(Route({module: module, validationId: validationId}));
        _routeIndexPlusOne[key] = _routes.length;

        emit RouteAdded(key, module, validationId);
    }

    function _setFactoryRoute(address factory, address module, bytes32 validationId) private {
        if (factory == address(0)) revert ZeroAddress();

        bool revoking = module == address(0) && validationId == bytes32(0);
        if (!revoking && (module == address(0) || validationId == bytes32(0))) {
            revert InvalidRevocation();
        }

        bytes32 newKey;
        if (!revoking) {
            _requireCode(factory);
            newKey = _routeKey(module, validationId);
            if (_routeIndexPlusOne[newKey] == 0) revert UnknownRoute(newKey);
        }

        bytes32 previousKey = routeForFactory[factory];
        if (previousKey == newKey) return;

        if (previousKey != bytes32(0)) {
            unchecked {
                --routeFactoryCount[previousKey];
            }
        }

        routeForFactory[factory] = newKey;
        if (newKey != bytes32(0)) ++routeFactoryCount[newKey];

        emit FactoryRouteSet(factory, previousKey, newKey);
    }

    function _callModule(address module, address gauge, bytes32 validationId)
        private
        view
        returns (bool success, address factory)
    {
        bytes4 selector = IGaugeValidationModule.factoryForGauge.selector;
        uint256 word;
        uint256 returnSize;

        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, selector)
            mstore(add(pointer, 0x04), and(gauge, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(pointer, 0x24), validationId)
            success := staticcall(MODULE_CALL_GAS, module, pointer, 0x44, pointer, 0x20)
            returnSize := returndatasize()
            word := mload(pointer)
        }

        if (!success || returnSize != 32 || word >> 160 != 0) {
            return (false, address(0));
        }

        // The canonical-address check above proves the narrowing is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        factory = address(uint160(word));
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert MissingCode(target);
    }

    function _routeKey(address module, bytes32 validationId) private pure returns (bytes32 key) {
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, and(module, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(pointer, 0x20), validationId)
            key := keccak256(pointer, 0x40)
        }
    }
}
