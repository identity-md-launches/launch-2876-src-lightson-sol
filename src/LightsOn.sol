// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LightsMath} from "./LightsMath.sol";
import {ISqueekCore, ISQK, IERC20Min, RoundPage} from "./ISqueek.sol";

/// Keep the Lights On (docs/lights-on-spec.md, settlement v2). Prototype, not deployed.
/// Squeektoshi's running rounds light numbered bulbs. Bet on a bulb; when the lights go out, the lit bulbs share
/// the whole pot (every counted bet plus the bonus pot) by stake x (bulb - bulbs already lit when the bet was sent).
/// No owner, admin, pause, proxy, setters or randomness, and dataHash is never read.
/// Nights come only from the walker, which reads SqueekCore.roundPage and never past certifiedThroughRound. The
/// walker, stall/void and burn code started as copies of HopOn.sol, which stays as it was. Since the 11-01 audit,
/// every read of the core goes through a call LightsOn makes to itself, so no reply from the core (a revert, a reply
/// in another shape, no code at all) can make a bet, a collect or the way out revert.
contract LightsOn {
    uint256 public constant ROUND_SECONDS = 600;
    uint256 public constant GUARD_SECONDS = 60; // a bet in the last 60 s of a round counts as sent in the next one
    uint256 public constant MAX_RECORDS = 16;
    uint256 public constant STALL_ROUNDS = 144;
    uint256 public constant VOID_DELAY = 1 days;
    uint256 public constant SLEEP_ROUNDS = 1008; // 7 days without a running round: the game can be ended (void)
    uint256 public constant CORE_GAS = 1_000_000; // gas each read of the core may use (a 16-record page: ~124,000)
    uint256 public constant STALL_GAS = 2_100_000; // gas the stall check needs, so a read can't be starved on purpose
    uint256 public constant MIN_BET = 10e18;
    uint256 public constant MAX_BET = 10_000e18;
    uint256 public constant MAX_BULB = 24;
    uint256 public constant BURN_BPS = 200;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint8 public constant WAITING = 0; // not counted into a night yet
    uint8 public constant COUNTED = 1; // counted into its night by settle
    uint8 public constant CLAIMED = 2;
    uint8 public constant REFUNDED = 3; // paid back after a void without ever being counted

    ISqueekCore public immutable CORE;
    ISQK public immutable SQK;
    uint256 public immutable G; // genesis timestamp; round R = [G+(R-1)*600, G+R*600)
    uint256 public immutable STATION; // rounds per night, hard end
    uint256 public immutable START_ROUND; // the walker starts after this round

    struct Config {
        address core;
        address sqk;
        uint256 genesisTime;
        uint256 station;
        uint32 startRound; // the walker starts after this round; pick one after a blackout
    }

    struct Bet {
        address owner;
        uint32 betRound; // effective round the bet was sent in (guard band applied)
        uint8 bulb;
        uint8 status;
        uint8 cls; // LightsMath class, set by settle
        uint8 litBefore; // bulbs lit before betRound in its night, set by settle
        uint32 night;
        uint96 stake;
        uint128 cumBefore; // winning weight of the earlier winners in the same night
    }

    struct Night {
        uint32 start; // departure round: it lights nothing
        uint32 c; // first quiet round of the blackout pair, 0 = STATION end
        uint64 stops; // bit i set: round start + i was active (bit 0 is the departure)
        uint32 spanEnd; // last round of the night: C + 1, or start + STATION - 1
        uint32 lastBetRound; // last round whose bets join it: C - 1 (C and C + 1 go to the next night), or spanEnd
        uint32 betEnd; // bets [previous night's betEnd, betEnd) belong to it; set when settled
        uint8 result; // LightsMath.SETTLING, PAID or ROLLED
        uint128 sumW; // winners: sum of stake * (bulb - litBefore)
        uint128 winStake;
        uint128 loseStake;
        uint128 bonusIn;
        uint128 burned;
    }

    struct Walker {
        uint32 cursor; // last round processed
        uint32 openStart; // 0 = no night in progress
        uint64 openStops;
        uint8 idleRun;
        uint32 lastActive; // last active round seen
        uint32 lastBetRound; // lastBetRound of the latest closed night
    }

    Bet[] internal _bets;
    Night[] internal _nights;
    Walker public walker;
    uint32 public nextSettle; // first night not settled yet
    uint32 public betCursor; // first bet not counted yet
    uint32 public consumedBefore; // the pots of ROLLED nights below this index were won by a later night
    uint128 public bonusPot; // carried into the next night to settle
    mapping(address => uint256) public lastBet; // owner => latest betId + 1

    uint256 public stallFlaggedAt;
    uint256 public stallMark; // last round the core was known to have settled when the flag went up
    bool public voided;
    bool public stallUnreadable; // the flag went up while the core could not be read (else: it was behind)
    uint32 public readThrough; // last round the core had settled when the walker last read it without a failure
    uint256 public unburned; // only if both burn and the 0xdEaD transfer failed
    uint256 private _lock = 1;

    event BetPlaced(uint256 indexed betId, address indexed owner, uint8 bulb, uint256 amount, uint256 betRound);
    event NightClosed(
        uint256 indexed nightId,
        uint256 start,
        uint256 c,
        uint256 lit,
        uint64 stops,
        uint256 spanEnd,
        uint256 lastBetRound
    );
    event NightSettled(
        uint256 indexed nightId, uint8 result, uint256 pot, uint256 burned, uint256 bonusIn, uint256 bonusOut
    );
    event Claimed(uint256 indexed betId, address indexed owner, uint256 amount);
    event Refunded(uint256 indexed betId, address indexed owner, uint256 amount);
    event Burned(uint256 amount, bool viaDead);
    event BurnFailed(uint256 amount);
    event StallFlagged(uint256 at);
    event StallCleared();
    event Voided();

    error BadConfig();
    error BeforeGenesis();
    error IsVoided();
    error BadBulb();
    error BadAmount();
    error AlreadyBet();
    error NotStalled();
    error TooEarly();
    error SettleFirst();
    error TransferFailed();
    error Reentrant();
    error NotSettled();
    error TooLate(); // betUntil: the bet arrived after its last round
    error PokeFirst(); // the walker has not read every round the core has; poke, then bet again
    error NeedMoreGas(); // the stall check needs STALL_GAS, so that a read of the core can't be starved on purpose
    error BadPage(); // readCorePage: a page that breaks the core's own rules

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(Config memory cfg) {
        if (cfg.core == address(0) || cfg.sqk == address(0) || cfg.station < 4 || cfg.station > 64) {
            revert BadConfig();
        }
        CORE = ISqueekCore(cfg.core);
        SQK = ISQK(cfg.sqk);
        G = cfg.genesisTime;
        STATION = cfg.station;
        START_ROUND = cfg.startRound;
        walker.cursor = cfg.startRound;
    }

    // ---------------------------------------------------------------- time

    function roundAt(uint256 t) public view returns (uint256) {
        return t < G ? 0 : (t - G) / ROUND_SECONDS + 1;
    }

    function currentRound() public view returns (uint256) {
        return roundAt(block.timestamp);
    }

    function effectiveRound() public view returns (uint256) {
        return roundAt(block.timestamp + GUARD_SECONDS);
    }

    // ---------------------------------------------------------------- bets

    /// One bet per address per night. It joins the night open in its round, or the next night if none is open.
    /// Whether it counts is decided at settlement (the "two rounds ahead" rule in LightsMath.classify).
    function bet(uint8 bulb, uint256 amount) external nonReentrant returns (uint256) {
        return _placeBet(bulb, amount);
    }

    /// The same bet, but it reverts (TooLate) if it arrives after round `lastRound` (block time + 60 s, as for every
    /// bet). The page passes the round the player saw, so a bet that waits to be included can't silently move to a
    /// later round or night.
    function betUntil(uint8 bulb, uint256 amount, uint256 lastRound) external nonReentrant returns (uint256) {
        if (effectiveRound() > lastRound) revert TooLate();
        return _placeBet(bulb, amount);
    }

    function _placeBet(uint8 bulb, uint256 amount) internal returns (uint256 betId) {
        if (voided) revert IsVoided();
        if (bulb == 0 || bulb > MAX_BULB) revert BadBulb();
        if (amount < MIN_BET || amount > MAX_BET) revert BadAmount();
        uint256 n = effectiveRound();
        if (n == 0) revert BeforeGenesis();
        _crank(1, 4);

        // The earlier bet is in another night only once a closed night's last bet round is at or after its round.
        // Every closed night ended before the current round, so the new bet cannot land in it. A bet sent in a
        // blackout round (C or C + 1) is in the next night, which is open until its own blackout.
        uint256 prev = lastBet[msg.sender];
        if (prev != 0) {
            uint256 before = _bets[prev - 1].betRound;
            if (walker.lastBetRound < before) {
                (, bool behind) = _poke(4); // after a quiet spell the walker may be behind; catch up before refusing
                // still behind the core: the earlier bet's night may be over, but the walker can't tell yet
                if (walker.lastBetRound < before) {
                    if (behind) revert PokeFirst();
                    revert AlreadyBet();
                }
            }
        }

        betId = _bets.length;
        _bets.push(
            Bet({
                owner: msg.sender,
                betRound: uint32(n),
                bulb: bulb,
                status: WAITING,
                cls: 0,
                litBefore: 0,
                night: 0,
                stake: uint96(amount),
                cumBefore: 0
            })
        );
        lastBet[msg.sender] = betId + 1;
        emit BetPlaced(betId, msg.sender, bulb, amount, n);
        if (!SQK.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
    }

    /// Anyone can claim for anyone; the money always goes to the bet's owner. Bets not ready yet are skipped, and
    /// claims never expire.
    function claim(uint256[] calldata betIds) external nonReentrant returns (uint256 done) {
        _crank(2, 32);
        for (uint256 i; i < betIds.length; ++i) {
            if (_claim(betIds[i])) ++done;
        }
    }

    // ---------------------------------------------------------------- walker

    /// Reads up to `maxPages` pages of rounds the core has certified and that have ended.
    function poke(uint256 maxPages) external returns (uint256 pages) {
        (pages,) = _poke(maxPages);
    }

    /// `behind`: the core answers and has ended rounds the walker has not read yet.
    function _poke(uint256 maxPages) internal returns (uint256 pages, bool behind) {
        if (voided) return (0, false);
        (bool ok, uint256 settledThrough) = _coreState();
        if (!ok) return (0, false);
        uint256 through = _lastEndedRound();
        if (settledThrough < through) through = settledThrough;

        Walker memory w = walker;
        bool failed;
        while (pages < maxPages && w.cursor < through) {
            (bool pageOk, uint256 cert, uint256[] memory ids) = _readPage(w.cursor, through);
            if (!pageOk) {
                failed = true;
                break;
            }
            uint256 prev = w.cursor;
            for (uint256 i; i < ids.length; ++i) {
                uint256 id = ids[i];
                _idle(w, prev + 1, id - 1);
                _active(w, id);
                prev = id;
            }
            _idle(w, prev + 1, cert);
            w.cursor = uint32(cert);
            ++pages;
        }
        walker = w;
        behind = w.cursor < through;
        // The core was read without a failure: nothing was left to read, or every page asked for came. The stall
        // check of the unreadable kind counts from here, not from a cursor that a page budget left behind.
        if (!failed && (pages != 0 || !behind) && through > readThrough) readThrough = uint32(through);
    }

    /// Quiet rounds: one is a break, two in a row are the blackout (C = the first). A night ends at its STATION
    /// round at the latest; a blackout pair counts only if both rounds are inside the night.
    function _idle(Walker memory w, uint256 from, uint256 to) internal {
        if (w.openStart == 0) return;
        uint256 last = w.openStart + STATION - 1;
        for (uint256 r = from; r <= to; ++r) {
            if (++w.idleRun == 2) return _close(w, r - 1, r);
            if (r == last) return _close(w, 0, r);
        }
    }

    /// An active round starts a night (the departure lights nothing) or lights the next bulb.
    function _active(Walker memory w, uint256 r) internal {
        if (w.openStart == 0) {
            w.openStart = uint32(r);
            w.openStops = 1;
        } else {
            w.openStops |= uint64(1 << (r - w.openStart));
        }
        w.idleRun = 0;
        w.lastActive = uint32(r);
        if (r == w.openStart + STATION - 1) _close(w, 0, r);
    }

    /// Every night is recorded, false starts too: a false start lights 0 bulbs, so nobody wins and its bets roll.
    /// Bets sent in the blackout's two quiet rounds (C and C + 1) belong to the next night. A STATION end has no
    /// quiet rounds that end it, so its bets run to its last round.
    function _close(Walker memory w, uint256 c, uint256 spanEnd) internal {
        uint256 lastBetRound = c != 0 ? c - 1 : spanEnd;
        Night storage night = _nights.push();
        night.start = w.openStart;
        night.c = uint32(c);
        night.stops = w.openStops;
        night.spanEnd = uint32(spanEnd);
        night.lastBetRound = uint32(lastBetRound);
        emit NightClosed(
            _nights.length - 1, w.openStart, c, _popcount(w.openStops) - 1, w.openStops, spanEnd, lastBetRound
        );
        w.lastBetRound = uint32(lastBetRound);
        w.openStart = 0;
        w.openStops = 0;
        w.idleRun = 0;
    }

    // ---------------------------------------------------------------- settle

    /// Counts bets into closed nights in bet order, then settles each night and carries its bonus pot.
    /// Bets are sorted by betRound, so night x owns the run of bets with betRound in
    /// (lastBetRound of x-1, lastBetRound of x].
    function settle(uint256 maxWork) external nonReentrant returns (uint256) {
        return _settle(maxWork);
    }

    function _settle(uint256 maxWork) internal returns (uint256 work) {
        if (voided) return 0;
        uint256 x = nextSettle;
        uint256 nNights = _nights.length;
        if (x == nNights) return 0;
        uint256 j = betCursor;
        while (x < nNights) {
            Night storage night = _nights[x];
            uint256 used;
            (j, used) = _count(night, x, j, maxWork - work);
            work += used;
            // Any bet placed from now on is after this night's last bet round, so its run is complete.
            if (work == maxWork) break;
            _complete(night, x, j);
            ++x;
            ++work;
        }
        nextSettle = uint32(x);
        betCursor = uint32(j);
    }

    struct Tally {
        uint256 start;
        uint64 stops;
        uint256 bulbsLit;
        uint256[] litAt;
        uint256 sumW;
        uint256 winStake;
        uint256 loseStake;
    }

    /// Counts up to `budget` bets of night x, starting at bet j. Returns the next bet and the bets counted.
    function _count(Night storage night, uint256 x, uint256 j, uint256 budget)
        internal
        returns (uint256, uint256 used)
    {
        uint256 n = _bets.length;
        uint256 lastBetRound = night.lastBetRound;
        Tally memory t;
        t.start = night.start;
        t.stops = night.stops;
        t.bulbsLit = _popcount(t.stops) - 1;
        t.litAt = _litRounds(t.start, t.stops, t.bulbsLit);
        t.sumW = night.sumW;
        t.winStake = night.winStake;
        t.loseStake = night.loseStake;
        while (used < budget && j < n && _bets[j].betRound <= lastBetRound) {
            _countBet(_bets[j], t, x);
            ++j;
            ++used;
        }
        night.sumW = uint128(t.sumW);
        night.winStake = uint128(t.winStake);
        night.loseStake = uint128(t.loseStake);
        return (j, used);
    }

    function _countBet(Bet storage b, Tally memory t, uint256 x) internal {
        uint256 bulb = b.bulb;
        uint256 betRound = b.betRound;
        uint256 stake = b.stake;
        uint8 cls = LightsMath.classify(bulb, t.bulbsLit, betRound, bulb <= t.bulbsLit ? t.litAt[bulb] : 0);
        uint256 before = _litBefore(t.start, t.stops, betRound);
        if (cls == LightsMath.WIN) {
            b.cumBefore = uint128(t.sumW);
            t.sumW += LightsMath.weight(stake, bulb, before);
            t.winStake += stake;
        } else if (cls == LightsMath.LOSE) {
            t.loseStake += stake;
        }
        b.cls = cls;
        b.litBefore = uint8(before);
        b.status = COUNTED;
        b.night = uint32(x);
    }

    function _complete(Night storage night, uint256 x, uint256 j) internal {
        uint256 bonusIn = bonusPot;
        uint256 pot = uint256(night.winStake) + night.loseStake + bonusIn;
        (uint8 result, uint256 burned, uint256 bonusOut,) =
            LightsMath.close(night.sumW, night.winStake, night.loseStake, bonusIn, BURN_BPS);
        night.betEnd = uint32(j);
        night.result = result;
        night.bonusIn = uint128(bonusIn);
        night.burned = uint128(burned);
        bonusPot = uint128(bonusOut);
        // A PAID night won every pot rolled before it.
        if (result == LightsMath.PAID) consumedBefore = uint32(x);
        emit NightSettled(x, result, pot, burned, bonusIn, bonusOut);
        if (burned != 0) _burn(burned);
    }

    function _burn(uint256 amount) internal {
        try SQK.burn(amount) {
            emit Burned(amount, false);
        } catch {
            (bool ok, bytes memory ret) = address(SQK).call(abi.encodeCall(IERC20Min.transfer, (DEAD, amount)));
            if (ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))))) {
                emit Burned(amount, true);
            } else {
                unburned += amount;
                emit BurnFailed(amount);
            }
        }
    }

    // ---------------------------------------------------------------- claims

    function _claim(uint256 betId) internal returns (bool) {
        if (betId >= _bets.length) return false;
        Bet storage b = _bets[betId];
        uint8 st = b.status;
        if (st == CLAIMED || st == REFUNDED) return false;
        (uint256 amount, bool ready) = _due(b);
        if (!ready) return false;
        address owner = b.owner;
        if (st == WAITING) {
            b.status = REFUNDED;
            emit Refunded(betId, owner, amount);
        } else {
            b.status = CLAIMED;
            // the only payout a ROLLED loser gets: its stake back from a pot that a void stranded
            if (amount != 0 && b.cls == LightsMath.LOSE) bonusPot -= uint128(amount);
            emit Claimed(betId, owner, amount);
        }
        if (amount != 0 && !SQK.transfer(owner, amount)) revert TransferFailed();
        return true;
    }

    /// What a bet is owed, and whether that is final.
    function _due(Bet storage b) internal view returns (uint256 amount, bool ready) {
        if (b.status == WAITING || b.status == REFUNDED) return (b.stake, voided);
        Night storage night = _nights[b.night];
        uint8 result = night.result;
        if (result == LightsMath.SETTLING) return (0, false);
        if (b.cls == LightsMath.LOSE && result == LightsMath.ROLLED) {
            if (b.night < consumedBefore) return (0, true); // a later night won the pot this stake rolled into
            return voided ? (uint256(b.stake), true) : (0, false); // still riding in the bonus pot
        }
        uint8 cls = b.cls;
        uint256 stake = b.stake;
        uint256 w = cls == LightsMath.WIN ? LightsMath.weight(stake, b.bulb, b.litBefore) : 0;
        return (LightsMath.payout(cls, stake, w, b.cumBefore, night.sumW, _pool(night)), true);
    }

    /// What the winners of a settled night share: every counted stake and the bonus pot, less the burn.
    function _pool(Night storage night) internal view returns (uint256) {
        if (night.result != LightsMath.PAID) return 0;
        return uint256(night.winStake) + night.loseStake + night.bonusIn - night.burned;
    }

    // ---------------------------------------------------------------- stall

    /// The spec: the core counts as stalled once it has stopped settling, or can't be read, for 144 rounds.
    /// A pause, a revert or a reply LightsOn can't read is not a stall by itself: it must last 144 rounds.
    function stalled() public view returns (bool s) {
        (s,,,) = _stall();
    }

    /// `mark` = the last round the core is known to have settled: its own answer if it can be read, else the last
    /// round it had settled when the walker last read it without a failure (`readThrough`, or the cursor if that is
    /// further). `walkFirst` = the core can still serve rounds the walker has not read.
    /// `unreadable` = the core could not be read just now (a revert, a bad page, a reply in another shape, no code).
    function _stall() internal view returns (bool, uint256 mark, bool walkFirst, bool unreadable) {
        if (gasleft() < STALL_GAS) revert NeedMoreGas();
        uint256 ended = _lastEndedRound();
        uint256 c = walker.cursor;
        (bool ok, uint256 settledThrough) = _coreState();
        if (ok) {
            uint256 through = settledThrough < ended ? settledThrough : ended;
            bool readable = through <= c;
            if (!readable) (readable,,) = _readPage(c, through);
            if (readable) return (ended > settledThrough + STALL_ROUNDS, settledThrough, through > c, false);
        }
        uint256 seen = readThrough;
        if (seen < c) seen = c;
        return (ended > seen + STALL_ROUNDS, seen, false, true);
    }

    function flagStall() external {
        if (voided) revert IsVoided();
        (bool s, uint256 mark,, bool unreadable) = _stall();
        if (!s) revert NotStalled();
        if (stallFlaggedAt == 0) {
            stallFlaggedAt = block.timestamp;
            stallMark = mark;
            stallUnreadable = unreadable;
            emit StallFlagged(block.timestamp);
        }
    }

    /// He has not run for SLEEP_ROUNDS (7 days): the core answers, the walker has read every round it can serve, and
    /// none of them since the last running round (or the start round) was active.
    function asleepTooLong() public view returns (bool) {
        (bool ok, uint256 settledThrough) = _coreState();
        if (!ok) return false;
        Walker memory w = walker;
        uint256 ended = _lastEndedRound();
        uint256 through = settledThrough < ended ? settledThrough : ended;
        uint256 awake = w.lastActive != 0 ? w.lastActive : START_ROUND;
        return w.openStart == 0 && w.cursor >= through && through > awake + SLEEP_ROUNDS;
    }

    /// Ends the game: closed nights keep their results, every bet not in one is refunded, and so is every stake in a
    /// bonus pot that no night won. Allowed (1) 24 h after a flag, if the core is still stalled in the same way (still
    /// behind, or still unreadable) and has settled nothing since the flag (otherwise the flag is cleared instead),
    /// or (2) when he has not run for 7 days.
    /// Every round the core can still serve must be read first (`poke`), and every closed night settled (`settle`),
    /// so a night that already ended pays as it ended (SettleFirst until then).
    function void() external {
        if (voided) revert IsVoided();
        bool walkFirst;
        if (!asleepTooLong()) {
            uint256 at = stallFlaggedAt;
            if (at == 0 || block.timestamp < at + VOID_DELAY) revert TooEarly();
            bool s;
            uint256 mark;
            bool unreadable;
            (s, mark, walkFirst, unreadable) = _stall();
            if (!s || unreadable != stallUnreadable || mark > stallMark) {
                // the core is fine again, stalls in another way, or settled rounds after the flag: the stall the
                // flag was raised for did not last
                stallFlaggedAt = 0;
                stallMark = 0;
                stallUnreadable = false;
                emit StallCleared();
                return;
            }
        }
        if (walkFirst || nextSettle != _nights.length) revert SettleFirst();
        voided = true;
        emit Voided();
    }

    // ---------------------------------------------------------------- views

    function betCount() external view returns (uint256) {
        return _bets.length;
    }

    function nightCount() external view returns (uint256) {
        return _nights.length;
    }

    function getBet(uint256 betId) external view returns (Bet memory) {
        return _bets[betId];
    }

    function getNight(uint256 nightId) external view returns (Night memory) {
        return _nights[nightId];
    }

    function getWalker() external view returns (Walker memory) {
        return walker;
    }

    /// Bulbs a closed night lit before its blackout.
    function lit(uint256 nightId) external view returns (uint256) {
        return _popcount(_nights[nightId].stops) - 1;
    }

    /// Round in which bulb `bulb` lit in a closed night, 0 if it stayed dark.
    function litRound(uint256 nightId, uint256 bulb) external view returns (uint256) {
        Night storage night = _nights[nightId];
        if (bulb == 0) return 0;
        uint256 i = _nthBitAbove(night.stops, 0, bulb);
        return i == 0 ? 0 : night.start + i;
    }

    /// The night in progress as far as the walker has read: departure round (0 = none), bulbs lit, quiet run.
    function openNight() external view returns (uint256 start, uint256 litSoFar, uint256 quiet) {
        Walker memory w = walker;
        if (w.openStart == 0) return (0, 0, 0);
        return (w.openStart, _popcount(w.openStops) - 1, w.idleRun);
    }

    /// Class, night result and payout of a bet. `ready` is false until the amount is final.
    function betOutcome(uint256 betId)
        external
        view
        returns (uint256 night, uint8 cls, uint8 result, uint256 payout, bool ready)
    {
        Bet storage b = _bets[betId];
        (payout, ready) = _due(b);
        if (b.status == COUNTED || b.status == CLAIMED) {
            night = b.night;
            cls = b.cls;
            result = _nights[night].result;
        }
    }

    /// The spec's single-round test: R is idle iff roundPage(R-1, R, 0).certifiedThrough >= R.
    function isIdle(uint64 r) external view returns (bool) {
        (bool ok, uint256 settledThrough) = _coreState();
        if (!ok || r == 0 || r > settledThrough) revert NotSettled();
        return CORE.roundPage(r - 1, r, 0).certifiedThroughRound >= r;
    }

    /// The settlement rule on its own, for the test vectors and the page. Same code as settle/claim.
    function settleNight(uint256 burnBps, uint256 litBulbs, uint256 bonusIn, LightsMath.BetIn[] calldata bets)
        external
        pure
        returns (uint256[] memory payouts, uint256 burned, uint256 bonusOut, uint8[] memory classes, uint8 result)
    {
        return LightsMath.settle(burnBps, litBulbs, bonusIn, bets);
    }

    // ---------------------------------------------------------------- internals

    /// Every bet and claim moves the walker and the settler a little. Neither ever reverts on a broken core.
    function _crank(uint256 pages, uint256 work) internal {
        if (voided) return;
        _poke(pages);
        _settle(work);
    }

    /// Bulbs lit in the rounds strictly between the departure and `betRound` (bit i of stops = round start + i).
    /// 0 for a bet sent before the departure or in it. betRound <= lastBetRound < start + 64, so the shift fits.
    function _litBefore(uint256 start, uint64 stops, uint256 betRound) internal pure returns (uint256) {
        if (betRound <= start + 1) return 0;
        return _popcount(uint64(stops & ((uint256(1) << (betRound - start)) - 2)));
    }

    /// litAt[k] = round bulb k lit in, for k = 1..min(lit, MAX_BULB).
    function _litRounds(uint256 start, uint64 stops, uint256 litBulbs) internal pure returns (uint256[] memory litAt) {
        uint256 n = litBulbs < MAX_BULB ? litBulbs : MAX_BULB;
        litAt = new uint256[](n + 1);
        uint256 k;
        for (uint256 i = 1; k < n; ++i) {
            if ((stops >> i) & 1 == 1) litAt[++k] = start + i;
        }
    }

    // ---------------------------------------------------------------- reading the core
    //
    // `try CORE.x()` catches a revert, but not a reply that can't be decoded (another shape after an upgrade of the
    // core, a value out of range) and not a core with no code: those revert in the caller. So LightsOn reads the core
    // through the two functions below, calling itself: anything wrong with the reply fails inside that inner call,
    // and the `try` around it catches it. Each read may use at most CORE_GAS.

    /// For LightsOn's own use (anyone may call it; it only reads): the core's settledThroughRound.
    function readCoreState() external view returns (uint256 settledThrough) {
        (settledThrough,,,,,,,) = CORE.state();
    }

    /// For LightsOn's own use (anyone may call it; it only reads): one page of the core, checked, as
    /// (certifiedThrough, the active round ids). Every round in (from, certifiedThrough] without a record is idle.
    /// Reverts BadPage unless the records are in order inside the page, each record adds work, and the page's end
    /// position is its last record's (so no running round was left out). The real core's pages all do this.
    function readCorePage(uint256 from, uint256 through) external view returns (uint256 cert, uint256[] memory ids) {
        RoundPage memory p = CORE.roundPage(uint64(from), uint64(through), MAX_RECORDS);
        cert = p.certifiedThroughRound;
        uint256 n = p.rounds.length;
        if (cert <= from || cert > through || n > MAX_RECORDS) revert BadPage();
        ids = new uint256[](n);
        uint256 prev = from;
        uint256 work = p.start.cumulativeWork;
        for (uint256 i; i < n; ++i) {
            uint256 id = p.rounds[i].roundId;
            uint256 cum = p.rounds[i].cumulativeWork;
            if (id <= prev || id > cert || cum <= work) revert BadPage();
            ids[i] = id;
            prev = id;
            work = cum;
        }
        if (p.end.cumulativeWork != work) revert BadPage();
    }

    function _coreState() internal view returns (bool ok, uint256 settledThrough) {
        try this.readCoreState{gas: CORE_GAS}() returns (uint256 s) {
            return (true, s);
        } catch {
            return (false, 0);
        }
    }

    function _readPage(uint256 from, uint256 through)
        internal
        view
        returns (bool ok, uint256 cert, uint256[] memory ids)
    {
        try this.readCorePage{gas: CORE_GAS}(from, through) returns (uint256 c, uint256[] memory r) {
            return (true, c, r);
        } catch {
            return (false, 0, ids);
        }
    }

    /// Rounds that have fully ended. A core that certified a round still in progress is not trusted for it.
    function _lastEndedRound() internal view returns (uint256) {
        uint256 cur = currentRound();
        return cur == 0 ? 0 : cur - 1;
    }

    function _popcount(uint64 x) internal pure returns (uint256 n) {
        for (; x != 0; x &= x - 1) {
            ++n;
        }
    }

    /// Bit index of the n-th set bit strictly above `off`, or 0 if there are fewer than n.
    function _nthBitAbove(uint64 x, uint256 off, uint256 n) internal pure returns (uint256) {
        for (uint256 i = off + 1; i < 64; ++i) {
            if ((x >> i) & 1 == 1 && --n == 0) return i;
        }
        return 0;
    }
}
