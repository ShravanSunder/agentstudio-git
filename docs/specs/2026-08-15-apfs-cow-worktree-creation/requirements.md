# APFS Copy-on-Write Worktree Fork — Requirements

## Authority and scope

These requirements capture the repository owner's settled needs for a new
`agentstudio-git` SDK capability. They are the authoritative Why and boundary
for the accompanying Specification and Program Design.

The capability is for developer tools such as Agent Studio that create many
Git worktrees from a prepared macOS working directory. The SDK must continue to
offer normal Git worktree creation and add a distinct operation that forks the
current filesystem state with APFS copy-on-write storage.

Included:

- the public SDK contract;
- normal and copy-on-write worktree creation behavior;
- macOS and APFS eligibility;
- dirty, untracked, ignored, sparse, nested-repository, and submodule state;
- reliability, rollback, concurrency, compatibility, and proof obligations.

Excluded:

- Agent Studio commands or UI;
- Agent Studio topology reconciliation;
- implementation planning, release work, or a pull request;
- a cross-platform physical-copy fallback;
- a coherent point-in-time snapshot of a live source;
- copying the source staging area into the destination staging area.

## Affected people and current problem

The direct consumer is a developer using `AgentStudioGitLocalClient` through
Agent Studio or another Swift client. That consumer can already create a clean
linked worktree, but cannot cheaply fork a prepared working directory that may
contain dirty edits, generated files, dependencies, build caches, nested Git
repositories, or initialized submodules.

Normal `git worktree add` shares Git objects but writes another clean checkout.
Copying the directory naively can duplicate large data and can leave copied
`.git` pointers attached to the source worktree's administration. Whole-
directory APFS cloning is fast, but it cannot inspect nested administrative or
runtime entries and Apple strongly discourages it as a generic hierarchy-copy
mechanism.

The desired outcome is a second, independently usable linked worktree that
starts with the source's current filesystem state, initially shares APFS data
blocks, and then diverges without later source or destination edits propagating
to the other side.

## Authorized needs

The repository owner assigns all priorities below. `P0` is required for the
capability to exist; `P1` is required before it is considered ready for normal
use.

| ID | Priority | Authorized need or outcome | Why it matters |
| --- | --- | --- | --- |
| U-01 | P0 | Existing normal worktree creation must retain its current public call, behavior, branch modes, result, platform support, and wire shape. | Current consumers must not pay a migration or behavior cost for the new capability. |
| U-02 | P0 | The SDK must add a distinct APFS CoW fork that reproduces the source worktree's present filesystem contents, including dirty tracked, untracked, and ignored entries. | Prepared dependencies, caches, generated output, and exploratory edits are the storage and workflow value of the feature. |
| U-03 | P0 | A fork must start at the source worktree's captured `HEAD`; its Git index must represent that commit rather than the source index. | The result has one clear meaning: source files are inherited, while staged source changes become unstaged destination changes. |
| U-04 | P0 | A successful fork must use genuine APFS copy-on-write for regular data, with no silent physical-copy fallback. | Returning success after duplicating large data would violate the primary storage promise. |
| U-05 | P0 | The operation must reject unsupported hosts and storage before mutation. It is available only on macOS 26 or later, with APFS source and destination on the same clone-capable filesystem. | Eligibility must be predictable and failure must not leave partial Git state. |
| U-06 | P0 | A successful fork must be an independently usable worktree even when the source uses initialized or uninitialized submodules, nested Git repositories, sparse checkout, or hard links. | These are legitimate prepared worktrees, not exceptional data that Agent Studio can discard or reject as a class. |
| U-07 | P0 | Initialized submodules and nested Git repositories must preserve their current working files while receiving destination-owned Git administration; uninitialized submodules must remain uninitialized. | Reusing prepared state saves work and space, while copied source pointers would make the fork unsafe. |
| U-08 | P0 | Failure or cancellation after mutation begins must remove transaction-created destination content and linked-worktree metadata and delete only a branch created by that transaction. The source must never be changed. | A failed fork must not publish a broken worktree or destroy unrelated repository state. |
| U-09 | P0 | The caller must receive a validated worktree snapshot and a truthful materialization report, including entries intentionally not reproduced. | A snapshot alone cannot explain successful but policy-driven omissions such as a Unix socket pathname. |
| U-10 | P1 | The async SDK call must keep blocking Git and filesystem work off the caller's cooperative executor while preventing another SDK mutation of the same repository from interleaving with the transaction. | Large trees take seconds; responsiveness and repository consistency are both required. |
| U-11 | P1 | Source changes made after an entry is cloned must not change the destination, and destination changes must not change the source. A live source may produce a documented nearby mixed-time result during creation. | APFS CoW promises independent divergence, not ongoing synchronization or snapshot isolation. |
| U-12 | P1 | The new public types and failures must have stable Codable behavior, while old payloads and source conformers remain compatible. | Agent Studio and test doubles consume the contracts across package and process boundaries. |
| U-13 | P1 | Unit tests and real APFS/Git integration tests must prove the public compatibility, filesystem, Git, submodule, sparse, hard-link, rollback, concurrency, and allocation claims. | Mock-only or status-only coverage cannot establish the defining storage and independence behavior. |

## Goal boundary

The existing `AgentStudioGitLocalClient` and libgit2 worktree writer are the
foundation to reuse. The new capability may extend `AgentStudioGitContracts`
and `AgentStudioGitLocal`, including the repository mutation lane. It must not
introduce Agent Studio product state, UI, topology reconciliation, a production
Git CLI dependency, a persistent transaction database, a service, or a
cross-run recovery subsystem.

Acceptable complexity is one typed public fork surface and the internal
planning, strict materialization, Git-administration isolation, index
initialization, validation, and rollback boundaries necessary to make its
success claim true. A general snapshot service, pluggable copy framework,
cross-platform abstraction, alternate-base overlay operation, or optional
whole-directory fast path requires a separate owner decision.

## Settled behavior

- Normal creation remains the clean Git checkout operation.
- CoW fork is a separate operation whose source is an existing worktree.
- The source `HEAD` is captured once as the destination base.
- Source index staging is not inherited.
- Dirty tracked, untracked, ignored, generated, dependency, and cache content
  is included unless its filesystem kind has an explicit safety rule.
- Registered and populated Git structures are preserved without retaining
  administrative pointers into the source worktree.
- Strict CoW failure is transaction failure, not permission to byte-copy.
- A live source is accepted without locking it; creation is best effort rather
  than a coherent filesystem snapshot.
- Abrupt process termination is outside the synchronous rollback guarantee.
  A later recovery feature is not authorized in this scope.

## Success outcomes

| Outcome | Observable success |
| --- | --- |
| O-01 — no regression | Existing normal create calls and old payloads behave exactly as before. |
| O-02 — useful fork | The destination opens as a valid linked worktree whose files reflect the copied source state and whose status reflects changes relative to the captured source `HEAD`. |
| O-03 — storage truth | Regular destination files begin as APFS clones and diverge independently when either side is modified. |
| O-04 — Git independence | Root, nested-repository, and initialized-submodule Git administration resolves only to destination-owned or common repository state intentionally shared by linked worktrees, never to source-worktree-specific administration. |
| O-05 — safe failure | Every injected synchronous failure phase leaves no transaction-created worktree, destination, or branch, or returns an explicit cleanup-residue failure rather than success. |
| O-06 — responsive serialization | Large materialization does not block the caller's cooperative executor, and same-repository SDK mutations cannot observe an in-progress transaction as their own execution state. |

## Evidence and remaining hypotheses

Current research and local macOS 26.5.2 measurements establish feasibility:

- a strict four-worker leaf walk materialized 50,000 files in a warm median of
  about 2.46 seconds;
- whole-directory clone was faster but lost required filtering, progress, and
  special-entry control and carries Apple's hierarchy-clone warning;
- building a 50,040-entry destination index took about 3.29 seconds and was a
  larger phase than strict materialization;
- a cloned 64 MiB file consumed only a small free-space delta initially and
  remained independent after an 8 MiB destination overwrite;
- Git's own worktree/submodule tests place an initialized linked-worktree
  submodule repository under that worktree's `$GIT_DIR/modules/...`, not the
  common worktree's submodule administration.

No fixed public latency guarantee is authorized yet. Performance evidence must
report phase costs against representative ordinary and many-file fixtures so a
later owner decision can set a threshold without weakening correctness.
