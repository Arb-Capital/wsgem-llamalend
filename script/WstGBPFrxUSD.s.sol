// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    WsgemLlamalendConfig,
    WsgemLlamalendScript,
    WsgemOracleScript,
    WsgemMarketScript
} from "./WsgemLlamalendDeploy.s.sol";
import {WstGBPFxScript} from "./WstGBPFx.s.sol";

import {WsgemFxLlamalendOracle} from "../src/WsgemFxLlamalendOracle.sol";
import {IWsgemShimOracle}       from "../src/interfaces/IWsgemShimOracle.sol";

/// @title WstGBPFrxUSDScript
/// @notice The concrete wstGBP/frxUSD deployment: wstGBP collateral, frxUSD borrowed.
/// @dev Three values, and everything else comes from `script/WstGBPFx.s.sol`. Asserted by
///      test/WstGBPFrxUSDDeployScript.t.sol.
abstract contract WstGBPFrxUSDScript is WstGBPFxScript {
    /// @dev Frax USD, 18 decimals. NOT the legacy FRAX token
    ///      (`0x853d955aCEf822Db058eb8505911ED77F175b99e`), which still exists, still trades, and
    ///      at the time of writing sits about 90 basis points below a dollar. The two are one
    ///      paste apart and price very differently; the deploy scripts' decimals and symbol checks
    ///      would not separate them, so the distinction is stated here.
    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;

    /// @dev Chainlink's frxUSD/USD push aggregator: 8 decimals, 24-hour heartbeat, 0.5% deviation
    ///      threshold.
    ///
    ///      Why Chainlink here when the crvUSD instance uses a Curve aggregator: there is no
    ///      equivalent Curve contract for frxUSD. Curve's `AggregatorStablePrice` is crvUSD's own,
    ///      and the Curve-native route for frxUSD would be a single pool -- frxUSD/crvUSD at
    ///      `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1`, about $13.5M, with a fourteen-minute
    ///      moving average -- divided into the crvUSD aggregator. That rests the market on one
    ///      pool's short average rather than on an OCR set, which is the worse of the two, so this
    ///      instance takes the feed.
    ///
    ///      Do NOT substitute Chainlink's FRAX/USD feed
    ///      (`0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD`). It prices the legacy token, not this
    ///      one, and the gap between them is currently near a percent -- in the direction that
    ///      OVER-values collateral, because the borrowed token's quote is the divisor.
    address internal constant FRXUSD_USD_FEED = 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83;

    function BORROWED() public pure virtual override returns (address) {
        return FRXUSD;
    }

    function BORROWED_QUOTE() public pure override returns (address) {
        return FRXUSD_USD_FEED;
    }

    function BORROWED_QUOTE_KIND()
        public
        pure
        override
        returns (WsgemFxLlamalendOracle.QuoteKind)
    {
        return WsgemFxLlamalendOracle.QuoteKind.CHAINLINK_FEED;
    }
}

/// @title WstGBPFrxUSDOracleScript
/// @notice Deploys the wstGBP/frxUSD price oracle shim on its own.
/// @dev `make oracle-dry INSTANCE=WstGBPFrxUSD`, then `make oracle-deploy INSTANCE=WstGBPFrxUSD`.
contract WstGBPFrxUSDOracleScript is WsgemOracleScript, WstGBPFrxUSDScript {
    // Disambiguations, no logic. See script/WstGBPCrvUSD.s.sol for why they exist.

    function BORROWED()
        public
        pure
        override(WsgemLlamalendConfig, WstGBPFrxUSDScript)
        returns (address)
    {
        return WstGBPFrxUSDScript.BORROWED();
    }

    function _deployOracle()
        internal
        override(WsgemLlamalendScript, WstGBPFxScript)
        returns (IWsgemShimOracle)
    {
        return WstGBPFxScript._deployOracle();
    }

    function _assertOracleExtra(IWsgemShimOracle oracle_)
        internal
        view
        override(WsgemLlamalendScript, WstGBPFxScript)
    {
        WstGBPFxScript._assertOracleExtra(oracle_);
    }

    function _assertFreshOracle(IWsgemShimOracle oracle_)
        internal
        view
        override(WsgemLlamalendScript, WstGBPFxScript)
    {
        WstGBPFxScript._assertFreshOracle(oracle_);
    }

    function _reportOracleExtra(IWsgemShimOracle oracle_)
        internal
        view
        override(WsgemLlamalendScript, WstGBPFxScript)
    {
        WstGBPFxScript._reportOracleExtra(oracle_);
    }
}

/// @title WstGBPFrxUSDMarketScript
/// @notice Deploys the rate calculator and monetary policy, then creates the wstGBP/frxUSD
///         Llamalend V2 market.
/// @dev `make market-dry INSTANCE=WstGBPFrxUSD`, then `make market-deploy INSTANCE=WstGBPFrxUSD`.
///
///      Set WSGEM_ORACLE to reuse the oracle from WstGBPFrxUSDOracleScript rather than deploying a
///      second one. It must be THIS instance's oracle: the wstGBP/tGBP and wstGBP/crvUSD oracles
///      are both rejected by `_assertOracleExtra`, which is the only place that confusion can be
///      caught. The resulting market has a zero borrow cap until a Curve DAO vote lifts it, and
///      that vote is separate from every other instance's.
contract WstGBPFrxUSDMarketScript is WsgemMarketScript, WstGBPFrxUSDScript {
    function _preflight() internal view override(WsgemLlamalendScript, WsgemMarketScript) {
        WsgemMarketScript._preflight();
    }

    function BORROWED()
        public
        pure
        override(WsgemLlamalendConfig, WstGBPFrxUSDScript)
        returns (address)
    {
        return WstGBPFrxUSDScript.BORROWED();
    }

    function _deployOracle()
        internal
        override(WsgemLlamalendScript, WstGBPFxScript)
        returns (IWsgemShimOracle)
    {
        return WstGBPFxScript._deployOracle();
    }

    function _assertOracleExtra(IWsgemShimOracle oracle_)
        internal
        view
        override(WsgemLlamalendScript, WstGBPFxScript)
    {
        WstGBPFxScript._assertOracleExtra(oracle_);
    }

    function _assertFreshOracle(IWsgemShimOracle oracle_)
        internal
        view
        override(WsgemLlamalendScript, WstGBPFxScript)
    {
        WstGBPFxScript._assertFreshOracle(oracle_);
    }

    function _reportOracleExtra(IWsgemShimOracle oracle_)
        internal
        view
        override(WsgemLlamalendScript, WstGBPFxScript)
    {
        WstGBPFxScript._reportOracleExtra(oracle_);
    }
}
