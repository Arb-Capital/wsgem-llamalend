// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice A wsgem price feed that can be driven into every state the real one reaches.
/// @dev The real feed sits behind an upgradeable proxy, so "unreadable" is as much a state as
///      "paused" -- an implementation swap can turn `read()` into a revert or into something that
///      does not return a word at all. Both are modelled here, because the shims are required to
///      absorb them rather than propagate them into a lending market.
contract MockPip {
    enum Mode {
        NORMAL,
        REVERTING,
        SHORT_RETURN,
        LONG_RETURN,
        GAS_BOMB,
        RETURNDATA_BOMB
    }

    uint256 public price;
    Mode public mode;

    constructor(uint256 price_) {
        price = price_;
    }

    /// @notice Publish a new NAV. `0` is how the real feed signals a pause.
    function poke(uint256 price_) external {
        price = price_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function read() external view returns (uint256) {
        Mode m_ = mode;
        if (m_ == Mode.NORMAL) return price;
        if (m_ == Mode.REVERTING) revert("pip: unreadable");

        if (m_ == Mode.GAS_BOMB) {
            // A hostile implementation swap that burns whatever the caller forwards. The shims
            // must cap the gas they hand over, or this bricks every market read path.
            uint256 acc_;
            while (true) acc_ = uint256(keccak256(abi.encode(acc_)));
        }

        uint256 p_ = price;
        if (m_ == Mode.SHORT_RETURN) {
            assembly {
                mstore(0x00, p_)
                return(0x00, 0x10) // 16 bytes -- less than one word
            }
        }
        if (m_ == Mode.RETURNDATA_BOMB) {
            // One mebibyte. Building it costs ~2.2M gas of memory expansion, far past any sane
            // read cap, so a gas-capped caller sees this fail exactly like a gas bomb.
            assembly {
                mstore(0x00, p_)
                return(0x00, 0x100000)
            }
        }
        assembly {
            mstore(0x00, p_)
            mstore(0x20, p_)
            return(0x00, 0x40) // two words -- more than declared
        }
    }
}

/// @notice Minimal 18-decimal gem.
contract MockGem {
    uint8 public decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

/// @notice The subset of a wsgem the shims read.
/// @dev `gem`, `pip` and `act` are immutable on the real wrapper, which is what licenses the shims
///      to cache `pip` at construction. They are immutable here too so a test cannot accidentally
///      rely on behaviour the real token does not have.
contract MockWsgem {
    uint256 internal constant WAD = 1e18;

    address public immutable gem;
    address public immutable pip;
    address public immutable act;
    uint8 public immutable decimals;

    /// @notice Redemption spread, WAD-scaled. Zero by default so price expectations stay exact;
    ///         tests that exercise the spread set it explicitly. The real wrapper's spread is
    ///         adjustable too, though not in normal operation.
    /// @dev Packed beside `quoteOverride` so the override check adds one warm, not one cold,
    ///      SLOAD to `burncost()` relative to the real wrapper -- keeps the gas bench honest.
    uint128 public fee;

    /// @notice When nonzero, `burncost()` returns this outright, without reading the pip.
    /// @dev Models an Act implementation swap that quotes a price the pip never published --
    ///      the quote's last hop is an upgradeable proxy on the live system, so a quote that
    ///      diverges from the pause signal is reachable there. The oracle must treat the pip,
    ///      not the quote, as the pause authority; see the test that pins that decision.
    uint128 public quoteOverride;

    constructor(address gem_, address pip_, uint8 decimals_) {
        gem = gem_;
        pip = pip_;
        act = address(0xAC7);
        decimals = decimals_;
    }

    function setFee(uint256 fee_) external {
        // casting to 'uint128' is safe because the spread is at most WAD
        // forge-lint: disable-next-line(unsafe-typecast)
        fee = uint128(fee_);
    }

    function setQuoteOverride(uint256 quote_) external {
        // casting to 'uint128' is safe because tests override with NAV-scale values
        // forge-lint: disable-next-line(unsafe-typecast)
        quoteOverride = uint128(quote_);
    }

    function navprice() external view returns (uint256) {
        return MockPip(pip).read();
    }

    /// @notice What one wsgem redeems for: the NAV net of the spread.
    /// @dev Reads the pip raw and replays a short return as a short return, rather than making a
    ///      typed call that would fold it into a revert -- so the oracle's own returndata-length
    ///      guard stays reachable from the suite. Every other feed failure mode arrives in its
    ///      natural shape: a revert propagates, and the bombs exhaust the forwarded gas here.
    function burncost() external view returns (uint256) {
        if (quoteOverride != 0) return quoteOverride;

        (bool ok_, bytes memory ret_) = pip.staticcall(abi.encodeWithSignature("read()"));
        require(ok_, "wsgem: pip unreadable");
        if (ret_.length < 32) {
            assembly ("memory-safe") {
                return(add(ret_, 0x20), mload(ret_))
            }
        }

        // Overflow-safe: the suite deliberately drives the NAV into regions where `nav * WAD`
        // wraps. With no spread the quote IS the NAV, exactly; at a 100% spread it is zero, like
        // the live wrapper's; with one in between, fall back to a divide-first order out where a
        // wei of rounding is beneath notice.
        uint256 nav_  = abi.decode(ret_, (uint256));
        uint256 keep_ = WAD - fee;
        if (keep_ == WAD) return nav_;
        if (keep_ == 0) return 0;
        if (nav_ > type(uint256).max / keep_) return (nav_ / WAD) * keep_;
        return (nav_ * keep_) / WAD;
    }
}
