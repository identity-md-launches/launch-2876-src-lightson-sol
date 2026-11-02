// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LightsOn} from "../src/LightsOn.sol";
import {MockCore, MockSQK} from "./mocks/Mocks.sol";

/// Test-only rehearsal of the factory's zero-value CREATE2, without initialization calls.
contract LightsLaunchFactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "constructor failed");
    }
}

/// No forks, RPC, environment variables or launch infrastructure are needed by these tests.
contract LightsLaunchTest is Test {
    address internal constant CORE = 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44;
    address internal constant SQK = 0x5501E1Fa81Be1c3F49225fa7668DA0245d07Db60;
    uint256 internal constant G = 1793022600;
    bytes32 internal constant SALT = keccak256("LightsOn launch rehearsal");

    LightsLaunchFactoryProbe internal factory;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(G + 1000 * 600 + 100); // round 1001
        factory = new LightsLaunchFactoryProbe();
    }

    function _config() internal pure returns (LightsOn.Config memory) {
        return LightsOn.Config({core: CORE, sqk: SQK, genesisTime: G, station: 36, startRound: 1000});
    }

    function _initCode() internal pure returns (bytes memory) {
        // The manifest supplies one static word per Config field in declaration order.
        return abi.encodePacked(type(LightsOn).creationCode, abi.encode(CORE, SQK, G, uint256(36), uint32(1000)));
    }

    function _deploy() internal returns (LightsOn) {
        return LightsOn(factory.deploy(_initCode(), SALT));
    }

    function test_factoryDeploysExactConfigOnEmptyChain() public {
        assertEq(CORE.code.length, 0, "no core during construction");
        assertEq(SQK.code.length, 0, "no token during construction");
        assertEq(abi.encode(_config()), abi.encode(CORE, SQK, G, uint256(36), uint32(1000)));
        bytes memory code = _initCode();
        assertLe(code.length, 49_152, "EIP-3860 init code limit");
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), SALT, keccak256(code)))))
        );

        LightsOn lights = _deploy();
        assertEq(address(lights), predicted);
        assertEq(address(lights).balance, 0);
        assertEq(address(lights.CORE()), CORE);
        assertEq(address(lights.SQK()), SQK);
        assertEq(lights.G(), G);
        assertEq(lights.STATION(), 36);
        assertEq(lights.START_ROUND(), 1000);
        assertEq(lights.getWalker().cursor, 1000);
        assertEq(lights.nightCount(), 0);
        assertEq(lights.betCount(), 0);
        assertFalse(lights.voided());
        assertEq(lights.poke(1), 0, "a missing core is handled on use");
        assertEq(lights.getWalker().cursor, 1000);
    }

    function test_factoryDeploymentRuntimeMeetsLaunchFloor() public {
        bytes memory code = address(_deploy()).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "EIP-170 runtime limit");
        // Match the protected floor: skip PUSH data and unreachable constant tails.
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }

    function test_factoryHasNoOwnerAdminOrInitializationSurface() public {
        LightsOn lights = _deploy();
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeWithSignature("owner()");
        calls[1] = abi.encodeWithSignature("admin()");
        calls[2] = abi.encodeWithSignature("pause()");
        calls[3] = abi.encodeWithSignature("transferOwnership(address)", address(factory));
        calls[4] = abi.encodeWithSignature("initialize(address)", address(factory));
        calls[5] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(factory), bytes(""));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(lights).call(calls[i]);
            assertFalse(ok, "factory gained an administrative entry point");
        }
    }

    /// Install existing test fixtures only after deployment at the configured dependency addresses.
    function _installMocks() internal returns (MockCore core, MockSQK sqk) {
        vm.etch(CORE, address(new MockCore()).code);
        vm.etch(SQK, address(new MockSQK()).code);
        core = MockCore(CORE);
        sqk = MockSQK(SQK);
    }

    function test_launchConfigSettlesAndPaysTheNextRide() public {
        LightsOn lights = _deploy();
        (MockCore core, MockSQK sqk) = _installMocks();
        core.setActiveRange(965, 966); // earlier ride must not become a night of this game
        core.setSettled(1000);
        assertTrue(lights.isIdle(999));
        assertTrue(lights.isIdle(1000));

        sqk.mint(address(this), 100e18);
        sqk.approve(address(lights), 100e18);
        uint256 winner = lights.betUntil(2, 100e18, 1001);
        address loser = makeAddr("launch test bettor");
        sqk.mint(loser, 100e18);
        vm.startPrank(loser);
        sqk.approve(address(lights), 100e18);
        uint256 losingBet = lights.betUntil(9, 100e18, 1001);
        vm.stopPrank();

        core.setActiveRange(1002, 1004); // departure 1002, bulbs 1 and 2, blackout 1005-1006
        core.setSettled(1006);
        vm.warp(G + 1006 * 600 + 100);
        assertEq(lights.poke(1), 1);
        assertEq(lights.settle(3), 3);
        assertEq(lights.nightCount(), 1);
        assertEq(lights.getNight(0).start, 1002);
        assertEq(lights.getNight(0).spanEnd, 1006);
        assertEq(lights.lit(0), 2);
        assertEq(lights.getNight(0).burned, 2e18);

        uint256[] memory ids = new uint256[](2);
        ids[0] = winner;
        ids[1] = losingBet;
        vm.prank(address(factory)); // anyone can collect; the factory receives nothing
        assertEq(lights.claim(ids), 2);
        assertEq(sqk.balanceOf(address(this)), 198e18);
        assertEq(sqk.balanceOf(loser), 0);
        assertEq(sqk.balanceOf(address(factory)), 0);
        assertEq(sqk.totalBurned(), 2e18);
        assertEq(sqk.balanceOf(address(lights)), 0);
    }

    function test_laterDeploymentStillWalksHistoryFrom1001() public {
        vm.warp(G + 1010 * 600 + 100);
        LightsOn lights = _deploy();
        (MockCore core,) = _installMocks();
        core.setActiveRange(965, 966);
        core.setActiveRange(1001, 1003);
        core.setSettled(1010);
        assertEq(lights.getWalker().cursor, 1000);
        lights.poke(1);
        assertEq(lights.getWalker().cursor, 1010);
        assertEq(lights.nightCount(), 1);
        assertEq(lights.getNight(0).start, 1001);
        assertEq(lights.lit(0), 2);
    }

    /// Imported audit aaf8dcee: valid-shaped false records cannot be distinguished from real activity.
    /// Changing the mock models what the external core's administrator could serve after an upgrade;
    /// it does not demonstrate any unprivileged way to change the real core.
    function test_wellFormedCoreHistoryIsAnExternalTrustAssumption() public {
        LightsOn lights = _deploy();
        (MockCore core,) = _installMocks();
        core.setSettled(1006);
        vm.warp(G + 1006 * 600 + 100);
        uint256 snapshot = vm.snapshotState();
        lights.poke(1);
        assertEq(lights.nightCount(), 0, "quiet history lights nothing");
        assertTrue(vm.revertToState(snapshot));

        // Same settled round, but a replacement core reports work during the quiet rounds.
        core.setActiveRange(1002, 1004);
        (uint256 cert, uint256[] memory ids) = lights.readCorePage(1000, 1006);
        assertEq(cert, 1006);
        assertEq(ids.length, 3);
        lights.poke(1);
        assertEq(lights.nightCount(), 1);
        assertEq(lights.lit(0), 2, "well-formed records determine the result");
        assertFalse(lights.stalled(), "valid-shaped false history is not an unreadable-core stall");
    }
}
