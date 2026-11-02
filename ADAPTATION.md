# Launch adaptation

`LightsOn` already satisfies the contracts-only factory requirements. Its game rules, limits, maths and
constructor ABI are unchanged. The launch deploys only `src/LightsOn.sol:LightsOn` on Sepolia
(`11155111`), using the existing SQK and SqueekCore contracts. The one source change (revision 2, below)
alters how the stall of the unreadable kind is measured, not the rule itself.

## Changes and reasons

| File | Change | Requirement or finding |
|---|---|---|
| `src/LightsOn.sol` | Revision 2. New storage `uint32 public readThrough`: the last round the core had settled when the walker last read it without a failure. `_poke` records it when the core's `state()` answered and either nothing was left to read or every page asked for was read (a failed page, or `poke(0)` with rounds left, records nothing). `_stall()` measures the unreadable kind, and sets its mark, from `max(walker.cursor, readThrough)` instead of the cursor alone. 14 lines; no change to limits, maths, rules, events or the constructor. | Review finding `4e170c77…`: the unreadable-kind stall was measured from the walker's cursor, which a page budget can leave behind the last round the core actually answered. See the disposition below for what the change does and does not cover. |
| `test/audit_review/ReviewFindings.t.sol` | Revision 2. Five tests: the page-budget case (fails on the previous code), an unreadable page with a working `state()` is not a read (so the T2b exit still opens), a partial read between flag and void clears the flag, `poke(0)` is not a read, and a fuzz that `readThrough` is monotone and never past the last ended or settled round. | Every change is tested; the second test pins the refinement over the reviewer's literal suggestion. |
| `test/LightsLaunch.t.sol` | Added six offline tests for the exact launch configuration: raw factory CREATE2 deployment on an empty chain, runtime limits and forbidden opcodes, absence of administrative entry points, settlement and payouts after round 1000, delayed deployment reading history from 1001, and acceptance of well-formed but false core history. | Rehearse the factory's actual constructor encoding and zero-ETH deployment, preserve game behaviour, and reproduce the imported audit's external trust assumption. The factory probe and dependency mocks are test fixtures only. |
| `README.md` | Recorded the approved constructor fields, deployment boundaries and start-round check. Corrected the claim that nobody can change SqueekCore's records and explained its upgrade risk. Revision 2: one sentence on how the unreadable stall is measured. | Provide the launch handoff and accurately disclose imported finding `aaf8dcee…`. |
| `ADAPTATION.md` | Recorded the adaptation decision, audit dispositions and checks. | Required launch adaptation record. |

## Revision 2: the reopening findings

### `4e170c7724a8f68dd3b741381bd3d0bfda21be12798f7883c2bcbdf149e88da7` (medium): unreadable stall measured from the cursor

**Reproduced.** The proof `Proof_4e170c7724a8.t.sol` fails on the starting tree at `assertFalse(voided)`: two
one-block read failures 145 rounds apart, with nobody calling the contract in between, void a game whose
finished night the core still serves.

**What was changed.** The root cause the finding names is real in one family of cases: the cursor is the last
round the walker *processed*, and a bet reads one page (16 running rounds), a collect two. After a long run the
cursor can sit far behind a core that was read fine in the same block, and one failed read in the next block
made that a "144-round" stall at once. `readThrough` now records the last round the core had settled on every
read without a failure, and the unreadable kind counts from `max(cursor, readThrough)`. The reviewer's literal
suggestion (record on every successful `state()` call) was not used: a core whose `state()` answers while its
pages cannot be read (audit_time T2b, a reply in another shape) would then have its mark pushed forward by
every bet, so the exit would never open and the funds would be locked. `test_aStateReplyWithAnUnreadablePageIsNotARead`
pins that. No rule, limit or constant changed; `RULES.md` already says "can't be read, for 144 rounds".

**Why the proof still fails, and is disputed.** The proof's scenario and the suite's canonical stall
(`test_stallAndVoid`, `LightsGas`, `LightsFuzz`, `LightsInvariant`, `MoneyChecks._void`, audit_time T2b) are
indistinguishable to the contract. In both, at the flag block the core does not answer and the contract's
storage is the same (cursor, `readThrough`, no flag); at the void block, 24 h later, the core again does not
answer and nothing has called the contract in between (the proof's only call is the view `stalled()`, which
writes nothing). A deterministic contract that sees the same storage and the same replies must give the same
answer, and the suite, the rules ("if it is still stuck the same way 24 hours later, anyone can end the game")
and T2b require that answer to be a void: otherwise a core that is permanently unreadable locks every stake
forever. Satisfying the proof would therefore need one of: (a) refusing or clearing the unreadable-kind void in
general, which contradicts T2b and the rule; (b) a new stall rule (for example a first-failure record before a
flag may go up, or a 48 h clock from the flag), which the brief forbids ("do not change the game's rules") and
which the proof itself also contradicts, since it requires the flag to succeed at the first observed failure
with `stallMark == 99`; or (c) making the view `stalled()` write state so that the proof's own call records a
read, which games the test rather than fixing anything. The remaining exposure is inherent to a contract with
no admin that learns about the core only when someone calls it: a stall can only be established by observation,
and any bet, collect or `poke` during the 24 h clears the flag. The reviewer's variant ("any poke between steps
4 and 5 … void() clears the flag") describes exactly that, and it holds on the new code too. The launch-time
remark (a deployment landing more than 144 rounds after round 1000 is flaggable in its first block if the core is
unreadable then) is the same observation case; the first bet, collect or `poke` records `readThrough`, and a
flag alone changes nothing.

### `70922547fab312cfb97fa3aa71a49d96ecf1998d9bb914fe24fe554be424202b` (low, advisory): 7-day void in a departure round

**Reproduced, left alone.** A scratch test confirmed the story: night 0 a false start that rolls 10,000 SQK,
Bob bets for the next ride, he departs in round 1110, and 100 s into that round (core settled through 1109)
`asleepTooLong()` is true and `void()` ends the game; Alice gets her 10,000 back and Bob his 100. This is the
written rule in `RULES.md` ("if he hasn't run at all for 7 days, anyone can end the game straight away") applied
to certified rounds, which are the only rounds the core serves: `roundPage` with a bound past
`settledThroughRound` reverts `InvalidRoundPageBounds`, so the contract cannot see the round in progress. Any
fix (a flag-and-wait for the 7-day exit, or a quiet-current-round condition) changes the rule, which the brief
forbids and the reviewer agrees is the requester's decision. Recorded here as an open design question for the
requester; no code or test changed for it.

## Why no contract adaptation is needed

The supported constructor is already `constructor(Config memory cfg)`, nonpayable and fully configured
without initialization. The fields are, in this exact order:

| Field | Type | Approved value |
|---|---|---|
| `core` | `address` | `0x980b4424c007caf7a1f3670b48c8eaef7ebc3d44` |
| `sqk` | `address` | `0x5501e1fa81be1c3f49225fa7668da0245d07db60` |
| `genesisTime` | `uint256` | `1793022600` |
| `station` | `uint256` | `36` |
| `startRound` | `uint32` | `1000` |

The tuple is static: `abi.encode(cfg)` equals the encoding of those five plain arguments, exactly 160
bytes, with no outer offset. The new factory test deploys the existing bytecode with the plain-word
encoding and checks all five stored values and the predicted CREATE2 address. Flattening the Solidity
constructor would add an unnecessary ABI change and require changing existing tests.

The constructor only validates configuration and writes immutables and the walker's cursor; it does not
call the core or token, check their code, require a particular block time, or give the factory a role.
It succeeds with both dependency addresses empty. `LightsMath` functions are internal; both creation
and runtime artifacts have empty library link references. `ISqueek.sol` supplies interfaces, not another
application to deploy. After revision 2 the built creation bytecode is 17,517 bytes and the runtime is
16,956 bytes, within the 49,152-byte and 24,576-byte limits. The runtime passes the same reachable-opcode
scan as the supplied protected floor (`test_factoryDeploymentRuntimeMeetsLaunchFloor` in `test/LightsLaunch.t.sol`).

No token, pool, owner, administrator, pause, proxy or upgrade mechanism was added. All original tests,
build configuration and dependencies are unchanged. No dependency installation was needed. The manifest
and actual deployment belong to the following launch steps; no `launch.json` or broadcast was produced.

## Imported audit disposition

- **`da4e884ad753ef7321a57265b6c85f6209f2583919f3f4a3b93879d03678bdc0` — coverage, informational.**
  The unchanged baseline reproduced 103 passing tests with the supplied seed, including the three earlier
  audit suites, fuzzing, invariants, real-round replays and vectors. Reviewed all three production files,
  the mocks, and the prior money/time/attack proofs. Rechecked constructor compatibility, linked code,
  runtime limits, core page semantics and SQK's interface as described below. No failing example or
  contract defect was reproduced, so no speculative contract fix was made. This is supporting evidence,
  not a claim that testing proves absence of defects.
- **`aaf8dcee06389bb3c8b4a5d6954327862ddc75ea7a196541ab211cc6e3226769` — external trust, informational.**
  Reproduced the reported EIP-1967 implementation and admin slot values at the supplied SqueekCore
  address. The new `test_wellFormedCoreHistoryIsAnExternalTrustAssumption` first supplies quiet history
  and observes no night, then substitutes ordered, increasing-work records for the same interval and
  observes two lit bulbs. Both responses satisfy the page validator; the second does not trigger a
  stall. This models the effect of a core upgrade, not an unprivileged exploit of LightsOn. The design
  intentionally trusts the core's records, so its settlement rules were preserved and the README was
  corrected. Existing regression tests cover malformed replies, missing code, failed reads and the
  delayed void/refund path. Those protections do not authenticate well-formed history.

Neither imported item recommends a contract change. The earlier money, time and attack fixes are
already present in the supplied code and their regression tests pass.

## Live dependency checks

Read-only RPC source: [Sepolia PublicNode](https://ethereum-sepolia-rpc.publicnode.com), chain ID
`11155111`, pinned block **12048326**. These reads are observations at that block; they are not required
by the offline tests and do not guarantee future behaviour after a core upgrade.

| Read | Result |
|---|---|
| SqueekCore EIP-1967 implementation slot | `0x284747c4664af2203e7a90a2ee76f22b6b5e6889` |
| SqueekCore EIP-1967 admin slot | `0x4a8ea91a43eeecb8cffc73631627a7d6f973fdbf` |
| `state()` | Decodes as the interface's eight words; settled through round `1003`, `paused = false`. |
| `roundPage(998, 1000, 16)` | Certifies through `1000`, no records, start and end positions equal. This confirms both `999` and `1000` are quiet, satisfying the existing T5 start-round check. |
| `roundPage(990, 1003, 16)` | Certifies through `1003`, no records, start and end positions equal. |
| `roundPage(44, 80, 9)` | Nine records, certifies through `54`, ending cumulative work `4815`. |
| `roundPage(44, 80, 16)` | Sixteen records, certifies through `78`, ending cumulative work `7692`. |
| `roundPage(44, 45, 0)` | Certifies only through `44`, consistent with round `45` being active. |
| SQK `symbol()` / `decimals()` | `SQK` / `18`. |
| SQK zero-value `transfer` via `eth_call` | Returns `true`. |
| SQK `burn(1)` via `eth_call` from SqueekCore, whose SQK balance is zero | Reverts with `ERC20InsufficientBalance(core, 0, 1)`, consistent with burning the caller's balance. |

The fixed start cursor is historical. Deploying later still walks from round 1001; it must not be
replaced with the deployment-time round. This is covered by the delayed-deployment test. The game has
no power to replace SqueekCore or recover from semantically false records itself.

## Verification

The baseline `forge build` passed and the baseline `forge test` passed all 103 tests. The six added
launch tests also pass independently. Final commands:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd1620a3ff330331bfee4b0f05b9fec39fb4abe4f23b313eb38f5ac63ea315f03 forge test --offline
```

Final result after revision 2: **114 tests passed, 0 failed, 0 skipped, across 14 suites** (109 before,
plus the five review regression tests). The invariant suite ran at the configured 48 runs and depth 200
with `fail_on_revert = true`. Both full test runs used the required seed. The full suite passes offline,
including the new launch and review tests; it needs no RPC, environment-provided addresses or external
launch harness. Artifact inspection confirmed the nonpayable static constructor ABI and no unlinked
libraries. The reviewer's proof `Proof_4e170c7724a8.t.sol` was run under `test/scratch/` on the starting
tree (fails) and on the result (still fails, for the reason given in its disposition); the page-budget
regression test fails on the starting tree and passes on the result.

The repository keeps its own Solidity 0.8.26 optimizer settings, `bytecode_hash = "none"`, disabled
CBOR metadata, 48 invariant runs at depth 200 and `fail_on_revert = true`. No reduced fuzz or invariant
settings were used. No Slither or Mythril run is claimed.
