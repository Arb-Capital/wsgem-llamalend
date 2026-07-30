// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                 from "forge-std/Test.sol";
import {WsgemLlamalendOracle} from "../src/WsgemLlamalendOracle.sol";
import {IWsgem}               from "../src/interfaces/IWsgem.sol";
import {MockPip, MockGem, MockWsgem} from "./mocks/MockWsgem.sol";

contract WsgemLlamalendOracleTest is Test {
    uint256 internal constant WAD   = 1e18;
    uint256 internal constant SPEED = uint256(0.0025e18) / 1 days; // the configured 0.25% per day
    uint256 internal constant NAV0  = 1.05e18;

    MockPip              internal pip;
    MockGem              internal gem;
    MockWsgem            internal wsgem;
    WsgemLlamalendOracle internal oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        pip    = new MockPip(NAV0);
        gem    = new MockGem(18);
        wsgem  = new MockWsgem(address(gem), address(pip), 18);
        oracle = new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
    }

    // --- Construction ------------------------------------------------------------------------

    function test_constructorCachesTheImmutableWiring() public view {
        assertEq(address(oracle.WSGEM()), address(wsgem));
        assertEq(oracle.GEM(), address(gem));
        assertEq(address(oracle.PIP()), address(pip));
        assertEq(oracle.MAX_UPSIDE_SPEED(), SPEED);
    }

    function test_constructorReportsTheLiveNavExactly() public view {
        assertEq(oracle.price(), NAV0, "a fresh oracle must not be rate-limited against itself");
    }

    function test_constructorRejectsAPausedFeed() public {
        pip.poke(0);
        vm.expectRevert(WsgemLlamalendOracle.OraclePaused.selector);
        new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
    }

    function test_constructorRejectsANonEighteenDecimalWsgem() public {
        MockWsgem odd_ = new MockWsgem(address(gem), address(pip), 6);
        vm.expectRevert(WsgemLlamalendOracle.UnsupportedDecimals.selector);
        new WsgemLlamalendOracle(IWsgem(address(odd_)), SPEED);
    }

    function test_constructorRejectsANonEighteenDecimalGem() public {
        MockGem   odd_    = new MockGem(6);
        MockWsgem wsgem_  = new MockWsgem(address(odd_), address(pip), 18);
        vm.expectRevert(WsgemLlamalendOracle.UnsupportedDecimals.selector);
        new WsgemLlamalendOracle(IWsgem(address(wsgem_)), SPEED);
    }

    function test_constructorRejectsAnUnboundedSpeed() public {
        // Read the limit BEFORE arming the cheatcode: expectRevert binds to the next call, and an
        // inline `oracle.MAX_UPSIDE_SPEED_LIMIT()` would be that call.
        uint256 tooHigh_ = oracle.MAX_UPSIDE_SPEED_LIMIT() + 1;

        vm.expectRevert(WsgemLlamalendOracle.SpeedTooHigh.selector);
        new WsgemLlamalendOracle(IWsgem(address(wsgem)), tooHigh_);

        vm.expectRevert(WsgemLlamalendOracle.SpeedTooHigh.selector);
        new WsgemLlamalendOracle(IWsgem(address(wsgem)), 0);
    }

    // --- The factory's own check ---------------------------------------------------------------

    /// @dev `LendFactory.create` reads `price()` into a local and asserts `price_w()` equals it.
    ///      An oracle that advances state before returning fails market creation outright.
    function test_priceAndPriceWAgreeWithinACall() public {
        pip.poke(2e18); // a jump large enough that the rate limit is binding
        skip(3 days);

        uint256 p_ = oracle.price();
        assertEq(oracle.price_w(), p_, "price_w must return exactly what price returned");
    }

    function test_priceIsUnchangedByAPriceWInTheSameBlock() public {
        pip.poke(2e18);
        skip(3 days);

        uint256 before_ = oracle.price();
        oracle.price_w();
        assertEq(oracle.price(), before_, "price_w must not move price within a block");
    }

    // --- Upside rate limit -----------------------------------------------------------------------

    function test_aSmallRiseIsAbsorbedQuickly() public {
        // The observed cadence is ~6.8 bp per week. At 0.25%/day the limit clears that in ~6.5h.
        uint256 target_ = (NAV0 * (WAD + 0.00068e18)) / WAD;
        pip.poke(target_);

        skip(7 hours);
        oracle.price_w();
        assertEq(oracle.price(), target_, "an ordinary weekly step must not be rate-limited for long");
    }

    function test_aLargeRiseIsRateLimited() public {
        pip.poke(NAV0 * 10);

        skip(1 days);
        uint256 p_ = oracle.price();

        // One day of allowance is 0.25%, so the reported price must be about 1.0025x, not 10x.
        assertApproxEqRel(p_, (NAV0 * 10_025) / 10_000, 1e12);
        assertLt(p_, (NAV0 * 10_050) / 10_000, "one day must not buy more than one day of allowance");
    }

    function test_aLargeRiseEventuallyArrives() public {
        pip.poke(NAV0 * 2);

        // Ratchet forward a day at a time. Compounding at 0.25%/day, doubling takes ~278 days.
        for (uint256 i; i < 300; ++i) {
            skip(1 days);
            oracle.price_w();
        }
        assertEq(oracle.price(), NAV0 * 2, "the limit must delay a genuine repricing, not block it");
    }

    function test_allowanceDoesNotAccrueBeyondMaxElapsed() public {
        pip.poke(NAV0 * 100);

        // A market untouched for a year must not accumulate a year of allowance.
        skip(365 days);
        uint256 p_ = oracle.price();

        uint256 ceilingAt7Days_ = NAV0 + (NAV0 * SPEED * 7 days) / WAD;
        assertEq(p_, ceilingAt7Days_, "elapsed time must be capped at MAX_ELAPSED");
    }

    function test_priceWDoesNotBankAllowanceAcrossAFreeze() public {
        // Freeze for a month, then republish far above the last good price. The limit must be
        // measured from the moment the freeze ended, not from before it began.
        pip.poke(0);
        for (uint256 i; i < 30; ++i) {
            skip(1 days);
            oracle.price_w(); // the AMM keeps touching the oracle through a pause
        }

        pip.poke(NAV0 * 10);
        skip(1 days);
        assertApproxEqRel(oracle.price(), (NAV0 * 10_025) / 10_000, 1e12);
    }

    // --- Downside ------------------------------------------------------------------------------

    function test_aFallPassesThroughImmediately() public {
        uint256 lower_ = NAV0 / 2;
        pip.poke(lower_);
        assertEq(oracle.price(), lower_, "under-valuing collateral is the safe direction");
    }

    function test_aFallResetsTheCeiling() public {
        pip.poke(NAV0 / 2);
        oracle.price_w();

        // The ceiling must now grow from the new, lower level rather than the old one.
        skip(1 days);
        assertApproxEqRel(oracle.priceCeiling(), (NAV0 * 10_025) / 20_000, 1e12);
    }

    // --- Freeze ----------------------------------------------------------------------------------

    function test_aPausedFeedFreezesRatherThanReportingZero() public {
        pip.poke(0);
        assertTrue(oracle.frozen());
        assertEq(oracle.price(), NAV0, "zero must never reach Llamalend");
        assertEq(oracle.price_w(), NAV0);
    }

    function test_anUnreadableFeedFreezesToo() public {
        pip.setMode(MockPip.Mode.REVERTING);
        assertEq(oracle.price(), NAV0, "a reverting pip is a pause with a different shape");
        assertEq(oracle.price_w(), NAV0);
    }

    function test_aShortReturnFreezesToo() public {
        pip.setMode(MockPip.Mode.SHORT_RETURN);
        assertEq(oracle.price(), NAV0);
    }

    function test_aLongReturnIsReadAsItsFirstWord() public {
        pip.setMode(MockPip.Mode.LONG_RETURN);
        assertEq(oracle.price(), NAV0, "an over-long return decodes to its first word");
    }

    function test_freezeHoldsTheLastReportedPriceNotTheLastSpot() public {
        // Reported price lags a jump. When the feed then pauses, the freeze must hold the value
        // this oracle last REPORTED -- not the higher spot it never reported.
        pip.poke(NAV0 * 10);
        skip(1 days);
        uint256 reported_ = oracle.price_w();

        pip.poke(0);
        assertEq(oracle.price(), reported_);
        assertLt(reported_, NAV0 * 10);
    }

    function test_priceIsNeverZeroAcrossAFullPauseCycle() public {
        pip.poke(0);
        for (uint256 i; i < 10; ++i) {
            skip(1 days);
            assertGt(oracle.price(), 0);
            assertGt(oracle.price_w(), 0);
        }
        pip.poke(NAV0);
        assertGt(oracle.price(), 0);
    }

    // --- Ownerlessness ---------------------------------------------------------------------------

    /// @dev The whole premise of the shim. If any of these ever resolve, something with an admin
    ///      has been introduced between the feed and the market.
    function test_thereIsNoAdministrativeSurface() public view {
        string[8] memory sigs_ = [
            "owner()",
            "admin()",
            "wards(address)",
            "rely(address)",
            "deny(address)",
            "setPrice(uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < sigs_.length; ++i) {
            (bool ok_,) = address(oracle).staticcall(abi.encodeWithSignature(sigs_[i], address(0)));
            assertFalse(ok_, sigs_[i]);
        }
    }

    // --- Fuzz --------------------------------------------------------------------------------------

    function testFuzz_reportedPriceNeverExceedsSpot(uint128 nav_, uint32 dt_) public {
        vm.assume(nav_ > 0);
        pip.poke(nav_);
        skip(dt_);
        assertLe(oracle.price(), nav_, "the shim may under-report, never over-report");
    }

    function testFuzz_reportedPriceIsNeverZero(uint128 nav_, uint32 dt_) public {
        pip.poke(nav_);
        skip(dt_);
        assertGt(oracle.price(), 0);
        assertGt(oracle.price_w(), 0);
    }

    function testFuzz_priceAndPriceWAlwaysAgree(uint128 nav_, uint32 dt_) public {
        pip.poke(nav_);
        skip(dt_);
        assertEq(oracle.price_w(), oracle.price());
    }
}
