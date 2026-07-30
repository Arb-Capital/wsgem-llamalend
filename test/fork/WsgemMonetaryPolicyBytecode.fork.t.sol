// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                 from "forge-std/Test.sol";
import {IHyperbolicDynamicMP} from "../../src/interfaces/IMonetaryPolicy.sol";

/// @notice Proves the vendored monetary-policy bytecode is the contract Curve itself deployed.
/// @dev The market deploy hands `LendFactory.create` a contract this repo did not compile, so the
///      artefact has to be verifiable rather than merely reproducible from a URL. Curve's own
///      sDOLA/crvUSD market runs the same contract, so the check is direct: deploy ours with that
///      market's constructor arguments and compare the resulting runtime code, byte for byte,
///      against the live deployment.
///
///      Vyper appends immutables to the end of the runtime code, which is why the arguments have to
///      match — with the same two addresses, the codes must be exactly equal, not merely
///      prefix-equal. See script/bytecode/PROVENANCE.md.
contract WsgemMonetaryPolicyBytecodeForkTest is Test {
    /// @notice Curve's deployed HyperbolicDynamicMP for the sDOLA/crvUSD market.
    address internal constant CURVE_SDOLA_MP = 0xE02C02FCeeF5608762058bFe79BFb4064DcAA7b8;

    address internal constant CURVE_SDOLA_CONTROLLER = 0xC77d97cF01737EB7aCE46cAb7cd9F60eC51a40c0;
    address internal constant CURVE_SDOLA_RATE_CALC  = 0x2BC89Ef5Fa2916bB63960be90B4F224a148450b8;

    // The curve parameters Curve deployed that market with. They are part of neither the runtime
    // code nor the immutables, so they do not affect the comparison -- they are here so the
    // deployment is reproduced exactly as published.
    uint256 internal constant TARGET_UTILIZATION = 0.90e18;
    uint256 internal constant LOW_RATIO          = 0.5e18;
    uint256 internal constant HIGH_RATIO         = 5e18;
    uint256 internal constant RATE_SHIFT         = 0;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envUint("ETH_FORK_BLOCK"));
    }

    function test_curvesDeployedPolicyIsWhereWeThinkItIs() public view {
        assertGt(CURVE_SDOLA_MP.code.length, 0, "no code at the reference deployment");
        assertEq(IHyperbolicDynamicMP(CURVE_SDOLA_MP).CONTROLLER(), CURVE_SDOLA_CONTROLLER);
        assertEq(IHyperbolicDynamicMP(CURVE_SDOLA_MP).RATE_CALCULATOR(), CURVE_SDOLA_RATE_CALC);
    }

    /// @notice The whole justification for vendoring bytecode, in one assertion.
    function test_ourBytecodeReproducesCurvesDeploymentExactly() public {
        bytes memory code_ = abi.encodePacked(
            vm.parseBytes(vm.readFile("script/bytecode/HyperbolicDynamicMP.initcode.hex")),
            abi.encode(
                CURVE_SDOLA_CONTROLLER,
                CURVE_SDOLA_RATE_CALC,
                TARGET_UTILIZATION,
                LOW_RATIO,
                HIGH_RATIO,
                RATE_SHIFT
            )
        );

        address mine_;
        assembly ("memory-safe") {
            mine_ := create(0, add(code_, 0x20), mload(code_))
        }
        require(mine_ != address(0), "monetary policy deploy failed");

        assertEq(
            mine_.code,
            CURVE_SDOLA_MP.code,
            "vendored bytecode does not reproduce Curve's live deployment"
        );
    }
}
