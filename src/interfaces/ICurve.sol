// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Selector catalog only. Do not use as a typed contract interface.
interface ICurve {
    function factory() external;
    function lp_token() external;
    function get_gauge(address) external;
    function minter() external;
    function gauge_for_vault(address) external;
    function is_valid_gauge(address) external;
    function add_gauge(address, int128, uint256) external;
    function execute(address, uint256, bytes calldata) external;
}
