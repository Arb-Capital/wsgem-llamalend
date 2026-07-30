// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                 from "forge-std/Test.sol";
import {IHyperbolicDynamicMP} from "../src/interfaces/IMonetaryPolicy.sol";

/// @notice Guards the vendored Curve monetary-policy bytecode without needing an RPC.
/// @dev The market deploy hands `LendFactory.create` a contract this repo did not compile. That is
///      only acceptable if the artefact is verifiable, so it is checked twice: here, against the
///      runtime file compiled alongside it, and in test/fork against Curve's own live deployment.
///      This half runs in the default suite so a corrupted, truncated or half-updated file is
///      caught on every push rather than at deploy time.
///
///      See script/bytecode/PROVENANCE.md.
contract WsgemMonetaryPolicyBytecodeTest is Test {
    string internal constant INITCODE_PATH = "script/bytecode/HyperbolicDynamicMP.initcode.hex";
    string internal constant RUNTIME_PATH  = "script/bytecode/HyperbolicDynamicMP.runtime.hex";

    // Curve's sDOLA/crvUSD market -- the published deployment this artefact is checked against.
    address internal constant CURVE_SDOLA_CONTROLLER = 0xC77d97cF01737EB7aCE46cAb7cd9F60eC51a40c0;
    address internal constant CURVE_SDOLA_RATE_CALC  = 0x2BC89Ef5Fa2916bB63960be90B4F224a148450b8;

    uint256 internal constant TARGET_UTILIZATION = 0.90e18;
    uint256 internal constant LOW_RATIO          = 0.5e18;
    uint256 internal constant HIGH_RATIO         = 5e18;
    uint256 internal constant RATE_SHIFT         = 0;

    function _deploy(address controller_, address rateCalculator_) internal returns (address mp_) {
        bytes memory code_ = abi.encodePacked(
            vm.parseBytes(vm.readFile(INITCODE_PATH)),
            abi.encode(controller_, rateCalculator_, TARGET_UTILIZATION, LOW_RATIO, HIGH_RATIO, RATE_SHIFT)
        );
        assembly ("memory-safe") {
            mp_ := create(0, add(code_, 0x20), mload(code_))
        }
        require(mp_ != address(0), "monetary policy deploy failed");
    }

    function test_theInitcodeDeploys() public {
        address mp_ = _deploy(address(0xC0), address(0xCA));
        assertGt(mp_.code.length, 0);
    }

    /// @dev Vyper appends immutables to the end of the runtime code, so a correct deployment is the
    ///      compiled runtime followed by exactly the constructor's immutable words -- here the two
    ///      addresses. Anything else means the two vendored files do not describe the same build.
    function test_theRuntimeMatchesTheCompiledRuntimePlusItsImmutables() public {
        address mp_ = _deploy(CURVE_SDOLA_CONTROLLER, CURVE_SDOLA_RATE_CALC);

        bytes memory expected_ = abi.encodePacked(
            vm.parseBytes(vm.readFile(RUNTIME_PATH)),
            abi.encode(CURVE_SDOLA_CONTROLLER),
            abi.encode(CURVE_SDOLA_RATE_CALC)
        );

        assertEq(mp_.code, expected_, "initcode and runtime files describe different builds");
    }

    /// @dev The reason the controller address has to be predicted before `LendFactory.create`.
    function test_theConstructorBindsItsControllerAndRateCalculator() public {
        address mp_ = _deploy(CURVE_SDOLA_CONTROLLER, CURVE_SDOLA_RATE_CALC);

        assertEq(IHyperbolicDynamicMP(mp_).CONTROLLER(), CURVE_SDOLA_CONTROLLER);
        assertEq(IHyperbolicDynamicMP(mp_).RATE_CALCULATOR(), CURVE_SDOLA_RATE_CALC);
    }

    /// @dev The policy reads its rate calculator through a failure-tolerant raw call and clamps the
    ///      result. Pointed at an address with no code, it must therefore floor rather than revert.
    function test_thePolicyFloorsRatherThanRevertingOnAnAbsentRateCalculator() public {
        address mp_ = _deploy(address(0xC0), address(0xDEAD));
        assertEq(IHyperbolicDynamicMP(mp_).target_rate(), 317_097_920, "MIN_TARGET_RATE");
    }

    /// @dev The parameter values the concrete deployment uses must actually produce a valid curve.
    ///      The constructor asserts this internally, so a bad set fails here rather than mid-deploy.
    function test_theConfiguredCurveParametersAreAccepted() public {
        address mp_ = _deploy(address(0xC0), address(0xCA));
        assertGt(IHyperbolicDynamicMP(mp_).target_apr(), 0);
    }
}
