// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice A Chainlink push feed that can be driven into every state the real one reaches.
/// @dev The consumer address is an `EACAggregatorProxy`, so the same "unreadable is a state, not an
///      error" reasoning that governs `MockPip` applies here: Chainlink can repoint the proxy, and a
///      broken or mid-migration implementation can revert, return a truncated round, or burn gas.
///      All of those are modelled, because the FX oracle is required to absorb them into a freeze
///      rather than propagate them into a lending market.
///
///      `answer` is `int256` on the real interface and CAN be zero or negative on a broken feed, so
///      it is signed here too -- a mock that could only hold positive answers would make the
///      oracle's sign check untestable.
contract MockChainlinkFeed {
    enum Mode {
        NORMAL,
        REVERTING,
        SHORT_RETURN,
        GAS_BOMB,
        RETURNDATA_BOMB
    }

    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals;
    Mode public mode;

    constructor(int256 answer_, uint8 decimals_) {
        answer    = answer_;
        decimals  = decimals_;
        updatedAt = block.timestamp;
    }

    /// @notice Publish a round now.
    function set(int256 answer_) external {
        answer    = answer_;
        updatedAt = block.timestamp;
    }

    /// @notice Publish a round stamped at an arbitrary time -- how staleness is driven.
    function setAt(int256 answer_, uint256 updatedAt_) external {
        answer    = answer_;
        updatedAt = updatedAt_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Mode m_ = mode;
        if (m_ == Mode.REVERTING) revert("feed: unreadable");

        if (m_ == Mode.GAS_BOMB) {
            uint256 acc_;
            while (true) acc_ = uint256(keccak256(abi.encode(acc_)));
        }

        if (m_ == Mode.SHORT_RETURN) {
            // Four words where the interface declares five: the shape a mismatched aggregator
            // returns, and the reason the oracle checks `returndatasize` rather than trusting the
            // decode.
            int256 a_ = answer;
            uint256 u_ = updatedAt;
            assembly {
                mstore(0x00, 1)
                mstore(0x20, a_)
                mstore(0x40, u_)
                mstore(0x60, u_)
                return(0x00, 0x80)
            }
        }

        if (m_ == Mode.RETURNDATA_BOMB) {
            // One mebibyte, which costs far past any sane read cap to build -- so a gas-capped
            // caller sees this fail exactly like a gas bomb.
            assembly {
                return(0x00, 0x100000)
            }
        }

        return (1, answer, updatedAt, updatedAt, 1);
    }
}

// --- Static stand-ins, for tests that need a contract at a FIXED address ------------------------
//
// `vm.etch` copies runtime code and nothing else, so a mock that keeps its configuration in storage
// arrives at the target address configured with zeros. These carry no state at all: every answer is
// in the code, so etching one is enough. They exist for the tests that must run against the
// production scripts' hardcoded addresses, which cannot be pointed anywhere else -- the config
// getters are `pure`.

/// @notice An 18-decimal token, and nothing else.
contract StaticDecimals18 {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice A always-fresh 8-decimal Chainlink feed at a fixed sterling rate.
contract StaticGbpUsdFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1.34714e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice A always-fresh 8-decimal Chainlink feed at a fixed near-dollar rate.
contract StaticStableFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 0.99987e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice A Curve-style WAD aggregator at a fixed near-dollar rate.
contract StaticStableAggregator {
    function price() external pure returns (uint256) {
        return 0.99992e18;
    }
}

/// @notice A Curve-style WAD `price()` aggregator for the borrowed token.
/// @dev Curve's crvUSD aggregator is a plain Vyper contract with no publication time, so there is
///      no staleness mode here -- only the shapes a contract can fail in. It is expensive to read
///      on mainnet (about 117k gas cold, walking every pool it averages), which is why `GAS_BOMB`
///      matters: the oracle's cap for this leg is deliberately loose and still has to bound it.
contract MockStablePriceAggregator {
    enum Mode {
        NORMAL,
        REVERTING,
        SHORT_RETURN,
        GAS_BOMB
    }

    uint256 public stored;
    Mode public mode;

    constructor(uint256 price_) {
        stored = price_;
    }

    function set(uint256 price_) external {
        stored = price_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function price() external view returns (uint256) {
        Mode m_ = mode;
        if (m_ == Mode.REVERTING) revert("aggregator: unreadable");

        if (m_ == Mode.GAS_BOMB) {
            uint256 acc_;
            while (true) acc_ = uint256(keccak256(abi.encode(acc_)));
        }

        uint256 p_ = stored;
        if (m_ == Mode.SHORT_RETURN) {
            assembly {
                mstore(0x00, p_)
                return(0x00, 0x10) // 16 bytes -- less than one word
            }
        }
        return p_;
    }
}
