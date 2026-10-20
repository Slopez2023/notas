# Stability repair plan

Baseline: `4d3992b49b8934fd39357b3b509ac05c6ce4d5ac`.

The audit found 27 distinct issues. Repair the data-loss boundaries first, preserve existing file readability, and verify the same failing inputs against production code. A passing unit suite alone is insufficient to designate the app stable.

## Workflow

1. Compare two independent design sketches for persistence, editor ownership, and paragraph invariants.
2. Give storage, editor, chat, and UI workers separate worktrees and owned regression files.
3. For each finding, record its old failure, implement the root-cause repair, and assert the user's resulting content or behavior.
4. Integrate worker commits one at a time. Rebuild and run relevant checks after each integration.
5. Regenerate and validate the Xcode target, run all app and stability checks, and drive the repaired UI in an isolated library.
6. Review the integrated diff independently, repair accepted findings, and repeat affected checks.
7. Build and install the verified release. Report any untested production environment or unresolved finding explicitly.

Throughput checkpoint: four implementation slices, one integration owner, and one independent final review. Workers own separate checkouts and test files. The integration owner owns shared entry points, the Xcode project, and the final release.

## Finding ownership

### Storage and imports

- S1. Retain failed ordinary saves, report failures, and retry after storage recovers.
- S2. Preserve damaged notebook metadata and existing assignments instead of reseeding.
- S3. Preserve newer external note contents during local mutations and expose conflicts.
- S4. Persist current contents before moving a note to recoverable Trash.
- S5. Report failed Trash moves and preserve the visible note.
- S6. Validate package identities and preserve duplicate conflict versions.
- S7. Roll back assets created by a failed capture import.
- S8. Keep the first meaningful capture line when earlier lines are whitespace.

### Editor and tab lifecycle

- E1. Snapshot outgoing editor contents before empty-note cleanup on close or replacement.
- E2. Preserve attachment paragraphs when pasting text or deleting adjacent separators.
- E3. Isolate divider pastes from existing paragraph text.
- E4. Normalize external indentation and avoid overflowing indentation arithmetic.

### Chat and edit acceptance

- C1. Reject CRLF-containing operations before their editor roundtrip can shift targets.
- C2. Preserve rejected history bytes across shutdown and later writes.
- C3. Reject failed stream terminal events.
- C4. Respect terminal refusal validation instead of retaining earlier output.
- C5. Preserve the kind of an empty trailing checklist.
- C6. Decode complete surrogate pairs in streamed previews.
- C7. Use collision-free diff cache keys.

### Windows and controls

- U1. Scope palette keyboard interception to its own window and supported modifiers.
- U2. Present the palette above chat and its backdrop.
- U3. Make overflowing tabs reachable.
- U4. Make overflowing notebook controls reachable.
- U5. Constrain long notebook names in the note header.
- U6. Make New Notebook open notebook creation.

### Integration and packaging

- P1. Keep the committed Xcode source list synchronized with the app.
- P2. Replace the unconditional notebook-persistence assertion with a real assertion.

## Delegate verification contract

Work only in the assigned worktree and file scope. Do not mutate the installed app, personal library, real preferences, credentials, or provider/privacy settings. Never make paid model calls. Use synthetic documents, isolated preferences, private pasteboards, and temporary directories for tests.

Each worker supplies a focused regression file with one public `@MainActor static func run() async -> Bool` entry, named `StorageStabilityTests`, `EditorStabilityTests`, `ChatStabilityTests`, or `UIStabilityTests`. Put it in `Sources/Notas/Debug`, wrapped in `#if DEBUG`. The integration owner wires the entries into one command. Do not edit the global entry point or existing suite files without an explicit handoff.

Commit tests before fixes when a cheap failing target exists. Record the failing baseline output and passing output. Tests call production behavior and compare literal expected content. Do not weaken assertions, mirror implementation, or count source-only reasoning as executed proof. Preserve old files and both sides of a conflict. Keep API additions small and owned by the module that enforces their invariants.

Commit scoped changes in the worktree. Return the commit IDs, exact checks, evidence paths, changed interfaces, and any uncovered finding. No worker pushes, installs, or changes another worker's checkout.

## Limits to retain

Live multi-Mac iCloud delivery, sudden power loss, platform extension hosting, and real provider failures require separate environmental coverage. Report them honestly even if deterministic local substitutes pass.
