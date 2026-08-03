// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

import {IWsgem}       from "../../src/interfaces/IWsgem.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @title DownsideDampedOracle
/// @notice The counterfactual `WsgemLlamalendOracle` is deliberately not: a SYMMETRIC speed limit,
///         damping falls as well as rises.
/// @dev A test fixture, not production code, and deliberately thin -- no freeze path, no live-zero
///      floor, no gas-capped reads. It exists to answer one question with numbers rather than
///      argument: what does a market lose, and what does it gain, if a downward publication is
///      metered out instead of passed through in one block?
///
///      Curve's post-sDOLA position is that a Llamalend oracle should have no capacity for an
///      instantaneous price jump *for any reason* -- a direction-blind rule. The shipped shim
///      conforms upward and diverges downward on purpose (docs/02-oracle-shim.md, hazard 3). This
///      contract is the other branch of that choice, so the two can be run against the same market,
///      the same positions and the same publication, and the difference read off rather than
///      asserted.
///
///      It keeps the one structural property `LendFactory.create` enforces: `price()` and
///      `price_w()` compute the SAME pure function of the stored checkpoint, and only the write
///      path persists. An oracle that advanced state before returning would fail market creation.
contract DownsideDampedOracle is IPriceOracle {
    uint256 internal constant WAD = 1e18;

    /// @notice Same allowance cap the shipped shim carries, for the same reason.
    uint256 public constant MAX_ELAPSED = 7 days;

    IWsgem public immutable WSGEM;

    /// @notice Maximum relative move per second, WAD-scaled. Applied in BOTH directions.
    uint256 public immutable MAX_SPEED;

    uint256 public cachedPrice;
    uint256 public cachedTimestamp;

    constructor(IWsgem wsgem_, uint256 maxSpeed_) {
        WSGEM     = wsgem_;
        MAX_SPEED = maxSpeed_;

        uint256 spot_ = wsgem_.burncost();
        require(spot_ > 0, "damped: zero quote at construction");

        cachedPrice     = spot_;
        cachedTimestamp = block.timestamp;
    }

    function price() external view returns (uint256) {
        return _price();
    }

    function price_w() external returns (uint256) {
        uint256 price_ = _price();
        cachedTimestamp = block.timestamp;
        if (price_ != cachedPrice) cachedPrice = price_;
        return price_;
    }

    /// @notice The undamped quote, for the test's mark-to-market leg.
    function spotPrice() external view returns (uint256) {
        return WSGEM.burncost();
    }

    function _price() internal view returns (uint256) {
        uint256 spot_ = WSGEM.burncost();
        if (spot_ == 0) return cachedPrice; // freeze, as the shipped shim does

        (uint256 floor_, uint256 ceiling_) = _bounds();
        if (spot_ > ceiling_) return ceiling_;
        if (spot_ < floor_) return floor_;
        return spot_;
    }

    /// @dev The symmetric band the reported price may move within since the last checkpoint.
    ///      `MAX_SPEED == 0` means no limit at all -- the undamped control arm. It has to be a
    ///      special case rather than a very large speed, because the band is computed from time
    ///      elapsed and no time elapses within the block a publication lands in: any finite speed
    ///      pins the reported price to the anchor in exactly the block the measurement is about.
    function _bounds() internal view returns (uint256 floor_, uint256 ceiling_) {
        if (MAX_SPEED == 0) return (1, type(uint256).max);

        uint256 cached_  = cachedPrice;
        uint256 elapsed_ = block.timestamp - cachedTimestamp;
        if (elapsed_ > MAX_ELAPSED) elapsed_ = MAX_ELAPSED;

        uint256 move_ = (cached_ * MAX_SPEED * elapsed_) / WAD;
        ceiling_      = cached_ + move_;
        floor_        = move_ >= cached_ ? 1 : cached_ - move_; // never zero
    }
}
