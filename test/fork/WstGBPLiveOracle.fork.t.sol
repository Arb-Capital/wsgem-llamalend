// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                 from "forge-std/Test.sol";
import {WsgemLlamalendOracle} from "../../src/WsgemLlamalendOracle.sol";
import {IWsgem}               from "../../src/interfaces/IWsgem.sol";
import {IPip}                 from "../../src/interfaces/IPip.sol";
import {WstGBPMarketScript}   from "../../script/WstGBP.s.sol";

/// @dev The wrapper's spread-setting surface, pranked as its ward in the zero-quote drill.
interface IActFile {
    function setBpsout(uint256 bpsout_) external;
}

/// @notice Exposes the deploy script's internal oracle validation so the LIVE instance can be
///         run through the exact code path `make market-deploy` will take with `WSGEM_ORACLE` set.
contract LiveOracleScriptHarness is WstGBPMarketScript {
    function assertOracle(WsgemLlamalendOracle oracle_) external {
        _assertOracle(oracle_);
    }
}

/// @notice The deployed wstGBP oracle, tested as the artifact on mainnet rather than as source.
/// @dev The other fork suites deploy FRESH shims into the fork and prove the code; this one
///      pins the deployment itself -- the instance recorded in `docs/instances/wstgbp.md`. It
///      proves three things nothing else does: the artifact at the live address is built from
///      this exact tree (so editing `src/WsgemLlamalendOracle.sol` after deployment fails here,
///      by design -- the shims are never redeployed), the market deploy's own validation accepts
///      it, and the docs/05 step-2 observation conditions hold and behave as documented -- the
///      publication-absorption drill runs the live contract through a synthetic NAV step instead
///      of waiting a week for a real one. The drills complement the real observation window;
///      they do not replace it.
///
///      Requires `ETH_FORK_BLOCK >= 25670242`, the deployment block: at an earlier pin the live
///      address has no code, and `setUp` hard-fails rather than skipping.
contract WstGBPLiveOracleForkTest is Test {
    /// @dev Deployed 2026-08-02 at block 25670242 -- see `docs/instances/wstgbp.md` for the full
    ///      deployment record. Hardcoded like the sDOLA references in the bytecode suite: this is
    ///      a fact about mainnet, not a configuration.
    address internal constant LIVE_ORACLE = 0xdc85a32D5B93e040A4e84401D567DcE02237557C;

    WstGBPMarketScript internal cfg;

    address internal WSGEM;

    WsgemLlamalendOracle internal oracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envUint("ETH_FORK_BLOCK"));

        // Read the production constants from the production script rather than restating them, so
        // this suite cannot drift away from what is actually deployed.
        cfg    = new WstGBPMarketScript();
        WSGEM  = cfg.WSGEM();
        oracle = WsgemLlamalendOracle(LIVE_ORACLE);

        require(
            LIVE_ORACLE.code.length > 0,
            "no code at the live oracle -- ETH_FORK_BLOCK must be >= 25670242"
        );
    }

    // --- The deployed artifact ---------------------------------------------------------------------

    /// @dev The wiring the instance sheet records, read back from the chain: the live oracle
    ///      prices this market's wsgem through this market's feed at the configured speed. Every
    ///      immutable is asserted directly so a mismatch names the field rather than opaquely
    ///      failing downstream.
    function test_theLiveOracleMatchesTheInstanceConfiguration() public view {
        assertEq(address(oracle.WSGEM()), WSGEM, "wsgem");
        assertEq(oracle.GEM(), cfg.GEM(), "gem");
        assertEq(address(oracle.PIP()), IWsgem(WSGEM).pip(), "pip");
        assertEq(oracle.MAX_UPSIDE_SPEED(), cfg.MAX_UPSIDE_SPEED(), "max upside speed");
    }

    /// @dev The exact validation `make market-deploy` runs against `WSGEM_ORACLE` before
    ///      broadcasting, applied to the live instance through the production script itself. If
    ///      this fails, so will the market deploy -- better to learn that during the observation
    ///      window than at broadcast time.
    function test_theMarketDeployValidationAcceptsTheLiveOracle() public {
        LiveOracleScriptHarness h_ = new LiveOracleScriptHarness();
        h_.assertOracle(oracle);
    }

    /// @dev The provenance guarantee the vendored monetary policy gets, extended to our own
    ///      contract: a fresh oracle built from THIS tree with THIS configuration -- immutables
    ///      included, since they are read off the same wsgem -- must match the deployed runtime
    ///      code byte for byte. Depends on `foundry.toml`'s pinned solc/optimizer/EVM settings
    ///      staying frozen, and fails on any post-deployment edit to the oracle source. That is
    ///      the point: the deployed shim is immutable, so the tree must stay the artifact's
    ///      source of truth rather than drifting away from it.
    function test_theDeployedRuntimeCodeMatchesThisTree() public {
        WsgemLlamalendOracle fresh_ =
            new WsgemLlamalendOracle(IWsgem(WSGEM), cfg.MAX_UPSIDE_SPEED());

        assertEq(
            address(fresh_).code,
            LIVE_ORACLE.code,
            "the live oracle is not built from this tree"
        );
    }

    // --- The observation window (docs/05 step 2) ---------------------------------------------------

    /// @dev The step-2 conditions, asserted at the pinned block instead of hand-polled with
    ///      `cast`: live quote, price at or below spot, not frozen, not zero-quoting, and the
    ///      report sitting exactly on `min(spot, ceiling)` -- the identity that holds whether or
    ///      not a publication is mid-absorption at the pin.
    function test_theObservationConditionsHoldAtThePin() public view {
        uint256 price_ = oracle.price();
        uint256 spot_  = oracle.spotPrice();
        uint256 ceil_  = oracle.priceCeiling();

        assertGt(spot_, 0, "the feed and quote must be live at the pinned block");
        assertGt(price_, 0, "price is never zero");
        assertLe(price_, spot_, "price never exceeds spot");
        assertFalse(oracle.frozen());
        assertFalse(oracle.quoteIsZero());
        assertEq(price_, spot_ < ceil_ ? spot_ : ceil_, "price is exactly min(spot, ceiling)");
    }

    /// @dev What the observation window exists to watch, run against the live contract on a
    ///      synthetic clock: one weekly-sized NAV step is expressed gradually -- riding the
    ///      ceiling while the limit binds -- and converges fully within ~6.5 hours at the
    ///      configured 0.25%/day, long before the next publication. The `price_w` poke first
    ///      re-anchors the allowance so the drill measures the limit, not however much elapsed
    ///      headroom the pinned block happens to carry.
    function test_aSyntheticPublicationIsAbsorbedWithinHours() public {
        uint256 anchor_ = oracle.price_w();
        uint256 nav_    = IPip(IWsgem(WSGEM).pip()).read();

        // One publication at the observed cadence: ~6.8 bp, about 3.54% APR over 52 weeks.
        _setNav(nav_ + (nav_ * 354) / 10_000 / 52);

        uint256 spot_ = oracle.spotPrice();
        assertGt(spot_, anchor_, "the step must move the live quote up");
        assertEq(oracle.price(), anchor_, "the step is not expressed instantly");

        skip(1 hours);
        assertGt(oracle.price(), anchor_, "an hour in, part of the step has been expressed");
        assertLt(oracle.price(), spot_, "an hour in, the limit still binds");
        assertEq(oracle.price(), oracle.priceCeiling(), "while binding, the report rides the ceiling");
        assertFalse(oracle.frozen(), "absorption is not a freeze");

        skip(6 hours);
        assertEq(oracle.price(), spot_, "converged well before the next publication");
    }

    /// @dev The docs/07 "feed frozen" alarm condition, demonstrated on the live instance: a
    ///      paused pip freezes the report at its last value rather than propagating a zero, and
    ///      an unpause resumes exactly where it held.
    function test_aPipPauseFreezesTheLiveOracleAtItsLastReport() public {
        uint256 held_ = oracle.price();

        vm.mockCall(IWsgem(WSGEM).pip(), abi.encodeCall(IPip.read, ()), abi.encode(uint256(0)));
        assertTrue(oracle.frozen(), "a zero NAV is a pause");
        assertEq(oracle.price(), held_, "a freeze holds the last report");
        assertEq(oracle.spotPrice(), 0, "spot reads zero so monitoring can see the freeze");

        vm.clearMockedCalls();
        assertFalse(oracle.frozen());
        assertEq(oracle.price(), held_, "recovery resumes from the held report");
    }

    /// @dev The wrapper's spread is settable to 100% on the live act, zeroing `burncost()` while
    ///      the feed stays live. The deployed oracle must read that as the one-wei floor -- not a
    ///      pause -- and recover its anchor exactly when the spread is restored. Same drill the
    ///      lifecycle suite runs against a fresh oracle, here against the deployment.
    function test_aHundredPercentSpreadFloorsTheLivePriceAndRecovers() public {
        address act_    = IWsgem(WSGEM).act();
        address ward_   = 0xa73c94969dE90Edb159D29922C42fF24beDFA085;
        uint256 anchor_ = oracle.price_w();

        vm.prank(ward_);
        IActFile(act_).setBpsout(10_000);

        assertEq(IWsgem(WSGEM).burncost(), 0, "the live wrapper quotes zero at a 100% spread");
        assertEq(oracle.price(), 1, "a live zero floors the price at one wei");
        assertFalse(oracle.frozen(), "this is not a pause");
        assertTrue(oracle.quoteIsZero());

        vm.prank(ward_);
        IActFile(act_).setBpsout(25);

        assertEq(oracle.price(), anchor_, "restoration recovers the anchor exactly");
        assertFalse(oracle.quoteIsZero());
    }

    // --- Helpers ------------------------------------------------------------------------------------

    /// @dev Overrides what the live feed reports, without touching its storage layout. Everything
    ///      downstream -- the wsgem's own `navprice()`, the live oracle, `burncost()` -- reads
    ///      through this one method, so the whole live stack still runs; only the published
    ///      number is ours.
    function _setNav(uint256 nav_) internal {
        vm.mockCall(IWsgem(WSGEM).pip(), abi.encodeCall(IPip.read, ()), abi.encode(nav_));
        require(IWsgem(WSGEM).navprice() == nav_, "nav override did not take");
    }
}
