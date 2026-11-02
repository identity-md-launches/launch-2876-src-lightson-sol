// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LightsOn} from "../src/LightsOn.sol";
import {LightsMath} from "../src/LightsMath.sol";
import {MockCore, MockSQK} from "./mocks/Mocks.sol";
import {LightsLaunchFixture} from "./LightsLaunchFixture.sol";

/// Drives the launched LightsOn (station 36, start round 1000) through everything that can happen to it: rides,
/// breaks, blackouts, 6-hour ends, week-long sleeps, a core that goes down or stops settling, stall flags, void
/// attempts, a token whose burn breaks, valid and invalid bets, and third-party collecting. No call may revert.
contract LaunchHandler is Test {
    uint256 internal constant G = 1793022600;

    LightsOn public immutable lights;
    MockCore public immutable core;
    MockSQK public immutable sqk;
    address[] public actors;
    address public immutable keeper; // collects for others, never bets

    uint256 public round;
    bool public down; // core reverts
    bool public frozen; // core stops settling
    bool public pageBroken; // state() answers, roundPage replies in another shape (audit_time T2b)
    uint256 public maxSettled; // the furthest round the core ever said it had settled
    uint256 public lastReadThrough;

    mapping(address => uint256) public received; // SQK each actor got from claims
    mapping(address => uint256) public staked;
    uint256 public maxNights;
    bool public sawVoid;
    uint256 public settledSeen; // nights [0, settledSeen) have their fingerprint recorded
    mapping(uint256 => bytes32) public fingerprint;

    uint256 public betsPlaced;
    uint256 public voids;
    uint256 public flags;
    uint256 public clears;

    constructor(LightsOn l, MockCore c, MockSQK s, address[] memory a, address k) {
        lights = l;
        core = c;
        sqk = s;
        actors = a;
        keeper = k;
        round = 1001;
        _enter();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _enter() internal {
        uint256 t = G + (round - 1) * 600 + 100;
        if (t > block.timestamp) vm.warp(t); // chain time only moves forward
        if (!frozen) core.setSettled(uint64(round - 1));
        if (core.settled() > maxSettled) maxSettled = core.settled();
        core.setReverting(down);
    }

    function _after() internal {
        if (lights.voided()) sawVoid = true;
        uint256 n = lights.nightCount();
        assertGe(n, maxNights, "nights are never removed");
        maxNights = n;
        // a settled night never changes again
        uint256 s = lights.nextSettle();
        for (uint256 x; x < settledSeen; ++x) {
            assertEq(_fp(x), fingerprint[x], "a settled night changed");
        }
        for (uint256 x = settledSeen; x < s; ++x) {
            fingerprint[x] = _fp(x);
        }
        if (s > settledSeen) settledSeen = s;
        // the last full read never goes back, and never claims a round that has not ended or that the core never
        // said it had settled
        uint256 rt = lights.readThrough();
        assertGe(rt, lastReadThrough, "readThrough never goes back");
        assertLe(rt, lights.currentRound() - 1, "readThrough never past the last ended round");
        assertLe(rt, maxSettled, "readThrough never past what the core settled");
        lastReadThrough = rt;
    }

    function _fp(uint256 x) internal view returns (bytes32) {
        return keccak256(abi.encode(lights.getNight(x)));
    }

    // ------------------------------------------------------------ time and the core

    function step(uint8 seed) external {
        if (seed % 4 != 0) core.setActive(uint64(round), 400);
        if (seed % 7 == 0) {
            down = false;
            frozen = false;
        }
        ++round;
        _enter();
        _after();
    }

    function stepMany(uint8 seed, uint8 n) external {
        n = uint8(bound(n, 1, 14));
        for (uint256 i; i < n; ++i) {
            if (uint256(keccak256(abi.encode(seed, i))) % 5 != 0) core.setActive(uint64(round), 400);
            ++round;
        }
        _enter();
        _after();
    }

    /// A long run read with a one-page budget: the cursor stops after 16 running rounds while the core answered
    /// further, so readThrough runs ahead of the cursor.
    function longRun(uint8 n) external {
        n = uint8(bound(n, 17, 40));
        for (uint256 i; i < n; ++i) {
            core.setActive(uint64(round), 400);
            ++round;
        }
        _enter();
        lights.poke(1);
        _after();
    }

    /// He sleeps: up to ~8 days of quiet rounds (a week without running lets anyone end the game).
    function sleep(uint16 n) external {
        round += bound(n, 1, 1150);
        _enter();
        _after();
    }

    function lateInRound() external {
        uint256 t = G + round * 600 - 30;
        if (block.timestamp < t) vm.warp(t);
        _after();
    }

    function coreDown() external {
        down = true;
        _enter();
        _after();
    }

    function coreFreeze() external {
        frozen = true;
        _after();
    }

    function coreRecover() external {
        down = false;
        frozen = false;
        _enter();
        _after();
    }

    /// The core's pages stop coming in a shape LightsOn can read while state() still answers, or come back.
    function pageBreak(bool on) external {
        pageBroken = on;
        if (on) vm.mockCall(address(core), abi.encodeWithSelector(MockCore.roundPage.selector), bytes("not a page"));
        else vm.clearMockedCalls();
        _after();
    }

    function burnMode(uint8 m) external {
        sqk.setBurnReverts(m & 1 == 1);
        sqk.setDeadTransferFails(m & 2 == 2);
        _after();
    }

    // ------------------------------------------------------------ the game

    function bet(uint256 seed, uint8 count) external {
        uint256 c = bound(count, 1, 3);
        for (uint256 i; i < c; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            address a = actors[x % actors.length];
            uint8 bulb = uint8(x % 3 == 0 ? 1 + (x >> 8) % 24 : 1 + (x >> 8) % 8);
            uint256 sel = (x >> 16) % 6;
            uint256 stake = sel == 0 ? 10e18 : sel == 1 ? 10_000e18 : 10e18 + (x >> 32) % 9_990e18;
            uint256 n = lights.betCount();
            bool v = lights.voided();
            uint256 balBefore = sqk.balanceOf(address(lights));
            uint256 gone = sqk.totalBurned() + sqk.balanceOf(lights.DEAD());
            uint256 last = lights.effectiveRound();
            vm.prank(a);
            bool ok;
            bytes memory err;
            if ((x >> 64) % 2 == 0) {
                try lights.bet(bulb, stake) {
                    ok = true;
                } catch (bytes memory e) {
                    err = e;
                }
            } else {
                try lights.betUntil(bulb, stake, last) {
                    ok = true;
                } catch (bytes memory e) {
                    err = e;
                }
            }
            if (ok) {
                assertFalse(v, "no bet after the game ended");
                assertEq(lights.betCount(), n + 1);
                LightsOn.Bet memory b = lights.getBet(n);
                assertEq(b.owner, a);
                assertEq(b.stake, stake);
                assertEq(b.bulb, bulb);
                assertEq(b.betRound, lights.effectiveRound());
                gone = sqk.totalBurned() + sqk.balanceOf(lights.DEAD()) - gone; // a night the bet settled on its way
                assertEq(sqk.balanceOf(address(lights)) + gone, balBefore + stake, "the stake arrived");
                staked[a] += stake;
                ++betsPlaced;
            } else {
                bytes4 e = bytes4(err);
                if (v) {
                    assertEq(e, LightsOn.IsVoided.selector, "after the end only IsVoided");
                } else {
                    assertTrue(
                        e == LightsOn.AlreadyBet.selector || e == LightsOn.PokeFirst.selector,
                        "only AlreadyBet or PokeFirst may refuse a valid bet"
                    );
                }
                assertEq(lights.betCount(), n, "a refused bet leaves nothing");
            }
        }
        _after();
    }

    /// Invalid bulbs and amounts are refused and leave no trace.
    function badBet(uint256 seed) external {
        address a = actors[seed % actors.length];
        uint8 bulb;
        uint256 amount;
        bytes4 want;
        uint256 kind = (seed >> 8) % 4;
        if (kind == 0) {
            (bulb, amount, want) = (0, 100e18, LightsOn.BadBulb.selector);
        } else if (kind == 1) {
            (bulb, amount, want) = (uint8(bound(seed >> 16, 25, 255)), 100e18, LightsOn.BadBulb.selector);
        } else if (kind == 2) {
            (bulb, amount, want) = (3, bound(seed >> 16, 0, 10e18 - 1), LightsOn.BadAmount.selector);
        } else {
            (bulb, amount, want) = (3, bound(seed >> 16, 10_000e18 + 1, 1e30), LightsOn.BadAmount.selector);
        }
        if (lights.voided()) want = LightsOn.IsVoided.selector;
        uint256 n = lights.betCount();
        uint256 bal = sqk.balanceOf(a);
        vm.prank(a);
        try lights.bet(bulb, amount) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), want);
        }
        assertEq(lights.betCount(), n);
        assertEq(sqk.balanceOf(a), bal);
        _after();
    }

    /// readThrough moves only when the core answered and nothing failed, and then to exactly the last round that
    /// has both ended and been settled by the core.
    function poke(uint8 pages) external {
        uint256 rt = lights.readThrough();
        uint256 cursor = lights.getWalker().cursor;
        uint256 n = bound(pages, 0, 4);
        uint256 read = lights.poke(n);
        uint256 rt2 = lights.readThrough();
        uint256 through = lights.currentRound() - 1;
        if (core.settled() < through) through = core.settled();
        if (down || lights.voided()) {
            assertEq(read, 0);
            assertEq(rt2, rt, "a core that can't be answered is not a read");
        } else if (pageBroken) {
            assertEq(read, 0, "no page can be read");
            if (cursor < through) assertEq(rt2, rt, "a failed page is not a read");
        }
        if (rt2 != rt) {
            assertEq(rt2, through, "a full read records what the core settled");
            if (lights.getWalker().cursor < through) assertEq(read, n, "a partial read took every page asked for");
        }
        _after();
    }

    function settle(uint8 work) external {
        lights.settle(bound(work, 0, 40));
        _after();
    }

    /// The keeper collects for random bets one at a time; the money goes to the owner, and only once.
    function claim(uint256 seed) external {
        uint256 n = lights.betCount();
        if (n == 0) return;
        for (uint256 i; i < 4; ++i) {
            uint256 id = uint256(keccak256(abi.encode(seed, i))) % n;
            _claimOne(id);
        }
        _after();
    }

    /// The same bet twice in one call pays at most once.
    function claimTwice(uint256 seed) external {
        uint256 n = lights.betCount();
        if (n == 0) return;
        uint256 id = seed % n;
        LightsOn.Bet memory b = lights.getBet(id);
        uint8 st = b.status;
        uint256 before = sqk.balanceOf(b.owner);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        vm.prank(keeper);
        uint256 done = lights.claim(ids);
        assertLe(done, 1, "one bet is collected once");
        uint256 got = sqk.balanceOf(b.owner) - before;
        LightsOn.Bet memory a = lights.getBet(id);
        if (st == lights.CLAIMED() || st == lights.REFUNDED()) assertEq(got, 0, "collected twice");
        if (a.status == lights.CLAIMED() || a.status == lights.REFUNDED()) {
            if (st != a.status) {
                (,,, uint256 pay,) = lights.betOutcome(id);
                assertEq(got, pay, "paid what betOutcome says");
            }
        } else {
            assertEq(got, 0, "nothing paid for a bet not collected");
        }
        received[b.owner] += got;
        _after();
    }

    function _claimOne(uint256 id) internal {
        LightsOn.Bet memory b = lights.getBet(id);
        uint8 st = b.status;
        uint256 before = sqk.balanceOf(b.owner);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeper);
        lights.claim(ids);
        uint256 got = sqk.balanceOf(b.owner) - before;
        uint8 now_ = lights.getBet(id).status;
        if (st == lights.CLAIMED() || st == lights.REFUNDED()) {
            assertEq(got, 0, "collected twice");
            assertEq(now_, st, "a final status never changes");
        } else if (now_ == lights.CLAIMED() || now_ == lights.REFUNDED()) {
            (,,, uint256 pay, bool ready) = lights.betOutcome(id);
            assertTrue(ready);
            assertEq(got, pay, "paid what betOutcome says");
        } else {
            assertEq(got, 0, "nothing paid for a bet not collected");
        }
        received[b.owner] += got;
    }

    // ------------------------------------------------------------ the way out

    function flagStall() external {
        bool v = lights.voided();
        bool s = v ? false : lights.stalled();
        uint256 at = lights.stallFlaggedAt();
        uint256 seen = lights.readThrough();
        if (seen < lights.getWalker().cursor) seen = lights.getWalker().cursor;
        try lights.flagStall() {
            assertFalse(v);
            assertTrue(s, "flagged only while stalled");
            if (at == 0) {
                assertEq(lights.stallFlaggedAt(), block.timestamp);
                if (lights.stallUnreadable()) {
                    assertEq(lights.stallMark(), seen, "unreadable: counted from the last full read or the cursor");
                    assertGt(lights.currentRound() - 1, seen + 144, "and only 145 rounds after it");
                }
                ++flags;
            } else {
                assertEq(lights.stallFlaggedAt(), at, "an existing flag is kept");
            }
        } catch (bytes memory err) {
            bytes4 e = bytes4(err);
            if (v) assertEq(e, LightsOn.IsVoided.selector);
            else assertEq(e, LightsOn.NotStalled.selector);
        }
        _after();
    }

    function waitADay() external {
        round += 145;
        _enter();
        _after();
    }

    function tryVoid() external {
        bool v = lights.voided();
        bool asleep = v ? false : lights.asleepTooLong();
        uint256 at = lights.stallFlaggedAt();
        try lights.void() {
            assertFalse(v);
            if (lights.voided()) {
                ++voids;
                assertTrue(asleep || (at != 0 && block.timestamp >= at + 1 days), "ended only when allowed");
                assertEq(lights.nextSettle(), lights.nightCount(), "every closed night settled first");
                (uint256 start,,) = lights.openNight();
                if (asleep) assertEq(start, 0);
            } else {
                ++clears;
                assertEq(lights.stallFlaggedAt(), 0, "a stale flag is cleared");
            }
        } catch (bytes memory err) {
            bytes4 e = bytes4(err);
            if (v) {
                assertEq(e, LightsOn.IsVoided.selector);
            } else {
                assertTrue(e == LightsOn.TooEarly.selector || e == LightsOn.SettleFirst.selector, "void refusal");
                if (e == LightsOn.TooEarly.selector) assertFalse(asleep);
            }
        }
        _after();
    }
}

/// Invariants of the launched game over random call sequences.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 150
contract LightsLaunchInvariantTest is LightsLaunchFixture {
    LaunchHandler internal handler;
    LightsOn internal lights;
    MockCore internal core;
    MockSQK internal sqk;
    address[] internal actors;
    address internal keeper = address(0xC011EC7);
    uint256 internal minted;

    function setUp() public {
        _warpRound(1001);
        (lights, core, sqk) = _launch(keccak256("launch invariants"));
        // He ran before the start round: that ride is not this game's.
        core.setActiveRange(960, 990);
        core.setSettled(1000);
        for (uint256 i; i < 10; ++i) {
            address a = address(uint160(0xB0B000 + i));
            actors.push(a);
            sqk.mint(a, 50_000_000e18);
            minted += 50_000_000e18;
            vm.prank(a);
            sqk.approve(address(lights), type(uint256).max);
        }
        handler = new LaunchHandler(lights, core, sqk, actors, keeper);
        targetContract(address(handler));
    }

    /// Every SQK wei is with a player, held by the game, or burned (by burn() or sent to 0xdEaD).
    function invariant_supplyIsConserved() public view {
        uint256 sum =
            sqk.balanceOf(address(lights)) + sqk.totalBurned() + sqk.balanceOf(lights.DEAD()) + sqk.balanceOf(keeper);
        for (uint256 i; i < actors.length; ++i) {
            sum += sqk.balanceOf(actors[i]);
        }
        assertEq(sum, minted);
        assertEq(sqk.balanceOf(keeper), 0, "collecting for others pays the caller nothing");
    }

    /// The game holds exactly what it owes, in every state, voided or not.
    function invariant_holdsExactlyWhatItOwes() public view {
        uint256 owed;
        uint256 riding;
        uint256 n = lights.betCount();
        for (uint256 id; id < n; ++id) {
            LightsOn.Bet memory b = lights.getBet(id);
            if (b.status == lights.WAITING()) {
                owed += b.stake;
            } else if (b.status == lights.COUNTED()) {
                uint8 result = lights.getNight(b.night).result;
                (,,, uint256 pay, bool ready) = lights.betOutcome(id);
                if (result == LightsMath.SETTLING) {
                    owed += b.stake;
                } else if (
                    result == LightsMath.ROLLED && b.cls == LightsMath.LOSE && b.night >= lights.consumedBefore()
                ) {
                    // still in the bonus pot: owed back only once the game has ended
                    riding += b.stake;
                    if (lights.voided()) {
                        assertTrue(ready);
                        assertEq(pay, b.stake, "after the end a stranded stake goes back");
                    } else {
                        assertFalse(ready, "a riding stake is not collectable while the game runs");
                    }
                } else {
                    assertTrue(ready, "a settled bet is ready");
                    owed += pay;
                }
            }
        }
        assertEq(riding, lights.bonusPot(), "bonus pot == rolled stakes no night has won");
        assertEq(sqk.balanceOf(address(lights)), owed + riding + lights.unburned(), "held == owed");
    }

    /// What each player received equals what betOutcome says its collected bets were owed, and nobody got more
    /// back than all the stakes in the game.
    function invariant_collectedMatchesOutcomes() public view {
        uint256 n = lights.betCount();
        uint256[] memory due = new uint256[](actors.length);
        uint256 totalStaked;
        for (uint256 id; id < n; ++id) {
            LightsOn.Bet memory b = lights.getBet(id);
            totalStaked += b.stake;
            if (b.status != lights.CLAIMED() && b.status != lights.REFUNDED()) continue;
            (,,, uint256 pay, bool ready) = lights.betOutcome(id);
            assertTrue(ready, "a collected bet's amount is final");
            due[uint160(b.owner) - 0xB0B000] += pay;
        }
        uint256 totalReceived;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(handler.received(actors[i]), due[i], "received == sum of collected outcomes");
            totalReceived += due[i];
        }
        assertLe(totalReceived, totalStaked, "nobody is paid from money that was never staked");
    }

    /// The walker starts after round 1000 and never reads a round that has not ended; nights never overlap and
    /// never last more than 36 rounds; ended games stay ended.
    function invariant_walkerAndNights() public view {
        LightsOn.Walker memory w = lights.getWalker();
        assertGe(w.cursor, START, "never before the start round");
        assertLt(w.cursor, lights.currentRound(), "never a round in progress");
        uint256 prevSpan = START;
        for (uint256 x; x < lights.nightCount(); ++x) {
            LightsOn.Night memory night = lights.getNight(x);
            assertGt(night.start, prevSpan, "no night before the start round, and none overlap");
            assertLe(uint256(night.spanEnd) - night.start + 1, STATION_, "a ride lasts 36 rounds at most");
            assertLe(night.spanEnd, w.cursor, "closed nights were read");
            prevSpan = night.spanEnd;
        }
        if (handler.sawVoid()) assertTrue(lights.voided(), "an ended game stays ended");
        assertLe(lights.nextSettle(), lights.nightCount());
    }

    /// Bets are kept in round order (the settler relies on it) and one wallet has one bet per night.
    function invariant_betOrderAndOnePerNight() public view {
        uint256 n = lights.betCount();
        for (uint256 id = 1; id < n; ++id) {
            assertGe(lights.getBet(id).betRound, lights.getBet(id - 1).betRound, "bets sorted by round");
        }
        uint256 first;
        for (uint256 x; x < lights.nextSettle(); ++x) {
            uint256 end = lights.getNight(x).betEnd;
            for (uint256 i = first; i < end; ++i) {
                assertEq(lights.getBet(i).night, x);
                for (uint256 j = i + 1; j < end; ++j) {
                    assertTrue(lights.getBet(j).owner != lights.getBet(i).owner, "one bet per wallet per night");
                }
            }
            first = end;
        }
    }

    /// Whatever happened, the game can always be ended and every bet collected: nothing is left but what a broken
    /// burn could not destroy.
    function afterInvariant() public {
        sqk.setBurnReverts(false);
        sqk.setDeadTransferFails(false);
        vm.clearMockedCalls();
        for (uint256 tries; tries < 4 && !lights.voided(); ++tries) {
            core.setReverting(true);
            uint256 seen = lights.readThrough();
            if (seen < lights.getWalker().cursor) seen = lights.getWalker().cursor;
            uint256 r = seen + 146;
            if (lights.currentRound() < r) _warpRound(r);
            lights.settle(type(uint256).max);
            if (lights.stallFlaggedAt() == 0) lights.flagStall();
            vm.warp(block.timestamp + 1 days);
            lights.void();
        }
        assertTrue(lights.voided(), "the game can always be ended");
        uint256 n = lights.betCount();
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = i;
        }
        lights.claim(ids);
        for (uint256 i; i < n; ++i) {
            uint8 st = lights.getBet(i).status;
            assertTrue(st == lights.CLAIMED() || st == lights.REFUNDED(), "every bet collected");
        }
        assertEq(lights.bonusPot(), 0, "the stranded pot went back to its bets");
        assertEq(sqk.balanceOf(address(lights)), lights.unburned(), "no stuck funds after the end");
        assertEq(lights.claim(ids), 0, "nothing can be collected twice");
        console2.log("bets", n, "nights", lights.nightCount());
        console2.log("burned (SQK)", sqk.totalBurned() / 1e18, "unburned (SQK)", lights.unburned() / 1e18);
        console2.log("voided in sequence / flags / clears", handler.voids(), handler.flags(), handler.clears());
    }
}
