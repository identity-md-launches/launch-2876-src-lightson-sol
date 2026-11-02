# Launch adaptation

`LightsOn` already satisfies the contracts-only factory requirements. Its production source, game rules,
limits, maths and ABI are unchanged. The launch deploys only `src/LightsOn.sol:LightsOn` on Sepolia
(`11155111`), using the existing SQK and SqueekCore contracts.

## Changes and reasons

| File | Change | Requirement or finding |
|---|---|---|
| `test/LightsLaunch.t.sol` | Added six offline tests for the exact launch configuration: raw factory CREATE2 deployment on an empty chain, runtime limits and forbidden opcodes, absence of administrative entry points, settlement and payouts after round 1000, delayed deployment reading history from 1001, and acceptance of well-formed but false core history. | Rehearse the factory's actual constructor encoding and zero-ETH deployment, preserve game behaviour, and reproduce the imported audit's external trust assumption. The factory probe and dependency mocks are test fixtures only. |
| `README.md` | Recorded the approved constructor fields, deployment boundaries and start-round check. Corrected the claim that nobody can change SqueekCore's records and explained its upgrade risk. | Provide the launch handoff and accurately disclose imported finding `aaf8dcee…`. |
| `ADAPTATION.md` | Recorded the adaptation decision, audit dispositions and checks. | Required launch adaptation record. |

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
application to deploy. The built creation bytecode is 17,369 bytes (17,529 including constructor data),
and the runtime is 16,808 bytes, within the 49,152-byte and 24,576-byte limits. The runtime passes the
same reachable-opcode scan as the supplied protected floor.

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

Final result: **109 tests passed, 0 failed, 0 skipped, across 13 suites**. The invariant run completed
48 runs and 9,600 calls with zero reverts. Both full test runs used the required seed. The full suite
passes offline, including the new launch tests; it needs no RPC, environment-provided addresses or
external launch harness. Artifact inspection confirmed the nonpayable static constructor ABI and no
unlinked libraries. A final change-list check confirmed that only the three files listed above differ.

The repository keeps its own Solidity 0.8.26 optimizer settings, `bytecode_hash = "none"`, disabled
CBOR metadata, 48 invariant runs at depth 200 and `fail_on_revert = true`. No reduced fuzz or invariant
settings were used. No Slither or Mythril run is claimed.
