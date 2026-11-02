// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LightsOn} from "../src/LightsOn.sol";
import {MockCore, MockSQK} from "./mocks/Mocks.sol";
import {LightsLaunchFixture} from "./LightsLaunchFixture.sol";

/// An SQK stand-in that can answer `false` instead of moving tokens, or call back into the game while it moves them.
contract HostileSQK {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public mode; // 1: transferFrom returns false, 2: transfer returns false, 3: re-enter on transfer(From)
    bytes public reentry; // call made into `target` while moving tokens
    address public target;
    bytes public reentryError; // what the re-entering call reverted with

    function setMode(uint8 m) external {
        mode = m;
    }

    function setReentry(address t, bytes calldata data) external {
        target = t;
        reentry = data;
    }

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        if (mode == 2) return false;
        _reenter();
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        if (mode == 1) return false;
        _reenter();
        allowance[from][msg.sender] -= v;
        balanceOf[from] -= v;
        balanceOf[to] += v;
        return true;
    }

    function burn(uint256 v) external {
        balanceOf[msg.sender] -= v;
    }

    function _reenter() internal {
        if (mode != 3) return;
        (bool ok, bytes memory ret) = target.call(reentry);
        require(!ok, "re-entry was allowed");
        reentryError = ret;
    }
}

/// Failure paths of the launched game (station 36, start round 1000, the Sepolia addresses), and the edges of
/// every fixed limit. Each refused call must leave nothing behind.
contract LightsLaunchFailuresTest is LightsLaunchFixture {
    LightsOn internal lights;
    MockCore internal core;
    MockSQK internal sqk;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        _warpRound(1001);
        (lights, core, sqk) = _launch(keccak256("launch failures"));
        core.setSettled(1000);
        _fund(alice);
        _fund(bob);
    }

    function _fund(address a) internal {
        sqk.mint(a, 100_000e18);
        vm.prank(a);
        sqk.approve(address(lights), type(uint256).max);
    }

    function _bet(address who, uint8 bulb, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return lights.bet(bulb, amount);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    /// Advance to 100 s into round r with the core settled through r - 1.
    function _to(uint256 r) internal {
        _warpRound(r);
        core.setSettled(uint64(r - 1));
    }

    // ------------------------------------------------------------ constructor

    function _cfg(address c, address s, uint256 station) internal pure returns (LightsOn.Config memory) {
        return LightsOn.Config({core: c, sqk: s, genesisTime: GEN, station: station, startRound: START});
    }

    function test_constructorRejectsZeroAddressesAndStationOutOfRange() public {
        vm.expectRevert(LightsOn.BadConfig.selector);
        new LightsOn(_cfg(address(0), SQK_ADDR, 36));
        vm.expectRevert(LightsOn.BadConfig.selector);
        new LightsOn(_cfg(CORE_ADDR, address(0), 36));
        vm.expectRevert(LightsOn.BadConfig.selector);
        new LightsOn(_cfg(CORE_ADDR, SQK_ADDR, 3));
        vm.expectRevert(LightsOn.BadConfig.selector);
        new LightsOn(_cfg(CORE_ADDR, SQK_ADDR, 65));
        vm.expectRevert(LightsOn.BadConfig.selector);
        new LightsOn(_cfg(CORE_ADDR, SQK_ADDR, 0));
        // the edges are allowed (a 64-round night still fits the 64-bit stops mask)
        assertEq(new LightsOn(_cfg(CORE_ADDR, SQK_ADDR, 4)).STATION(), 4);
        assertEq(new LightsOn(_cfg(CORE_ADDR, SQK_ADDR, 64)).STATION(), 64);
    }

    function test_launchedConstantsAreTheFixedLimits() public view {
        assertEq(lights.MIN_BET(), 10e18);
        assertEq(lights.MAX_BET(), 10_000e18);
        assertEq(lights.MAX_BULB(), 24);
        assertEq(lights.BURN_BPS(), 200);
        assertEq(lights.STATION(), 36);
        assertEq(lights.START_ROUND(), 1000);
        assertEq(lights.G(), GEN);
        assertEq(lights.roundAt(GEN - 1), 0);
        assertEq(lights.roundAt(GEN), 1);
        assertEq(lights.roundAt(GEN + 1000 * 600 - 1), 1000);
        assertEq(lights.roundAt(GEN + 1000 * 600), 1001);
    }

    // ------------------------------------------------------------ bet limits

    function test_betRejectsBulbOutsideOneToTwentyFour() public {
        vm.startPrank(alice);
        vm.expectRevert(LightsOn.BadBulb.selector);
        lights.bet(0, 100e18);
        vm.expectRevert(LightsOn.BadBulb.selector);
        lights.bet(25, 100e18);
        vm.expectRevert(LightsOn.BadBulb.selector);
        lights.bet(255, 100e18);
        vm.expectRevert(LightsOn.BadBulb.selector);
        lights.betUntil(0, 100e18, type(uint256).max);
        vm.stopPrank();
        assertEq(lights.betCount(), 0);
        assertEq(sqk.balanceOf(alice), 100_000e18);
    }

    function test_betRejectsAmountOutsideLimits() public {
        vm.startPrank(alice);
        vm.expectRevert(LightsOn.BadAmount.selector);
        lights.bet(3, 0);
        vm.expectRevert(LightsOn.BadAmount.selector);
        lights.bet(3, 10e18 - 1);
        vm.expectRevert(LightsOn.BadAmount.selector);
        lights.bet(3, 10_000e18 + 1);
        vm.expectRevert(LightsOn.BadAmount.selector);
        lights.bet(3, type(uint256).max);
        vm.stopPrank();
        assertEq(lights.betCount(), 0);
    }

    /// The exact edges are accepted: bulb 1 and 24, 10 SQK and 10,000 SQK.
    function test_betAcceptsExactEdges() public {
        assertEq(_bet(alice, 1, 10e18), 0);
        assertEq(_bet(bob, 24, 10_000e18), 1);
        assertEq(lights.getBet(0).stake, 10e18);
        assertEq(lights.getBet(1).stake, 10_000e18);
        assertEq(lights.getBet(1).bulb, 24);
        assertEq(sqk.balanceOf(address(lights)), 10_010e18);
    }

    /// Fuzzed: any amount outside [10, 10,000] SQK and any bulb outside [1, 24] is refused with no state change.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_outOfRangeBetsAreRefused(uint8 bulb, uint256 amount) public {
        bool badBulb = bulb == 0 || bulb > 24;
        bool badAmount = amount < 10e18 || amount > 10_000e18;
        if (!badBulb && !badAmount) amount = bound(amount, 10_000e18 + 1, type(uint256).max);
        vm.expectRevert(badBulb ? LightsOn.BadBulb.selector : LightsOn.BadAmount.selector);
        vm.prank(alice);
        lights.bet(bulb, amount);
        assertEq(lights.betCount(), 0);
        assertEq(sqk.balanceOf(alice), 100_000e18);
    }

    function test_betBeforeGenesisRefusedUntilTheGuardBand() public {
        vm.warp(GEN - 61); // effective time GEN - 1: before round 1
        vm.prank(alice);
        vm.expectRevert(LightsOn.BeforeGenesis.selector);
        lights.bet(5, 100e18);
        vm.warp(GEN - 60); // effective time GEN: round 1
        assertEq(lights.effectiveRound(), 1);
        assertEq(_bet(alice, 5, 100e18), 0);
        assertEq(lights.getBet(0).betRound, 1);
    }

    function test_guardBandMovesTheLastSixtySecondsToTheNextRound() public {
        vm.warp(GEN + 1000 * 600 + 539);
        assertEq(lights.effectiveRound(), 1001);
        vm.warp(GEN + 1000 * 600 + 540);
        assertEq(lights.currentRound(), 1001);
        assertEq(lights.effectiveRound(), 1002);
    }

    function test_betUntilRefusesAfterItsLastRound() public {
        uint256 n = lights.effectiveRound();
        vm.prank(alice);
        vm.expectRevert(LightsOn.TooLate.selector);
        lights.betUntil(5, 100e18, n - 1);
        vm.prank(alice);
        vm.expectRevert(LightsOn.TooLate.selector);
        lights.betUntil(5, 100e18, 0);
        vm.prank(alice);
        assertEq(lights.betUntil(5, 100e18, n), 0);
    }

    function test_secondBetInTheSameRideRefused() public {
        _bet(alice, 5, 100e18);
        _to(1003);
        vm.prank(alice);
        vm.expectRevert(LightsOn.AlreadyBet.selector);
        lights.bet(6, 100e18);
        vm.prank(alice);
        vm.expectRevert(LightsOn.AlreadyBet.selector);
        lights.betUntil(6, 100e18, type(uint256).max);
        assertEq(lights.betCount(), 1);
    }

    /// After the ride the first bet joined has ended (blackout read), the same wallet may bet on the next one.
    function test_nextRideAcceptsANewBetFromTheSameWallet() public {
        _bet(alice, 1, 100e18);
        core.setActiveRange(1002, 1004);
        _to(1007); // 1005, 1006 quiet: blackout
        assertEq(_bet(alice, 2, 100e18), 1);
        assertEq(lights.nightCount(), 1);
        assertEq(lights.getNight(0).start, 1002);
    }

    // ------------------------------------------------------------ token failures

    function _hostileLaunch() internal returns (HostileSQK h) {
        vm.etch(SQK_ADDR, address(new HostileSQK()).code);
        h = HostileSQK(SQK_ADDR);
        h.mint(alice, 1_000e18);
        h.mint(bob, 1_000e18);
        vm.prank(alice);
        h.approve(address(lights), type(uint256).max);
        vm.prank(bob);
        h.approve(address(lights), type(uint256).max);
    }

    function test_betRevertsWhenTokenReturnsFalse() public {
        HostileSQK h = _hostileLaunch();
        h.setMode(1);
        vm.prank(alice);
        vm.expectRevert(LightsOn.TransferFailed.selector);
        lights.bet(5, 100e18);
        assertEq(lights.betCount(), 0, "no bet without its stake");
        assertEq(lights.lastBet(alice), 0);
    }

    /// A payout the token refuses reverts the collect, and the bet stays collectable for later.
    function test_claimRevertsWhenTokenRefusesAndStaysCollectable() public {
        HostileSQK h = _hostileLaunch();
        vm.prank(alice);
        lights.bet(2, 100e18);
        // He never runs; a week later the game can be ended and the bet refunded.
        _to(1000 + 1008 + 3);
        lights.poke(10);
        assertTrue(lights.asleepTooLong());
        lights.void();
        h.setMode(2);
        vm.expectRevert(LightsOn.TransferFailed.selector);
        lights.claim(_ids(0));
        assertEq(lights.getBet(0).status, lights.WAITING());
        h.setMode(0);
        assertEq(lights.claim(_ids(0)), 1);
        assertEq(h.balanceOf(alice), 1_000e18);
        assertEq(lights.getBet(0).status, lights.REFUNDED());
    }

    function test_reentryFromTheTokenIsRefused() public {
        HostileSQK h = _hostileLaunch();
        h.setMode(3);
        h.setReentry(address(lights), abi.encodeCall(LightsOn.bet, (7, 100e18)));
        vm.prank(alice);
        lights.bet(5, 100e18);
        assertEq(bytes4(h.reentryError()), LightsOn.Reentrant.selector);
        assertEq(lights.betCount(), 1);

        h.setReentry(address(lights), abi.encodeCall(LightsOn.settle, (10)));
        vm.prank(bob);
        lights.bet(5, 100e18);
        assertEq(bytes4(h.reentryError()), LightsOn.Reentrant.selector);

        // a collect that re-enters claim for the same bet can't pay twice
        _to(1000 + 1008 + 3);
        lights.poke(10);
        h.setMode(0);
        lights.void();
        h.setMode(3);
        h.setReentry(address(lights), abi.encodeCall(LightsOn.claim, (_ids(0))));
        assertEq(lights.claim(_ids(0)), 1);
        assertEq(bytes4(h.reentryError()), LightsOn.Reentrant.selector);
        assertEq(h.balanceOf(alice), 1_000e18, "refunded exactly once");
    }

    // ------------------------------------------------------------ core failures

    function test_readCorePageRejectsBrokenPagesAndThePokeReadsNothing() public {
        core.setActiveRange(1002, 1004);
        _to(1008);
        core.setEvil(1); // certifies past `through`
        vm.expectRevert(LightsOn.BadPage.selector);
        lights.readCorePage(1000, 1007);
        assertEq(lights.poke(5), 0);
        assertEq(lights.getWalker().cursor, 1000);
        core.setEvil(2); // records out of order
        vm.expectRevert(LightsOn.BadPage.selector);
        lights.readCorePage(1000, 1007);
        assertEq(lights.poke(5), 0);
        // bets and collects still work against a broken core
        assertEq(_bet(alice, 3, 100e18), 0);
        assertEq(lights.claim(_ids(0)), 0);
        core.setEvil(0);
        assertEq(lights.poke(5), 1);
        assertEq(lights.nightCount(), 1);
        assertEq(lights.lit(0), 2);
    }

    function test_isIdleRefusesUnsettledRoundsAndRoundZero() public {
        vm.expectRevert(LightsOn.NotSettled.selector);
        lights.isIdle(0);
        vm.expectRevert(LightsOn.NotSettled.selector);
        lights.isIdle(1001);
        assertTrue(lights.isIdle(1000));
        core.setReverting(true);
        vm.expectRevert(LightsOn.NotSettled.selector);
        lights.isIdle(1000);
    }

    function test_stallChecksNeedEnoughGas() public {
        vm.expectRevert(LightsOn.NeedMoreGas.selector);
        lights.flagStall{gas: 1_500_000}();
        vm.expectRevert(LightsOn.NeedMoreGas.selector);
        lights.stalled{gas: 1_500_000}();
    }

    function test_flagStallRefusedWhileHealthyOrBriefOutage() public {
        vm.expectRevert(LightsOn.NotStalled.selector);
        lights.flagStall();
        core.setReverting(true);
        _warpRound(1000 + 145); // last ended 1144 = cursor + 144: not yet
        vm.expectRevert(LightsOn.NotStalled.selector);
        lights.flagStall();
        _warpRound(1000 + 146);
        lights.flagStall();
        assertGt(lights.stallFlaggedAt(), 0);
        assertTrue(lights.stallUnreadable());
    }

    function test_voidRefusedTooEarlyThenAllowedAfterADay() public {
        _bet(alice, 4, 100e18);
        vm.expectRevert(LightsOn.TooEarly.selector);
        lights.void();
        core.setReverting(true);
        _warpRound(1000 + 146);
        lights.flagStall();
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(LightsOn.TooEarly.selector);
        lights.void();
        vm.warp(block.timestamp + 1);
        lights.void();
        assertTrue(lights.voided());
        // after the end: no bet, no flag, no second void; the waiting bet is refunded once
        vm.prank(bob);
        vm.expectRevert(LightsOn.IsVoided.selector);
        lights.bet(4, 100e18);
        vm.expectRevert(LightsOn.IsVoided.selector);
        lights.flagStall();
        vm.expectRevert(LightsOn.IsVoided.selector);
        lights.void();
        assertEq(lights.poke(5), 0);
        assertEq(lights.settle(5), 0);
        assertEq(lights.claim(_ids(0)), 1);
        assertEq(sqk.balanceOf(alice), 100_000e18);
        assertEq(lights.claim(_ids(0)), 0);
    }

    /// The core recovers after the flag: void clears the flag instead of ending the game.
    function test_voidClearsAFlagWhoseStallEnded() public {
        core.setReverting(true);
        _warpRound(1000 + 146);
        lights.flagStall();
        vm.warp(block.timestamp + 1 days);
        core.setReverting(false);
        core.setSettled(uint64(lights.currentRound() - 1));
        vm.expectEmit(address(lights));
        emit LightsOn.StallCleared();
        lights.void();
        assertFalse(lights.voided());
        assertEq(lights.stallFlaggedAt(), 0);
        assertEq(lights.stallMark(), 0);
        assertFalse(lights.stallUnreadable());
    }

    /// A closed ride that nobody settled blocks the way out until it is settled, so it pays as it ended.
    function test_voidAfterSleepNeedsClosedRidesSettledFirst() public {
        _bet(alice, 1, 100e18);
        _bet(bob, 9, 100e18);
        core.setActiveRange(1002, 1004);
        core.setSettled(1006);
        _warpRound(1006 + 1010);
        core.setSettled(uint64(1006 + 1009));
        lights.poke(10);
        assertEq(lights.nightCount(), 1);
        assertTrue(lights.asleepTooLong());
        vm.expectRevert(LightsOn.SettleFirst.selector);
        lights.void();
        lights.settle(10);
        lights.void();
        assertTrue(lights.voided());
        uint256[] memory ids = new uint256[](2);
        ids[1] = 1;
        assertEq(lights.claim(ids), 2);
        assertEq(sqk.balanceOf(alice), 100_000e18 + 98e18, "the won ride pays as it ended");
        assertEq(sqk.balanceOf(bob), 100_000e18 - 100e18);
        assertEq(sqk.balanceOf(address(lights)), 0);
    }

    /// A bet id that doesn't exist, a bet not settled yet, and an empty list collect nothing and never revert.
    function test_claimSkipsUnknownAndUnreadyBets() public {
        assertEq(lights.claim(new uint256[](0)), 0);
        assertEq(lights.claim(_ids(0)), 0);
        assertEq(lights.claim(_ids(type(uint256).max)), 0);
        _bet(alice, 3, 100e18);
        assertEq(lights.claim(_ids(0)), 0, "waiting bet");
        (,,, uint256 pay, bool ready) = lights.betOutcome(0);
        assertEq(pay, 100e18);
        assertFalse(ready);
        assertEq(sqk.balanceOf(address(lights)), 100e18);
    }

    /// A false start rolls; losers' stakes ride in the bonus pot and can't be collected while the game runs.
    function test_rolledStakeIsNotCollectableUntilTheGameEnds() public {
        _bet(alice, 3, 100e18);
        core.setActive(1002, 500); // departure only: a false start
        _to(1006);
        lights.poke(5);
        lights.settle(10);
        assertEq(lights.getNight(0).result, 3); // ROLLED
        assertEq(lights.bonusPot(), 100e18);
        assertEq(lights.claim(_ids(0)), 0);
        (,,, uint256 pay, bool ready) = lights.betOutcome(0);
        assertEq(pay, 0);
        assertFalse(ready);
    }

    // ------------------------------------------------------------ the unreadable stall counts from the last full read

    /// Three pages of running rounds; the second page can't be read. The poke reads the first page and stops: that is
    /// not a full read, so `readThrough` stays unset and the stall counts from the cursor the first page left. A bet
    /// during the outage reads state() fine but its page fails, so it records nothing either.
    function test_aPageThatFailsMidPokeRecordsNoRead() public {
        core.setActiveRange(1001, 1040);
        _to(1100);
        vm.mockCallRevert(CORE_ADDR, abi.encodeWithSelector(MockCore.roundPage.selector, uint64(1016)), "bad page");
        assertEq(lights.poke(4), 1, "one page came, the next failed");
        assertEq(lights.getWalker().cursor, 1016);
        assertEq(lights.readThrough(), 0, "a failed page is not a full read");
        _to(1120);
        _bet(alice, 5, 100e18);
        assertEq(lights.readThrough(), 0, "the bet's page failed too");
        assertEq(lights.getWalker().cursor, 1016);

        _to(1016 + 145); // last ended = cursor + 144
        assertFalse(lights.stalled());
        vm.expectRevert(LightsOn.NotStalled.selector);
        lights.flagStall();
        _to(1016 + 146);
        lights.flagStall();
        assertTrue(lights.stallUnreadable(), "state() answers, the page does not: the unreadable kind");
        assertEq(lights.stallMark(), 1016, "counted from the cursor, the last round actually read");

        // the page is served again: the flag does not survive, and a full read records the core's settled round
        vm.clearMockedCalls();
        vm.warp(block.timestamp + 1 days);
        core.setSettled(uint64(lights.currentRound() - 1));
        lights.void();
        assertFalse(lights.voided());
        assertEq(lights.stallFlaggedAt(), 0);
        lights.poke(10);
        assertEq(lights.readThrough(), lights.currentRound() - 1);
        assertEq(lights.getWalker().cursor, lights.currentRound() - 1);
    }

    /// The deployment is first touched long after round 1000 while the core can't be read: nothing was ever read, so
    /// the stall counts from the start round and can be flagged at once. Any full read in the next 24 h clears it.
    function test_aDeadCoreSeenLateIsFlaggableButAReadWithinTheDayClearsIt() public {
        core.setReverting(true);
        _warpRound(1300);
        assertEq(lights.readThrough(), 0);
        lights.flagStall();
        assertEq(lights.stallMark(), 1000, "never read: counted from the start round");
        uint256 flaggedAt = lights.stallFlaggedAt();

        core.setReverting(false);
        _to(1310);
        lights.poke(1);
        assertEq(lights.readThrough(), 1309);

        core.setReverting(true);
        vm.warp(flaggedAt + 1 days);
        lights.void();
        assertFalse(lights.voided(), "the core was read after the flag");
        assertEq(lights.stallFlaggedAt(), 0, "the flag is cleared");
        vm.expectRevert(LightsOn.NotStalled.selector);
        lights.flagStall();
        _warpRound(1309 + 146);
        lights.flagStall();
        assertEq(lights.stallMark(), 1309);
    }

    /// After a full read at any round, with the core lagging by up to 100 rounds, a dead core is a stall exactly from
    /// the 145th round after the last round the core had settled, and not one round earlier. With more than 16
    /// running rounds the one page asked for leaves the cursor behind: the stall still counts from the core's round.
    function testFuzz_unreadableStallOpensAt145RoundsAfterTheLastRead(uint256 r, uint256 lag, uint256 running) public {
        running = bound(running, 0, 60);
        if (running != 0) core.setActiveRange(1001, uint64(1000 + running));
        r = bound(r, 1162, 50_000);
        lag = bound(lag, 0, 100);
        _warpRound(r);
        core.setSettled(uint64(r - 1 - lag));
        lights.poke(1);
        uint256 seen = r - 1 - lag;
        assertEq(lights.readThrough(), seen);
        if (running > 16) assertEq(lights.getWalker().cursor, 1016, "one page of 16 running rounds");
        else assertEq(lights.getWalker().cursor, seen);
        assertFalse(lights.stalled(), "a core 100 rounds behind is not a stall");

        core.setReverting(true);
        _warpRound(seen + 145);
        assertFalse(lights.stalled());
        vm.expectRevert(LightsOn.NotStalled.selector);
        lights.flagStall();
        _warpRound(seen + 146);
        assertTrue(lights.stalled());
        lights.flagStall();
        assertEq(lights.stallMark(), seen);
        assertTrue(lights.stallUnreadable());
    }
}
