# APFS Copy-on-Write Worktree Fork — Program Design

## Design inputs and structural crux

This design realizes the observable contract in
[specification.md](./specification.md), authorized by
[requirements.md](./requirements.md).

The current package already has the correct outer owners:

- `AgentStudioGitContracts` owns public Git-shaped values and
  `AgentStudioGitLocalClient`;
- `LibGit2AgentStudioGitLocalClient` routes mutations through one writer lane
  per canonical common Git directory;
- `LibGit2WorktreeWriter` owns branch/ref resolution, `git_worktree_add`,
  detached setup, validation, and rollback;
- `LibGit2BlockingReadExecutor` demonstrates the package's continuation-to-
  dispatch boundary for synchronous libgit2 work.

The current `GitRepositoryWriterLane.run` executes a synchronous closure on an
actor executor. That is adequate for short mutations but not for a multi-second
filesystem traversal. Simply awaiting background work from the actor would
permit actor reentrancy and allow another mutation to interleave.

The structural crux is therefore one transaction that simultaneously owns:

1. same-repository mutation serialization;
2. non-cooperative blocking Git and filesystem work;
3. source planning and strict APFS materialization;
4. destination Git-administration isolation;
5. index/sparse reconstruction, validation, and rollback.

Splitting those stages across public SDK calls would release transaction
custody between mutations and expose a partially usable destination.

## Alternatives and selection

| Alternative | Gain | Cost or failure | Decision |
| --- | --- | --- | --- |
| Add an optional materialization field to `GitCreateWorktreeRequest` | One method name and one writer entrypoint. | Changes the normal wire shape, couples clean checkout to fork-only result reporting, and cannot return skipped entries through the existing snapshot result. | Reject. Preserve normal creation and add a distinct fork contract. |
| Clone every top-level directory with `clonefile()` | Fastest measured many-file materialization. | Apple strongly discourages generic hierarchy cloning; nested Git pointers and runtime entries cannot be classified; one call lacks bounded cancellation and progress. | Reject as the arbitrary-worktree default. No fast path in this scope. |
| Recursive `copyfile` or `/bin/cp -cR` | Smaller implementation and mature traversal. | Both permit physical-copy fallback in cases relevant to the strict storage promise; process/callback policy is too coarse for nested Git administration. | Reject. They remain comparative evidence only. |
| Iterative plan plus strict per-leaf cloning | Exact nested policy, hard-link preservation, bounded cancellation, truthful failures, and no byte-copy fallback. | More syscalls and application code; slower raw materialization than directory clone. | Select. Correctness and inspectability carry the cost. |
| Reject initialized submodules, sparse worktrees, or nested repositories | Much smaller first version. | Violates the accepted requirement to reuse prepared real worktrees and moves the storage cost back to the user. | Reject. Model and re-home them explicitly. |

The selected design spends complexity inside one local writer transaction. It
does not add persistence, a service, a production Git subprocess, product
topology state, or a cross-platform copy abstraction. Reconsider a directory
fast path only if a future contract identifies opaque, controlled cache roots
whose contents require no nested classification and whose measured gain
outweighs the filesystem-health and cancellation cost.

## Target composition

```text
AgentStudioGitLocalClient
  owns public normal-create and fork-worktree behavior
  consumed by SDK clients and conforming test doubles
  changes when the public Git data-plane contract changes

GitRepositoryWriterLane
  owns FIFO execution of complete mutations for one common Git directory
  exposes async submission to a dedicated serial blocking queue
  consumed by every local mutation
  changes when repository mutation scheduling changes

LibGit2WorktreeWriter
  owns existing normal worktree creation without semantic changes
  consumed by the local client
  changes when normal Git worktree mutation changes

LibGit2WorktreeForkWriter
  owns the complete fork transaction and phase state
  consumes planner, materializer, Git-state re-homer, and rollback journal
  changes when fork ordering or success invariants change

WorktreeForkPlanner
  owns immutable source classification and the captured Git/filesystem plan
  consumes libgit2 facts and descriptor-relative filesystem metadata
  changes when eligibility or entry/Git-topology policy changes

APFSStrictCloneMaterializer
  owns destination directory/leaf realization and a fixed leaf-worker bound
  consumes the immutable plan
  changes when APFS clone or filesystem-kind realization changes

GitRepositoryStateRehomer
  owns destination-safe submodule/nested-repository administration and indexes
  consumes planned Git nodes and their captured state
  changes when nested Git isolation or sparse/index rules change

WorktreeForkValidator
  owns final fork-specific invariant checks and the materialization report
  consumes plan, destination repositories, and materializer observations
  changes when the public success claim changes

WorktreeForkRollbackJournal
  owns transaction-created artifact identity, compensation, and residue proof
  consumed only by the fork writer
  changes when a phase creates a new recoverable side effect
```

These boundaries are not general-purpose copy or transaction frameworks.
`WorktreeForkPlanner` exists because classification must finish before mutation;
`GitRepositoryStateRehomer` exists because Git administrative truth has
different invariants from working-file materialization; the validator exists
because ordinary `validateWorktree` does not prove the fork contract.

## Ownership and dependency rules

| Truth or side effect | Sole owner | Allowed consumers | Forbidden edge |
| --- | --- | --- | --- |
| Public fork request/result encoding | `AgentStudioGitContracts` | local client and external SDK clients | local implementation inventing unreported variants |
| Per-common-directory mutation order | `GitRepositoryWriterLane` | every local writer | a writer bypassing the lane or releasing custody during rollback |
| Captured root/nested `HEAD`, source entry set, hard-link groups, sparse state, Git-node classification | `WorktreeForkPlanner` | materializer, re-homer, validator | workers rediscovering policy independently |
| Root branch/ref and linked-worktree metadata | `LibGit2WorktreeForkWriter` through libgit2 | re-homer and validator read it | filesystem code creating root `.git` administration |
| Working-entry creation | `APFSStrictCloneMaterializer` | validator observes results | Git-state code copying arbitrary working payloads |
| Submodule/nested Git administration and index state | `GitRepositoryStateRehomer` | validator | ordinary entry copying of `.git`, `commondir`, alternates, indexes, or locks |
| Compensation and residue report | `WorktreeForkRollbackJournal` | fork writer | best-effort cleanup whose errors are discarded |
| Final success | `WorktreeForkValidator` supplies evidence; fork writer publishes | public client | returning the ordinary snapshot validation as fork success |

Production code MUST NOT invoke the Git CLI. Libgit2 owns Git identity and
index/ref operations; Darwin filesystem APIs own APFS and entry realization.

## Public and internal interface behavior

### Protocol compatibility

`AgentStudioGitLocalClient` gains the Specification's `forkWorktree` requirement
plus a protocol-extension default that throws a stable capability-unavailable
`GitWorktreeForkError`. Existing conformers therefore retain source
compatibility. The concrete libgit2 client overrides it and submits the
transaction to the same repository lane selected from `sourceWorktreePath`
identity.

Fork-only failures live in the new `GitWorktreeForkError` union. Existing
libgit2/Git failures are wrapped as a payload rather than adding cases to
`GitDataPlaneError`; this preserves the latter's encoding and downstream
exhaustive switches.

The existing `createWorktree` method, request, writer path, and return value do
not delegate through fork logic. This makes an unavailable CoW platform
irrelevant to normal creation and preserves normal request encoding without
custom compatibility shims.

### Repository mutation submission

`GitRepositoryWriterLane` keeps actor-owned lane identity but changes execution
from direct actor closure invocation to asynchronous submission onto one
dedicated serial blocking queue per repository identity. Its behavioral
interface is:

- accept a `@Sendable` synchronous mutation closure and `Sendable` result;
- enqueue mutations FIFO on the lane's serial queue;
- resume the async caller with exactly that closure's result or error;
- keep queue custody until all child workers and rollback complete;
- never execute the blocking closure on the caller, MainActor, or Swift
  cooperative executor.

Existing short mutations use the same interface, preserving order while moving
their blocking work to the appropriate execution domain. Reads remain on the
existing blocking read executor and are not serialized with writes; the fork
contract does not promise read isolation or external-process isolation.

### Immutable fork plan

`WorktreeForkPlanner` returns one immutable, `Sendable` plan containing:

- canonical source and destination roots plus open root descriptors;
- runtime/volume capability evidence;
- captured root and nested repository `HEAD` OIDs;
- selected branch mode and its validated destination identity;
- parent-before-child directories and child-before-parent metadata finalizers;
- regular files, symbolic links, FIFOs, unsupported entries, and Unix sockets;
- `(device, inode)` hard-link groups;
- registered submodule paths and initialized/uninitialized state;
- independent nested repository nodes and resolved administrative topology;
- sparse patterns, relevant worktree configuration, and an effective
  skip-worktree map for each initialized Git node, derived without requiring a
  sparse-index file to be readable by libgit2;
- every alternate/common Git store that must receive a destination-owned CoW
  mirror;
- planned entry counts, logical sizes, and metadata expectations.

Planning rejects overlap, containment escapes, unsupported special files,
cross-filesystem administrative stores, and any Git node whose independent
destination topology cannot be constructed. A socket is a planned skip, not an
unsupported entry.

## Normal call path and proposed fork call path

Current normal creation before this design is:

```text
client.createWorktree(request)
  ──► resolve repository identity and writer lane
  ──► actor-isolated lane directly runs synchronous writer closure
  ──► resolve/create ref
  ──► git_worktree_add with normal checkout
  ──► detach when requested
  ──► ordinary linked-worktree validation
  ◄── GitWorktreeSnapshot or GitDataPlaneError
```

The scheduling delta for every existing mutation is deliberately narrow:

| Edge | Delta | Ownership/effect/result |
| --- | --- | --- |
| client to repository lane | Intentionally unchanged | Async call selects the lane by canonical common-directory identity. |
| lane actor to mutation closure | Changed | The actor enqueues onto its dedicated serial blocking queue instead of executing on the cooperative executor. |
| blocking queue to existing writer | Added | The same synchronous writer and libgit2 side effects run FIFO off the cooperative executor. |
| writer result/error to caller | Intentionally unchanged | The continuation returns the existing typed result or error after the queued mutation finishes. |

The new fork path has no predecessor:

```text
client.forkWorktree(request)
  ──► resolve source repository identity and writer lane
  ──► enqueue one complete blocking transaction
      ──► capture HEAD and build WorktreeForkPlan
      ──► create/validate destination branch identity
      ──► git_worktree_add with GIT_CHECKOUT_NONE
      ──► materialize working entries with bounded strict-clone workers
      ──► re-home initialized submodule and nested-repository administration
      ──► rebuild root and nested indexes from captured HEAD trees
      ──► reapply sparse configuration and skip-worktree semantics
      ──► validate every plan/result/Git-isolation invariant
      ◄── GitForkWorktreeResult

  any failure or cancellation after mutation
      ──► stop and join leaf workers
      ──► compensate and verify every rollback-journal entry
      ◄── primary typed failure or cleanup-incomplete typed failure
```

The result/error edge resumes the caller only after the serial repository queue
has completed validation or cleanup. No continuation crosses a live libgit2
pointer or mutable rollback journal.

## Transaction state and legal transitions

| State | Mutation present | Legal next state | Invariant |
| --- | --- | --- | --- |
| `queued` | No | `planning`, `failedClean` | No work executes outside lane order. Cancellation before execution returns cleanly. |
| `planning` | No | `creatingIdentity`, `failedClean` | Source is read-only; planning failure or cancellation has nothing to compensate. |
| `creatingIdentity` | Branch may exist | `creatingWorktree`, `rollingBack` | Every attempted artifact is journaled even if libgit2 returns failure. |
| `creatingWorktree` | Branch, admin, or destination may exist | `materializing`, `rollingBack` | Root `.git` is destination-created, never source-copied. |
| `materializing` | Partial destination | `rehomingGitState`, `rollingBack` | Only planned entries appear; no byte-copy fallback. |
| `rehomingGitState` | Partial nested administration | `buildingIndexes`, `rollingBack` | No copied pointer is accepted as final administration. |
| `buildingIndexes` | Working tree complete; indexes provisional | `validating`, `rollingBack` | Every index derives from its captured HEAD plus sparse flags, never source staging. |
| `validating` | Complete but unpublished to caller | `succeeded`, `rollingBack` | Full fork-specific validation, not ordinary worktree validation alone. |
| `rollingBack` | Residue possible | `failedClean`, `failedWithResidue` | No new work admitted; every journal entry receives a verified disposition. |
| `succeeded` | Valid destination | Terminal | Return snapshot/report and release lane. |
| `failedClean` | None created by transaction | Terminal | Return primary failure and release lane. |
| `failedWithResidue` | Explicit verified residue | Terminal | Return cleanup-incomplete failure with residue; never success. |

Cancellation can request transition from any nonterminal state. Before mutation
it terminates directly; after mutation it always transitions through
`rollingBack`. Other same-repository mutations cannot execute between these
states.

## Strict filesystem realization

The planner performs an iterative shallow URL/metadata walk while retaining
root-relative path components. Source and destination root descriptors are the
containment authority; lexical string prefixes are not.

The materializer creates directories in parent-before-child order, then uses a
fixed pool of four blocking leaf workers. Four is the current measured default,
not a public constant. Each regular file uses descriptor-relative
`clonefileat` with final-symlink non-following, intermediate-symlink rejection,
and beneath-root resolution. Any clone failure is returned to the transaction.

Before a worker can inspect or clone a regular file, it sets the thread-scoped
`IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` policy to
`IOPOL_MATERIALIZE_DATALESS_FILES_OFF` and verifies that policy change. The
worker restores its prior policy before returning. An inability to establish
the policy is a strict-clone failure; it never proceeds under the host
process's ambient default. This makes a dataless source fail deterministically
instead of allowing `clonefileat` to trigger File Provider materialization.

For each hard-link group, one planned path becomes the primary APFS clone and
remaining paths use descriptor-relative hard linking to that destination
inode. Symlinks are reproduced from their link text, FIFOs with `mkfifoat`, and
sockets become report entries with no destination node. Directory metadata is
applied after children so traversal permissions and final timestamps do not
fight each other.

Workers execute mechanics only. They do not change classification, retry by
byte-copying, discover new entries, or decide whether an error is skippable.
They check cancellation between entries and stop accepting work after the first
failure. The transaction queue waits for all admitted workers before rollback.

The plan is intentionally not a snapshot. A new source entry after its parent
enumeration is omitted. Before each materialization operation, descriptor-
relative metadata is checked against the planned kind and identity; deletion,
kind replacement, or containment failure aborts the transaction. This yields
the Specification's explicit mixed-time traversal semantics without claiming
cross-file atomicity.

## Git-administration isolation

### Classification

The planner combines the captured `HEAD` tree's gitlinks, `.gitmodules`,
libgit2 repository discovery, and on-disk Git files to classify every `.git`
entry. Classification never requires the source index merely to discover
registered submodules:

1. exact source root administration — never copied;
2. registered uninitialized submodule — remains absent/uninitialized;
3. registered initialized submodule — re-homed beneath the destination
   superproject worktree's `$GIT_DIR/modules/...` hierarchy;
4. independent nested repository with an embedded `.git` directory — copied
   into destination-owned nested administration;
5. independent nested gitfile or linked worktree — its worktree-private and
   common administration are flattened or mirrored into destination-owned
   nested administration;
6. malformed or unresolvable Git pointer — planning failure.

Classification recurses through initialized submodules and nested repositories.
A directory named `.git` that libgit2 does not recognize as administration is
still treated conservatively: it must be proven ordinary and safe or the fork
fails.

### Re-homing algorithm

For each initialized Git node, `GitRepositoryStateRehomer`:

1. assigns a destination-owned administrative root appropriate to its parent;
2. strict-CoW clones portable repository data such as object databases,
   refs/packed refs, shallow data, and sanitized configuration;
3. excludes lock files, source indexes, and in-progress merge/rebase/
   cherry-pick/bisect operation state;
4. captures and writes the node's `HEAD` identity from the plan;
5. replaces worktree pointers with a destination `.git` file or embedded
   directory pointing only to destination-owned administration;
6. removes or rewrites `core.worktree` and `commondir` for the destination;
7. maps each object alternate to a destination-owned CoW mirror, recursively,
   deduplicating canonical source object stores within the plan;
8. opens the destination repository through libgit2 and proves every captured
   `HEAD` and ref required for usability resolves without a source-specific
   administrative path.

An alternate or common store on a different filesystem fails preflight because
it cannot be mirrored under the strict CoW contract. Git symbolic refs and
ordinary repository data are preserved; transient process locks and operation
sequencer state are intentionally not inherited, consistent with rebuilding
the index rather than copying source staging.

### Index and sparse reconstruction

The planner owns sparse intent without assuming libgit2 can open every source
index. Libgit2 1.9 rejects Git's mandatory sparse-index extension, so the source
index is an optional optimization rather than an authority required for a
successful sparse fork.

For each initialized Git node, the planner:

1. reads the captured `HEAD` tree as the complete tracked-path and gitlink
   authority;
2. reads the worktree-specific sparse configuration and sparse-checkout pattern
   file directly from the resolved source administration;
3. uses a package-owned Git-compatible sparse matcher for both cone and
   non-cone pattern modes to derive the effective skip-worktree map over the
   captured tree;
4. when libgit2 can read a non-sparse source index, uses its persisted
   skip-worktree flags to confirm or refine that derived map, but never copies
   stage numbers, conflict entries, assume-unchanged flags, or stat cache;
5. treats a sparse-index source as supported input and does not ask libgit2 to
   open that source index.

The re-homer then:

1. reads the captured `HEAD` tree into a new full destination index;
2. applies the plan's effective skip-worktree map;
3. reproduces sparse patterns and relevant worktree-specific configuration
   under destination administration while leaving sparse-index compression
   disabled;
4. writes and reopens the destination index;
5. validates index flags and sparse-absent filesystem paths directly against
   the immutable sparse plan rather than depending on libgit2 status to infer
   the flags correctly.

Real-Git integration evidence remains responsible for proving that ordinary
Git status and checkout behavior observe the resulting full sparse index
without reporting intentionally absent paths as deletions.

This preserves sparse observable behavior while making all staged, conflicted,
or in-progress source content ordinary destination working-tree differences.

## Validation and publication

`WorktreeForkValidator` is separate from `LibGit2WorktreeReader` because the
latter proves only that a worktree can be opened and described. Fork validation
checks:

- root worktree identity, branch/detached mode, and captured `HEAD` OID;
- plan-versus-destination path kinds and counts;
- one successful strict clone observation per required regular payload;
- destination inode equality within each hard-link group and separation from
  the source inode namespace expected after APFS clone;
- every recreated FIFO count, socket skip, and metadata normalization appears
  in the report's corresponding field without classifying a created node as
  skipped;
- root and nested index trees, status semantics, and sparse behavior;
- initialized submodule and nested repository open/status operations;
- uninitialized submodules remain uninitialized;
- canonical resolution of `.git`, `commondir`, `core.worktree`, and alternate
  paths does not enter source-worktree-specific administration;
- no transaction lock or temporary artifact remains.

Only the fork writer may turn those observations into
`GitForkWorktreeResult`. Agent Studio topology publication is outside this SDK;
external Git processes may observe the linked-worktree registration during the
transaction.

## Failure, recovery, and residue

The rollback journal is created before the first mutation. It records the
preflight absence/presence and expected identity of:

- a transaction-created branch;
- the linked-worktree name and administrative path;
- the destination root;
- each destination-owned nested/submodule administrative root;
- temporary or alternate-mirror roots.

An attempted `git_worktree_add` is journaled before the call. Cleanup probes
the expected destination and administrative paths even when libgit2 returns an
error, because libgit2 may create administration before failing to create or
populate the working directory.

Recovery order is:

```text
stop admission and join all leaf workers
  ──► close destination Git/index handles
  ──► remove journaled working and nested-administration paths
  ──► prune journaled linked-worktree administration
  ──► delete only the journaled transaction-created branch
  ──► re-probe every journal entry
  ──► return primary error when clean
       or cleanup-incomplete error with ordered residue
```

Cleanup operations are idempotent: an already absent transaction-owned path is
clean, while a path whose current identity no longer matches the journal is not
deleted and is reported as residue. No cleanup error is discarded. The journal
is in-memory and scoped to the call; the design intentionally adds no crash
recovery database or startup scan.

## Concurrency and consistency

| Overlap | Rule | Mechanism and consequence |
| --- | --- | --- |
| Two SDK mutations of one common Git repository | Never interleave. | Same serial blocking writer queue; the second operation waits through validation or rollback. |
| Mutations of unrelated repositories | May progress independently. | One serial queue per canonical repository identity. |
| Four leaf clones within one fork | May overlap after plan classification. | Fixed blocking worker pool; first failure stops admission, then all admitted work joins before cleanup. |
| SDK reads during a fork | May observe intermediate on-disk state. | Existing read executor remains independent; no read-isolation promise. Product publication waits for the returned result. |
| External Git/filesystem mutation | Not serialized and may cause mixed-time capture or failure. | Descriptor-relative kind/containment checks plus final validation; no source lock or false snapshot claim. |
| Cancellation and queued mutation | Queue custody remains with the cancelled fork until cleanup completes. | Cancellation flag is observed by planner/workers; continuation completes only after terminal state. |

The serial queue is the transaction boundary, not the actor's suspension state.
The plan and worker results are immutable Sendable values. Libgit2 handles,
mutable error capture, and the rollback journal remain on the serial blocking
queue. Root descriptors may move only within the transaction's blocking domain
from that queue to its admitted leaf workers; they never cross into actor or
cooperative-executor code and never escape through the caller continuation.

## Compatibility and cutover

There is no runtime migration or dual source of truth.

1. Existing normal creation continues through the current writer semantics,
   now scheduled on the serial blocking lane.
2. Existing conformers inherit the default unsupported fork implementation.
3. The concrete libgit2 client implements the new method on macOS 26+ while
   preserving the package's macOS 14 deployment target.
4. New Codable types and the separate fork error are additive. Existing
   `GitDataPlaneError` and old request encoding are verified byte-for-byte and
   are never rewritten through a new materialization enum.

The behavioral cutover is per call: only an explicit `forkWorktree` request can
enter the new transaction. There is no feature flag, implicit APFS upgrade of a
normal create, or fallback from fork to normal checkout.

## Cross-cutting realization

| Obligation | Owner and mechanism | Failure/degradation | Proof seam |
| --- | --- | --- | --- |
| Strict storage truth | planner preflight plus materializer per-file clone result under worker-scoped dataless-materialization denial | inability to deny materialization or any required payload clone failure rolls back; never download or byte-copy | APFS fixture plus dataless non-materialization, physical-allocation, and divergence observation |
| Source/destination containment | planner root descriptors and descriptor-relative operations | escape or type race aborts | adversarial symlink/race integration fixture |
| Git independence | state re-homer and validator canonical-pointer scan | unresolved/source-specific pointer aborts | real Git commands and canonical admin-path inspection |
| Reliability | fork writer state machine and verified rollback journal | cleanup failure becomes explicit residue error | phase failure injection and residue fixture |
| Responsiveness | serial blocking queue plus bounded blocking leaf pool | same repo waits; unrelated repos and caller executor remain live | deterministic admission acknowledgements and concurrency integration |
| Platform compatibility | runtime capability preflight at fork entry only | typed unavailable reason; normal APIs unaffected | platform/capability unit seams and supported-host integration |
| Privacy | report paths are relative/redacted; all ignored contents remain local | no network or telemetry surface is added | contract encoding and path-redaction tests |
| Accessibility | Not applicable: SDK-only, no UI or human interaction surface. | — | — |

## Requirement, realization, and proof trace

| Requirement | Observable contract | Realization owner | Proof boundary |
| --- | --- | --- | --- |
| U-01, U-12 | normal API/encoding unchanged; additive source-compatible fork API | contracts, protocol default, unchanged normal writer | public contract and normal integration suites |
| U-02, U-03 | copied filesystem with captured-HEAD index/status matrix | planner, fork writer, index reconstruction | real dirty/ignored repository status integration |
| U-04, U-05 | strict regular-data CoW on eligible APFS only | preflight and strict materializer | real APFS allocation/divergence and rejection integration |
| U-06, U-07 | submodule/nested/sparse/hard-link usability and independence | planner's HEAD-tree sparse evaluation plus Git state re-homer | recursive real-Git fixtures, cone/non-cone sparse-index sources, and pointer/index/inode inspection |
| U-08 | no success with partial transaction; verified residue when cleanup fails | rollback journal and serial transaction | failure injection at every state transition |
| U-09 | validated snapshot plus truthful ordered report | validator and public result types | report-policy unit tests and special-entry integration |
| U-10 | nonblocking caller execution and same-repository non-interleaving | blocking writer lane and bounded workers | deterministic concurrent-mutation integration |
| U-11 | mixed-time contract and independent post-clone divergence | planner race rules and APFS clone | controlled source mutation plus bidirectional divergence fixture |
| U-13 | behavioral, Git, APFS, rollback, concurrency, and performance evidence | all owners expose real seams above | unit/integration/performance evidence kept distinct |

The production path itself is the integration-test path: fixtures use real
libgit2, filesystem entries, APFS clones, Git administration, and indexes.
Fakes are appropriate only for pure capability classification, entry-policy,
plan, report, rollback-decision, and failure-injection seams. Performance and
allocation measurements supplement rather than replace behavioral assertions.

## Structural limits and revisit signals

This design intentionally does not include product topology hiding, progress
callbacks, persistent recovery, secret filtering, source locking, a generic
filesystem copier, a directory-clone fast path, or an alternate-base overlay.

Reopen the structure if evidence shows one of these:

- representative prepared repositories cannot meet an owner-set latency budget
  with bounded leaf cloning and index construction;
- destination-safe re-homing cannot support a legitimate Git administrative
  form without a production Git CLI;
- external visibility of the in-progress linked worktree becomes a product
  requirement rather than an SDK publication boundary;
- crash residue is common enough to justify a separately authorized durable
  recovery design;
- metadata normalization prevents independently usable results in real source
  worktrees.
