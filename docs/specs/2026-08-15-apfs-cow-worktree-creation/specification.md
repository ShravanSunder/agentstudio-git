# APFS Copy-on-Write Worktree Fork — Specification

## Contract boundary

This Specification defines what `agentstudio-git` callers may observe. Its
Requirements source is [requirements.md](./requirements.md). Internal
components, syscall structure, transaction ordering, and proof seams belong to
[program-design.md](./program-design.md).

The package exposes two different operations:

```text
normal create
  commit and Git checkout are the filesystem source of truth

APFS CoW fork
  one source worktree's current filesystem is the byte source of truth
  its captured HEAD is the destination Git/index source of truth
```

The CoW fork does not replace or alter normal creation.

```text
Agent Studio and other Swift SDK clients
  ──► normal create request
  ──► APFS CoW fork request
       │
       ▼
  AgentStudioGitLocalClient as one opaque SDK boundary
       │
       ├─ normal result/error with the existing contract
       └─ fork result/report or fork-specific typed error

Existing third-party/test conformers
  ──► retain normal behavior
  └─ fork defaults to an explicit unavailable result until implemented

Outside the boundary
  Agent Studio UI, topology publication, secret policy, and crash recovery
```

## Developer journey

| Step | Current observable pain | Required observable difference | Requirement |
| --- | --- | --- | --- |
| Select a prepared source worktree | It may contain dependencies, build caches, generated files, dirty edits, submodules, or nested repositories that normal creation discards. | The fork accepts the existing worktree path as its source. | U-02, U-06 |
| Select destination Git identity | A different base would make the copied filesystem an ambiguous overlay. | Every fork identity resolves to the source's captured `HEAD`. | U-03 |
| Create | Normal checkout rewrites files; naive copying can duplicate data or preserve unsafe `.git` pointers. | Regular-file payloads are APFS clones and Git administration is destination-safe. | U-04, U-07 |
| Start work | Source staging must not leak, and later changes must not cross between copies. | The destination index represents captured `HEAD`; both filesystems diverge independently. | U-03, U-11 |
| Diagnose omissions or failure | A snapshot alone cannot explain skipped runtime entries or incomplete cleanup. | Success includes a materialization report; failure includes typed cause and any cleanup residue. | U-08, U-09 |

## Public SDK surface

### Existing normal creation

The package MUST preserve this method and its current behavior:

```swift
func createWorktree(
    _ request: GitCreateWorktreeRequest
) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
```

`GitCreateWorktreeRequest(repositoryPath:destinationPath:mode:)`, its
three-argument initializer, its three current modes, and its encoded field
shape MUST remain unchanged. Decoding an existing payload MUST continue to
produce the same normal request. Existing normal success and failure behavior
MUST not depend on CoW availability.

### New CoW fork

The package MUST add a separate method:

```swift
func forkWorktree(
    _ request: GitForkWorktreeRequest
) async throws(GitWorktreeForkError) -> GitForkWorktreeResult
```

`GitForkWorktreeRequest` MUST contain:

- `sourceWorktreePath`: an existing main or linked worktree whose filesystem
  state will be captured;
- `destinationPath`: a nonexistent destination on the same clone-capable APFS
  filesystem;
- `mode`: a `GitForkWorktreeMode` selecting `.existingBranch(name:)`,
  `.newBranch(name:)`, or `.detached`.

The fork mode contains no arbitrary start point. A new branch is created at
the source's captured `HEAD`; a detached destination uses that commit; an
existing branch is accepted only if it resolves to that commit and is not
already checked out in another worktree. A mismatch MUST fail before mutation.

The new protocol requirement MUST have a default implementation that throws a
typed unsupported-capability error so existing source conformers and test
doubles continue to compile. The concrete libgit2 client MUST implement the
capability. No binary-ABI compatibility beyond Swift package source
compatibility is promised.

`GitWorktreeForkError` MUST be a new stable Codable error contract rather than
new cases on `GitDataPlaneError`. It MUST distinguish request/preflight
rejection, wrapped Git data-plane failure, source-race failure, strict-clone or
entry-policy failure, cancellation, validation failure, and cleanup-incomplete
failure. Keeping fork-only variants out of the existing public enum avoids
breaking downstream exhaustive switches over `GitDataPlaneError`.

`GitForkWorktreeResult` MUST contain:

- `worktree`: the validated `GitWorktreeSnapshot`;
- `materialization`: a `GitWorktreeMaterializationReport`.

The report MUST contain stable counts for cloned regular files, created
directories, recreated symbolic links, preserved hard links, preserved Git
repositories, recreated FIFOs, and logical regular-file bytes. It MUST also
contain two ordered entry lists with different meanings:

- `skippedEntries` records source entries that were intentionally not created
  in the destination. Every record contains a repository-relative path,
  filesystem kind, and stable reason.
- `normalizedEntries` records entries that were created but whose metadata
  could not be reproduced exactly under the allowed normalization policy.
  Every record contains a repository-relative path, affected metadata
  attribute, and stable reason.

An entry MUST NOT be described as skipped when its destination node exists.
Paths in reports and errors MUST not be absolute unless the public input path
itself is the failing value.

## Eligibility and preconditions

The operation MUST reject without mutation unless all of these are true:

- the runtime is macOS 26 or later;
- the source and destination parent are on APFS;
- both paths resolve to the same filesystem/device;
- the volume advertises file-clone capability;
- the source is a valid worktree with a resolvable `HEAD` commit;
- the destination parent already exists;
- the destination does not exist;
- source and destination roots do not overlap or contain one another;
- every initialized nested or submodule Git common directory and object
  alternate that must be mirrored resolves to that same filesystem/device;
- the selected branch mode satisfies the captured-`HEAD` rules.

The package's deployment target and all non-fork APIs MUST remain usable on
macOS 14 and later. Calling the fork on an ineligible host MUST return a stable
typed reason rather than a generic libgit2 or Foundation message.

## Filesystem capture contract

### Included state

The fork MUST plan and reproduce every source-root child except the exact root
`.git` entry, subject to the explicit rules below. Inclusion is independent of
Git tracked or ignored status. Dirty tracked files, tracked deletions,
untracked files, ignored files, dependency trees, generated output, and caches
are therefore included when present in the source traversal.

Regular-file payloads MUST be created through strict APFS clone operations. If
any required regular payload cannot be cloned, the fork MUST fail; it MUST NOT
fall back to reading and writing the payload bytes.

Directories, symbolic links, hard links, FIFOs, and Git pointer files do not
have regular-file CoW payloads and MUST be reconstructed according to their
type:

| Source entry | Destination behavior |
| --- | --- |
| Directory | Create the directory, populate its children, then reproduce representable mode, ACL, extended-attribute, flag, and timestamp metadata. |
| Regular file | Strictly APFS-clone the payload and metadata; no byte-copy fallback. |
| Symbolic link | Recreate the link text without following it and reproduce representable link metadata. |
| Multiple paths to one regular-file inode | Clone the first payload once and create destination hard links for the remaining paths. |
| FIFO | Recreate an empty FIFO node and report it as recreated; no in-flight stream state exists to copy. |
| Unix socket pathname | Do not reproduce it; return success only with a skipped-entry report identifying the socket. |
| Character or block device, or an unknown filesystem kind | Fail and roll back rather than silently omit or transform it. |
| Dataless regular file that cannot be cloned without materialization | Fail and roll back; strict CoW does not authorize a download or byte copy. |

Metadata that the calling process or APFS cannot reproduce MUST be reported.
Loss of payload, execute bits, ACL access semantics, extended attributes, or
file flags is a failure. A source ownership identity that the unprivileged
caller cannot assign MAY be normalized to the calling user only when reported;
setuid or setgid bits that macOS clears as a consequence MUST also be reported.

### Containment and source races

The operation MUST never follow a traversed source or destination path outside
the supplied roots. A symlink inserted or changed during traversal MUST not
turn into an escape.

The operation does not lock the source and does not promise a coherent
point-in-time snapshot. Its defined live-source behavior is:

- each successfully cloned regular file is an independent APFS clone of the
  version observed when that entry is cloned;
- an entry created after its parent was planned MAY be absent;
- an entry changed before it is cloned MAY contribute its newer contents;
- a planned entry that disappears, changes to an incompatible kind, or escapes
  containment causes failure and rollback;
- the operation MUST NOT reset, stage, rewrite, lock, or otherwise mutate the
  source worktree.

After an entry is cloned, later source changes MUST not propagate to the
destination. Later destination changes MUST not propagate to the source.

## Git state contract

### Root worktree and index

The destination MUST be a normal linked worktree sharing the superproject's
common Git object/ref administration. Its root `.git` pointer MUST be the one
created for the destination, never a copy of the source root `.git` entry.

The destination `HEAD` MUST remain the captured source `HEAD` commit. Its index
MUST be rebuilt from that commit without rewriting materialized working files.
Consequently:

| Source state | Destination state relative to captured `HEAD` |
| --- | --- |
| Clean tracked entry | Clean tracked entry |
| Staged or unstaged modification | Unstaged modification |
| Staged new or untracked entry | Untracked entry |
| Tracked deletion | Unstaged deletion |
| Ignored entry | Ignored entry |

### Sparse worktrees

If the source uses sparse checkout, the destination MUST preserve the source's
effective sparse patterns, worktree-specific sparse configuration, and
skip-worktree semantics while rebuilding content from captured `HEAD`.
Intentionally absent sparse paths MUST not appear as mass deletions. Sparse
index representation itself is not a compatibility promise; an equivalent
full index is acceptable when status and checkout behavior are the same.

### Initialized submodules

For each registered submodule:

- a source submodule with no populated working tree MUST remain uninitialized
  and unpopulated in the destination;
- a populated source submodule MUST retain its current working files, nested
  ignored content, and dirty state;
- its destination Git repository and index MUST be independently usable and
  associated with the destination submodule path;
- its destination index MUST represent that submodule's captured `HEAD`, so
  staging inside the source submodule is not inherited;
- its `.git`, `core.worktree`, `commondir`, object-alternate, or equivalent
  administrative pointers MUST NOT resolve into source-worktree-specific
  administration;
- recursive submodules follow the same rules.

The parent worktree's gitlink remains whatever captured superproject `HEAD`
records. If the populated submodule's captured `HEAD` differs, normal Git
status MUST report that difference.

### Independent nested Git repositories

An initialized Git repository nested inside ordinary content MUST remain an
independently usable destination repository with its working files and dirty
state preserved. A nested gitfile, linked-worktree `commondir`, or object
alternate MUST be re-homed to destination-owned administration or a
destination-owned CoW mirror. Blindly copying a source administrative pointer,
silently treating the nested repository as ordinary non-Git data, or omitting
it is forbidden.

Lock files and live process state inside Git administration MUST not be copied
as active locks. The destination repository's index MUST be rebuilt from its
captured nested `HEAD`, preserving sparse semantics but not source staging.
An in-progress merge, rebase, cherry-pick, revert, bisect, or sequencer operation
is not inherited as an active Git operation; its working files are captured
under the ordinary dirty-file rules.

## Completion, cancellation, and failure

The SDK MUST return success only after validating:

- the linked-worktree registration and selected Git identity;
- the destination index and expected status semantics;
- required entry counts and types from the materialization plan;
- strict-clone completion for every required regular payload;
- hard-link groups;
- sparse behavior;
- initialized and uninitialized submodule state;
- nested Git repository usability;
- absence of administrative pointers into source-worktree-specific state.

Cancellation is observed at bounded planning and materialization boundaries.
Once mutation has begun, cancellation MUST stop admitting new work, wait for
in-flight leaf operations, perform rollback, and then return a typed cancelled
failure. Cancellation MUST NOT release same-repository mutation serialization
before cleanup finishes.

For every synchronous error or cancellation after mutation:

1. remove destination working content created by the transaction;
2. remove linked-worktree and nested destination administration created by the
   transaction;
3. delete only a branch created by the transaction;
4. verify the absence of each recorded artifact.

If cleanup itself fails, the SDK MUST return a typed cleanup-incomplete error
containing the primary failure and a redacted, ordered list of remaining
artifact kinds and paths. It MUST never suppress cleanup failure or return a
successful snapshot. Abrupt process termination, power loss, and automatic
recovery in a later process are outside this contract.

The SDK call does not promise invisibility from external Git processes after
linked-worktree metadata is created. Its publication guarantee is that no
successful SDK result is returned until validation completes, and no other
mutation submitted through the same in-process repository lane interleaves.

## Execution and serialization

Blocking Git, filesystem traversal, cloning, index construction, validation,
and rollback work MUST execute outside the caller's Swift cooperative
executor. Mutations submitted through one SDK process for the same canonical
common Git directory MUST execute in FIFO order and MUST NOT interleave. The
fork retains that mutation position until its leaf work is joined and it has
either validated success or completed and verified rollback. Mutations of
unrelated repositories MAY proceed independently, and reads or external Git
processes remain outside this isolation guarantee.

## Compatibility and encoding

- Encoding a normal `GitCreateWorktreeRequest` MUST produce the same keys and
  case representation as before this feature.
- Existing normal request payloads MUST decode without a new field or default.
- The fork request, mode, result, report, skip reasons, capability failures,
  cancellation, and cleanup-residue failures MUST round-trip through Codable.
- `GitDataPlaneError` MUST retain its existing cases and encoding; fork Git
  failures are carried as a payload of `GitWorktreeForkError`.
- Stable public enums MUST use explicit wire representations and reject unknown
  cases rather than reinterpret them.
- Existing `AgentStudioGitLocalClient` conformers MUST compile through the
  default fork implementation.

## Proof obligations

The normative sections above are grouped into these stable requirement and
contract identities:

| Requirements source | Problem | Outcome | Normative requirement | Observable contract home | Proof |
| --- | --- | --- | --- | --- | --- |
| U-01, U-12 | P-01 — adding CoW could break existing clients | O-01 — no regression | R-01 — preserve normal API, behavior, source conformance, errors, and wire shape | C-01 — Existing normal creation; Compatibility and encoding | V-01 |
| U-02 | P-02 — normal checkout loses prepared filesystem state | O-02 — useful fork | R-02 — capture all tracked, dirty, untracked, and ignored content under explicit entry rules | C-02 — New CoW fork; Included state | V-02 |
| U-03 | P-03 — copied bytes and Git identity can describe different bases | O-02 — useful fork | R-03 — capture source HEAD and rebuild indexes from it without source staging | C-03 — Root worktree and index | V-02 |
| U-04, U-05 | P-04 — a copy may silently consume full storage | O-03 — storage truth | R-04 — clone every required regular payload or fail on a preflighted eligible APFS volume | C-04 — Eligibility; Filesystem capture | V-03 |
| U-06, U-07 | P-05 — copied Git pointers make prepared complex worktrees unsafe | O-04 — Git independence | R-05 — preserve and isolate hard links, sparse state, submodules, and nested repositories | C-05 — Sparse worktrees; Submodules; Nested Git repositories | V-04 |
| U-08 | P-06 — a multi-phase failure can leave branch, admin, and file residue | O-05 — safe failure | R-06 — compensate and verify every transaction-created artifact or report exact residue | C-06 — Completion, cancellation, and failure | V-05 |
| U-09 | P-07 — a snapshot hides policy-driven omissions | O-02, O-05 | R-07 — return validated snapshot plus ordered materialization report | C-07 — New CoW fork; Completion validation | V-06 |
| U-10 | P-08 — blocking traversal and actor reentrancy threaten responsiveness and ordering | O-06 — responsive serialization | R-08 — execute off the cooperative executor while retaining same-repository mutation custody | C-08 — Execution and serialization | V-07 |
| U-11 | P-09 — CoW may be mistaken for synchronization or snapshot isolation | O-03 — storage truth | R-09 — provide independent divergence with explicit mixed-time traversal semantics | C-09 — Containment and source races | V-03, V-08 |
| U-13 | P-10 — mock or status evidence cannot prove APFS/Git behavior | O-01 through O-06 | R-10 — prove contracts at their real unit, Git, APFS, concurrency, and performance boundaries | C-10 — Proof obligations | V-01 through V-08 |

| Proof ID | Requirements | Evidence that distinguishes pass from fail |
| --- | --- | --- |
| V-01 | U-01, U-12 | Contract round trips, exact old JSON-shape comparison, legacy payload decode, source-conformer compilation, and normal-mode integration behavior. |
| V-02 | U-02, U-03 | Real repository integration showing clean, staged, unstaged, deleted, untracked, and ignored source states and the defined destination status matrix. |
| V-03 | U-04, U-05, U-11 | Real APFS clone-capability and same-volume checks, free-space/allocation evidence, and bidirectional modification independence; incompatible platform/filesystem cases reject before mutation. |
| V-04 | U-06, U-07 | Real initialized/uninitialized/recursive submodule, nested standalone/linked Git repository, cone and non-cone sparse checkout including a sparse-index source, and hard-link fixtures; Git commands work independently, sparse paths retain their behavior, and pointer scans find no source administration. |
| V-05 | U-08 | Failure injection after each transaction phase and cancellation while leaves are in flight; destination, metadata, and created branch absence are inspected, including a forced cleanup-residue case. |
| V-06 | U-09 | Unit coverage for entry policy and stable report counts, skipped entries, and normalized entries plus integration fixtures for FIFO recreation, socket skipping, metadata normalization, unsupported special entries, and dataless clone failure without source materialization where available. |
| V-07 | U-10 | Same-repository concurrent mutation integration proves non-interleaving while an unrelated repository can progress; executor responsiveness is observed independently of wall-clock sleeps. |
| V-08 | U-13 | Representative ordinary, 50,000-file, and prepared-cache benchmarks report preflight, planning, materialization, index, validation, first-status, and physical-allocation phases without replacing behavioral tests. |

## Negative space

The operation does not provide an alternate-base overlay, source staging
preservation, ongoing synchronization, source locking, coherent snapshot
isolation, physical-copy fallback, cross-volume operation, Windows/Linux
implementation, product topology publication, crash recovery, secret filtering,
an active Git-operation continuation, or an experimental whole-directory clone
fast path.

All ignored content is included. Deciding that secret-shaped ignored paths need
product-level exclusion belongs to an Agent Studio policy layer and requires a
separate owner decision; this filesystem SDK does not guess from filenames.
