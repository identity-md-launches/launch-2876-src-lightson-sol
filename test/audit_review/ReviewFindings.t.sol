// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LightsBase} from "../LightsBase.t.sol";
import {LightsOn} from "../../src/LightsOn.sol";
import {MockCore} from "../mocks/Mocks.sol";

/// Launch review (11-02), finding 4e170c77: the stall of the unreadable kind was measured from the walker's cursor.
/// The cursor is the last round the walker *processed*, which a page budget can leave behind the last round the core
/// *answered*: a bet reads one page, a collect two, so after a long run the cursor lags a core that was read fine in
/// the same block. Now `readThrough` records the last round the core had settled whenever it was read without a
/// failure, and the unreadable kind counts 144 rounds from max(cursor, readThrough). The first test FAILED on the
/// audited LightsOn.sol; the others pin what must not change with it.
///   forge test --offline --match-path 'test/audit_review/*' -vv
contract ReviewFindingsTest is LightsBase {
    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    /// He runs 40 rounds (three pages) while nobody touches the game. A bet at round 300 reads one page, so the
    /// cursor stops at 115 although the core answered through 299 in that very block. One block later the core
    /// can't be read: that is not a stall of 144 rounds, and the flag is refused.
    function test_aPageBudgetThatLeavesTheCursorBehindIsNotAnUnreadableStall() public {
        _at(100);
        uint256 a = _bet(bettors[0], 2, 100e18);
        assertEq(lights.getWalker().cursor, 99);
        assertEq(lights.readThrough(), 99, "the core was read through 99");
        _active(100, 139);
        _at(300);
        _bet(bettors[1], 5, 100e18);
        assertEq(lights.getWalker().cursor, 115, "one page of 16 running rounds");
        assertEq(lights.readThrough(), 299, "but the core answered through 299");

        core.setReverting(true);
        assertFalse(lights.stalled(), "the core was readable in the block before");
        vm.expectRevert(LightsOn.NotStalled.selector);
        lights.flagStall();
        // 145 rounds after the last successful read it is one
        vm.warp(G + (299 + 144) * 600 + 100);
        assertFalse(lights.stalled(), "exactly 144 rounds since the last read");
        vm.warp(G + (300 + 144) * 600 + 100);
        assertTrue(lights.stalled(), "145 rounds since the last read");
        lights.flagStall();
        assertTrue(lights.stallUnreadable());
        assertEq(lights.stallMark(), 299, "the mark is the last round the core was read through, not the cursor");
        core.setReverting(false);

        _at(lights.currentRound());
        _settleAll();
        assertEq(lights.nightCount(), 2, "the 36-round night and the 4-round one");
        assertEq(_claim(a), 100e18, "the only bet of night 0 is a winner and gets its stake back");
    }

    /// A page the walker can't read (a reply in another shape, as in audit_time T2b) does not count as a read, even
    /// though state() still answers on every bet: `readThrough` stays where the last full read left it, so the way
    /// out opens 144 rounds after that, with or without bets in between. The reviewer's suggestion to record every
    /// successful state() call would have pushed the mark forward on each bet and locked the game.
    function test_aStateReplyWithAnUnreadablePageIsNotARead() public {
        _at(97);
        uint256 l = _bet(bettors[0], 9, 100e18);
        _active(100, 102); // nobody wins: 100 rolls into the bonus pot
        _at(110);
        _settleAll();
        assertEq(lights.readThrough(), 109);

        core.setActive(111, 500);
        vm.mockCall(address(core), abi.encodeWithSelector(MockCore.roundPage.selector), bytes("not a page"));
        uint256[] memory open = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            _at(112 + 40 * i); // bets keep coming while the page can't be read; each one reads state() fine
            open[i] = _bet(bettors[1 + i], uint8(3 + i), 50e18);
            assertEq(lights.readThrough(), 109, "state() answered, the page did not: not a read");
            assertEq(lights.getWalker().cursor, 109);
        }
        vm.warp(G + (109 + 144) * 600 + 100);
        core.setSettled(uint64(lights.currentRound() - 1));
        vm.expectRevert(LightsOn.NotStalled.selector);
        lights.flagStall();
        vm.warp(G + (109 + 145) * 600 + 100);
        core.setSettled(uint64(lights.currentRound() - 1));
        lights.flagStall();
        assertEq(lights.stallMark(), 109);
        vm.warp(block.timestamp + 1 days);
        core.setSettled(uint64(lights.currentRound() - 1));
        lights.void();
        assertTrue(lights.voided(), "a page unreadable for 144 rounds and 24 h more: the game ends");
        vm.clearMockedCalls();
        for (uint256 i; i < 3; ++i) {
            assertEq(_claim(open[i]), 50e18);
        }
        assertEq(_claim(l), 100e18, "the bonus pot goes back to its bet");
        assertEq(sqk.balanceOf(address(lights)), 0, "nothing locked");
    }

    /// A full read between the flag and the void raises the mark and clears the flag, even when that read moved the
    /// cursor only part of the way (a collect reads two pages).
    function test_aPartialReadBetweenFlagAndVoidClearsTheFlag() public {
        _at(100);
        uint256 a = _bet(bettors[0], 2, 100e18);
        uint256 b = _bet(bettors[1], 10, 100e18);
        _active(100, 105); // bulbs 1-5, lights out 106-107
        _coreDownForAStall();
        lights.flagStall();
        assertEq(lights.stallMark(), 99);
        core.setReverting(false);

        // the core is back; he runs 50 more rounds and somebody collects (two pages), which does not reach the end
        _active(200, 249);
        _at(260);
        assertEq(_claim(a), 198e18, "the collect reads two pages, settles night 0 and pays Alice as it ended");
        assertLt(lights.getWalker().cursor, 259, "two pages did not catch up");
        assertEq(lights.readThrough(), 259, "but the core was read through 259");

        vm.warp(block.timestamp + 1 days);
        core.setReverting(true);
        lights.void();
        assertFalse(lights.voided(), "the core was read after the flag");
        assertEq(lights.stallFlaggedAt(), 0, "the flag is cleared");
        vm.expectRevert(LightsOn.NotStalled.selector);
        lights.flagStall();
        core.setReverting(false);

        _at(lights.currentRound());
        _settleAll();
        assertEq(_claim(b), 0, "Bob's bulb 10 stayed dark");
        assertEq(lights.getBet(a).status, lights.CLAIMED());
    }

    /// poke(0) reads nothing: it is not a read, so it can't be used to keep a dead core's clock from running.
    function test_pokeWithNoPagesIsNotARead() public {
        _at(100);
        _bet(bettors[0], 2, 100e18);
        assertEq(lights.readThrough(), 99);
        vm.mockCall(address(core), abi.encodeWithSelector(MockCore.roundPage.selector), bytes("not a page"));
        _at(200);
        assertEq(lights.poke(0), 0);
        assertEq(lights.readThrough(), 99, "nothing was read");
        _at(250);
        assertTrue(lights.stalled(), "150 rounds without a page: a stall");
        vm.clearMockedCalls();
    }

    /// `readThrough` never goes backwards and never exceeds the last ended round.
    function testFuzz_readThroughIsMonotone(uint16 settledLag, uint8 steps) public {
        _at(100);
        uint256 last;
        for (uint256 i; i < bound(steps, 1, 12); ++i) {
            uint256 r = 100 + (i + 1) * 20;
            vm.warp(G + (r - 1) * 600 + 100);
            uint256 s = r - 1 - bound(settledLag, 0, 30) % (i + 2);
            core.setSettled(uint64(s));
            lights.poke(3);
            uint256 rt = lights.readThrough();
            assertGe(rt, last, "monotone");
            assertLe(rt, r - 1, "never past the last ended round");
            assertLe(rt, s, "never past what the core settled");
            assertGe(rt, lights.getWalker().cursor, "a full read is at least the cursor");
            last = rt;
        }
    }
}
