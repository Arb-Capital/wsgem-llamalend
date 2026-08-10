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

/// @title WstGBPCrvUSDScript
/// @notice The concrete wstGBP/crvUSD deployment: wstGBP collateral, crvUSD borrowed.
/// @dev Three values, and everything else comes from `script/WstGBPFx.s.sol`. Asserted by
///      test/WstGBPCrvUSDDeployScript.t.sol.
abstract contract WstGBPCrvUSDScript is WstGBPFxScript {
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    /// @dev Curve's own crvUSD aggregator, `price()` in WAD. Chosen over Chainlink's CRVUSD/USD
    ///      feed (`0xEEf0C605546958c1f899b6fB336C20671f9cD49F`, 8 decimals, 24-hour heartbeat,
    ///      0.5% deviation) because it is what Curve's crvUSD markets themselves read, what the
    ///      comparable svZCHF/crvUSD market's oracle reads, and because it carries no heartbeat to
    ///      go stale -- it is an exponential moving average over five Curve pools pairing crvUSD
    ///      against dollar stablecoins, so it moves with trades. A 0.5% deviation threshold on a
    ///      token that lives within a few basis points of a dollar is a feed that can sit at its
    ///      last value through the entire range that matters.
    ///
    ///      The cost of that choice, stated plainly: its "dollar" is a basket of dollar
    ///      stablecoins rather than Chainlink's USD, so composing the two legs leaves a small
    ///      residual basis. And its admin is the Curve DAO agent
    ///      (`0x40907540d8a6C65c637785e8f8B742ae6b0b9968`) -- the same agent that admins the
    ///      LendFactory -- which chooses the pools it averages over. See docs/02-oracle-shim.md.
    address internal constant CRVUSD_AGGREGATOR = 0x18672b1b0c623a30089A280Ed9256379fb0E4E62;

    function BORROWED() public pure virtual override returns (address) {
        return CRVUSD;
    }

    function BORROWED_QUOTE() public pure override returns (address) {
        return CRVUSD_AGGREGATOR;
    }

    function BORROWED_QUOTE_KIND()
        public
        pure
        override
        returns (WsgemFxLlamalendOracle.QuoteKind)
    {
        return WsgemFxLlamalendOracle.QuoteKind.CURVE_AGGREGATOR;
    }
}

/// @title WstGBPCrvUSDOracleScript
/// @notice Deploys the wstGBP/crvUSD price oracle shim on its own.
/// @dev `make oracle-dry INSTANCE=WstGBPCrvUSD`, then `make oracle-deploy INSTANCE=WstGBPCrvUSD`.
contract WstGBPCrvUSDOracleScript is WsgemOracleScript, WstGBPCrvUSDScript {
    // Disambiguations, no logic. Both branches of this instance's inheritance reach
    // `WsgemLlamalendScript`, so Solidity requires the derived contract to say which definition of
    // each shared member it means. Every one forwards; the reasoning lives once, up the chain.

    function BORROWED()
        public
        pure
        override(WsgemLlamalendConfig, WstGBPCrvUSDScript)
        returns (address)
    {
        return WstGBPCrvUSDScript.BORROWED();
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

/// @title WstGBPCrvUSDMarketScript
/// @notice Deploys the rate calculator and monetary policy, then creates the wstGBP/crvUSD
///         Llamalend V2 market.
/// @dev `make market-dry INSTANCE=WstGBPCrvUSD`, then `make market-deploy INSTANCE=WstGBPCrvUSD`.
///
///      Set WSGEM_ORACLE to reuse the oracle from WstGBPCrvUSDOracleScript rather than deploying a
///      second one. It must be THIS instance's oracle: the wstGBP/tGBP and wstGBP/frxUSD oracles
///      are both rejected by `_assertOracleExtra`, which is the only place that confusion can be
///      caught. The resulting market has a zero borrow cap until a Curve DAO vote lifts it, and
///      that vote is separate from every other instance's.
contract WstGBPCrvUSDMarketScript is WsgemMarketScript, WstGBPCrvUSDScript {
    // The same disambiguations as the oracle script, plus `_preflight`, which the market branch
    // extends with the factory and AMM bounds. Forwarding to that branch is what keeps them.

    function _preflight() internal view override(WsgemLlamalendScript, WsgemMarketScript) {
        WsgemMarketScript._preflight();
    }

    function BORROWED()
        public
        pure
        override(WsgemLlamalendConfig, WstGBPCrvUSDScript)
        returns (address)
    {
        return WstGBPCrvUSDScript.BORROWED();
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
