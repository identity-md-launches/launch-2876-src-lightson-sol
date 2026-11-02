// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LightsOn} from "../src/LightsOn.sol";
import {MockCore, MockSQK} from "./mocks/Mocks.sol";

/// Zero-value CREATE2 of the exact launch init code, as the project factory does it.
contract LaunchCreate2 {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "constructor failed");
    }
}

/// The launch exactly as briefed: Config(core, sqk, genesisTime, station, startRound) =
/// (0x980b…3d44, 0x5501…db60, 1793022600, 36, 1000), deployed by CREATE2 on an empty chain. Only after the
/// deployment are test stand-ins for SqueekCore and SQK etched at the two Sepolia addresses.
abstract contract LightsLaunchFixture is Test {
    address internal constant CORE_ADDR = 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44;
    address internal constant SQK_ADDR = 0x5501E1Fa81Be1c3F49225fa7668DA0245d07Db60;
    uint256 internal constant GEN = 1793022600;
    uint256 internal constant STATION_ = 36;
    uint32 internal constant START = 1000;

    function _launchInitCode() internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(LightsOn).creationCode, abi.encode(CORE_ADDR, SQK_ADDR, GEN, uint256(STATION_), uint32(START))
        );
    }

    function _launch(bytes32 salt) internal returns (LightsOn lights, MockCore core, MockSQK sqk) {
        vm.chainId(11155111);
        LaunchCreate2 f = new LaunchCreate2();
        lights = LightsOn(f.deploy(_launchInitCode(), salt));
        vm.etch(CORE_ADDR, address(new MockCore()).code);
        vm.etch(SQK_ADDR, address(new MockSQK()).code);
        core = MockCore(CORE_ADDR);
        sqk = MockSQK(SQK_ADDR);
    }

    /// 100 s into round r.
    function _warpRound(uint256 r) internal {
        vm.warp(GEN + (r - 1) * 600 + 100);
    }
}
