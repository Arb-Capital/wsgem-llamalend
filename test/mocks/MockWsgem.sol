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
    address public immutable gem;
    address public immutable pip;
    address public immutable act;
    uint8 public immutable decimals;

    constructor(address gem_, address pip_, uint8 decimals_) {
        gem = gem_;
        pip = pip_;
        act = address(0xAC7);
        decimals = decimals_;
    }

    function navprice() external view returns (uint256) {
        return MockPip(pip).read();
    }
}
