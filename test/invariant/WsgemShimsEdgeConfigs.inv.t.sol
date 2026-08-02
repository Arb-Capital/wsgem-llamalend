// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WsgemShimsInvariantTest} from "./WsgemShims.inv.t.sol";

/// @notice The full invariant set rerun at the constructors' accept-boundaries. The parent suite
///         runs the configured wstGBP parameters; a property that only holds there is not a
///         property of the contracts, and these are the configurations most likely to expose
///         that -- every bound at its legal extreme, both cadence regimes interleaved by the
///         shared handler's `accrue` action.

/// @notice One extreme: the floor disabled, the shortest window and grace, the fastest legal
///         upside limit.
/// @dev `spacing == 0` is the regime where every distinct reading records -- same-block
///      re-records and collapsed spans included -- and `gap == 1 days` keeps the overdue
///      extension hot in nearly every run.
contract WsgemShimsTightConfigInvariantTest is WsgemShimsInvariantTest {
    function setUp() public override {
        _setUp(uint256(1e18) / 1 hours, 2, 1 days, 0, 1e18); // == MAX_UPSIDE_SPEED_LIMIT
    }
}

/// @notice The other extreme: the widest window and grace, a one-second floor, a one-wei-per-
///         second upside limit.
/// @dev The dust-speed limit drives the ghost's rounding arm, and the widest window exercises
///      the full ring depth under both cadence regimes.
contract WsgemShimsWideConfigInvariantTest is WsgemShimsInvariantTest {
    function setUp() public override {
        _setUp(1, 7, 90 days, 1, 1e18);
    }
}
