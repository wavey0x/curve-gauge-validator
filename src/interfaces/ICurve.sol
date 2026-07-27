// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Selector catalog only. Do not use as a typed contract interface.
interface ICurve {
    function factory() external;
    // forge-lint: disable-next-line(mixed-case-function)
    function lp_token() external;
    // forge-lint: disable-next-line(mixed-case-function)
    function get_gauge(address) external;
    function minter() external;
    // forge-lint: disable-next-line(mixed-case-function)
    function gauge_for_vault(address) external;
    // forge-lint: disable-next-line(mixed-case-function)
    function is_valid_gauge(address) external;
    // forge-lint: disable-next-line(mixed-case-function)
    function add_gauge(address, int128, uint256) external;
    function execute(address, uint256, bytes calldata) external;
}
