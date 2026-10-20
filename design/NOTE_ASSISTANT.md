# A note-scoped Codex assistant

Status: implemented October 20, 2026 on the Codex-managed ChatGPT sign-in route (personal local use). Sign in with ChatGPT registration remains unestablished, so this is not a distribution-ready authentication path.

Implementation status:

- Done and covered by `scripts/test-assistant.sh` (20 checks: edit reducer, editor Undo/Redo, stale-proposal rejection, session isolation, persistence, fake app-server transport) and `scripts/test-assistant.sh --live` (6 checks against the real `codex` binary: handshake, sandbox denial of private reads and scratch writes, command/connector/hook restrictions, sentinel credentials absent from the tool environment). `scripts/test.sh` still passes its 203 checks.
- Not yet verified: browser sign-in, subscribed access to `gpt-6.1-sol` at `medium`, and a real completed inference. Earlier attempts to continue ended on a ChatGPT usage limit; the live checks deliberately request no sign-in or inference. Verify these manually in the app before relying on the feature.
- Not done: Sign in with ChatGPT (app-owned OAuth) route, App Store packaging, iCloud external-edit reconciliation.

## Product behavior

Add a collapsible, resizable SwiftUI inspector beside the AppKit note editor. Start around 340 points wide, with an accessible layout for smaller windows. Represent the right panel with one enum such as `closed`, `style`, or `chat` so the existing style pane and chat cannot overlap. The pane shows the bound note title, conversation history, composer, Stop, and pending edit previews. The note remains the main workspace.

Each note gets its own persistent conversation. Renaming or moving a note keeps its conversation because identity is the note UUID. Switching notes switches the displayed conversation and draft. A running reply remains attached to its original note. New conversation creates another session for that same note and preserves the previous history locally.

The assistant can discuss a note, draft content into an empty note, and propose text edits. Changes appear as a preview with Apply and Dismiss. Apply is one undoable editor action. Version one preserves existing photos, sketches, tables, boards, and columns. It can describe their structured text but cannot silently replace their payloads. Photo and PDF contents are not uploaded automatically.

ChatGPT subscription sign-in uses OpenAI's browser authorization flow. The user never enters a password or token into Notas. Settings shows the connected account, model, usage-limit state when exposed by the selected authentication route, and installed Codex version. Explain before first use that selected note content is sent to OpenAI. This feature uses cloud inference even though its UI and process run locally.

Interpret "Sol medium" as `gpt-6.1-sol` with reasoning effort `medium`. Use `model/list` to discover the exact model and effort, then verify access with a successfully completed inference request. With the Sign in with ChatGPT provider, the list may be a bundled catalog rather than an entitlement check. If unavailable, show an actionable error. Do not silently substitute a model or switch to API billing.

## Existing ownership and runtime flow

- `AppState` owns tab selection and a weak reference to the active `NotasTextView`.
- `MainView` mounts `NoteEditorView(...).id(noteID)`. Opening another note reconstructs the editor.
- `NoteEditorView.Coordinator` reads the live text storage after a 250 ms debounce and calls `LibraryStore.updateDocument`.
- `LibraryStore` updates memory immediately and atomically writes `note.json` after a further 500 ms debounce on its I/O queue.
- `NoteDocument` stores semantic blocks and inline formatting. Blocks currently have no stable IDs. Attachment blocks carry structured payloads and reference files inside the note package.
- `NotasTextView.load` clears Undo. `updateNSView` updates style but does not reload externally changed note content.

Therefore the live editor is authoritative while open. Writing AI changes directly to `note.json` or only to `LibraryStore` would race typing and leave the visible editor stale. Calling `load` to fix that would erase Undo.

The current product specification describes on-device AI only. This proposal deliberately adds an opt-in cloud feature in response to the new requirement. Update those roadmap statements when the feature ships.

## Caller usage and module shape

Conceptual Swift interfaces follow. These are design signatures, not compiled implementation.

```swift
// MainView supplies a fixed note identity to the pane.
NoteChatSidebar(session: app.noteAssistant.session(for: noteID))

// Sending captures the live document internally before starting the turn.
try await session.send("Make the introduction shorter")

// The proposal already carries its originating note and snapshot.
try app.noteAssistant.apply(proposal.id)
```

Keep four responsibilities visible:

- `Chat/NoteAssistant.swift`: owns observable sessions, per-note drafts, account partitioning, persistence, and event routing. `AppState` owns one instance. Its public operations are session, send, stop, start new conversation, and apply.
- `Chat/CodexConnection.swift`: a Swift actor owns the `Process`, pipes, bounded JSONL decoder, request correlation, handshake, deadlines, and reconnection. It translates wire events to domain events. Views never consume raw JSON-RPC.
- `Chat/NoteEdit.swift`: snapshot representation, strict proposal decoding, revision checks, and a pure edit reducer. It handles domain data without owning a second document store.
- `UI/NoteChatSidebar.swift`: native presentation. Add an editor transaction method to `NotasTextView` and snapshot access through its coordinator.

```swift
struct SessionKey: Hashable, Codable {
    let libraryID: UUID
    let accountPartitionID: UUID
    let noteID: UUID
    let conversationID: UUID
}

struct NoteSnapshot {
    let noteID: UUID
    let revision: DocumentRevision
    let document: NoteDocument
    let blockReferences: [SnapshotBlockReference]
}

struct EditProposal {
    let id: UUID
    let session: SessionKey
    let baseRevision: DocumentRevision
    let operations: [TextEditOperation]
}

enum ReplyState {
    case idle
    case sending(UUID)
    case streaming(turnID: String)
    case stopping(turnID: String)
    case interrupted
    case failed(AssistantFailure)
}
```

`DocumentRevision` is a digest of a deterministic encoding of the complete semantic document, including attachment payloads. Do not use `modified` timestamps as a revision. Use snapshot-scoped block references containing index and expected content digest. The full revision must match before interpreting any reference. This avoids a note-file migration solely to add block IDs.

## Codex integration

Run the official CLI as a child process using `codex app-server --listen stdio://`. Use `Process.executableURL` and an argument array. Resolve a configured binary explicitly because GUI apps do not inherit an interactive shell's PATH. Check the binary version and show installation guidance when absent.

Use one managed app-server per connected account partition, started lazily. Notes have separate threads within it; they do not each need a permanently running CLI process. Set a Notas-owned `CODEX_HOME` in the child's environment, outside the note library and iCloud. Keep this separate from the user's developer Codex configuration.

For a new integration, prefer the current Sign in with ChatGPT route. Register the client, use the documented OAuth flow with PKCE, validate identity and granted plan-usage scopes, and keep credentials in the macOS Keychain. Configure app-server's Responses provider with `base_url="https://api.openai.com/v1"`, `wire_api="responses"`, `requires_openai_auth=false`, `supports_websockets=false`, and an `env_key` whose access token is set only in the child environment. No separate Codex login is required. The app owns renewal: refresh ahead of expiry, drain or deliberately interrupt active turns, restart app-server, and resume saved threads. A refresh restart affects every active conversation in that account partition, so reconcile each interrupted turn. Never put tokens into command-line arguments, logs, or notes.

This route is a preview. The current docs describe plan usage for open-source partners and selected private clients, with commercial access limited to selected partners. Establish Notas's eligibility and client registration before implementing production authentication. The feature is not ready to promise subscription access until this succeeds.

The app-server docs describe continued Codex-managed authentication for local or open-source applications, recommend migration to Sign in with ChatGPT, and exclude commercial or hosted use of app-server authentication. A personal local CLI prototype can evaluate that route separately. It uses `account/login/start` with `type: "chatgpt"` and Codex-managed renewal. Prefer `cli_auth_credentials_store="keyring"` and verify isolation of its credential store. Never read or copy the user's existing developer auth files. Do not treat this as an automatic fallback when registration is unavailable.

Connection lifecycle:

1. Send `initialize` with client metadata, wait for its response, then send `initialized`.
2. Authenticate using the selected route above. For Sign in with ChatGPT, Notas owns account state and passes the authorized access token to the child. For the local Codex-managed route, use the account RPCs.
3. Page through `model/list`, confirm the requested model supports `medium`, and verify entitlement with a completed inference turn during integration validation.
4. Create a thread with `thread/start`, or resume the saved thread with `thread/resume`.
5. Send `turn/start` with the bound note snapshot, user request, exact model, `effort: "medium"`, enforced permissions, and the response schema.
6. Route events by thread, turn, and item identity. End on `turn/completed`, including failed and interrupted statuses. Stop calls `turn/interrupt`.

Use the installed version's generated JSON Schema as the protocol contract. The installed CLI was `0.163.0` when this proposal was written. Its default schema exposes `outputSchema` and `effort` on `TurnStartParams`; experimental dynamic tools are absent unless requested during schema generation.

The app-server command itself is marked experimental in the installed CLI. Pin a tested compatibility range, perform a startup compatibility check, and keep an unsupported installation from attempting edits. Do not assume the latest web documentation exactly matches every installed CLI.

## A boundary that actually locks the session to one note

Conversation separation and `cwd` do not restrict filesystem reads. A read-only sandbox with its default full read access also does not isolate notes.

Version one supplies a note snapshot and receives structured output. It exposes no app tool that can select another note or accept an arbitrary path. The host binds every response to the session that initiated the request. Model-returned note IDs cannot retarget an edit.

Use an empty per-session working directory. Enforce restricted filesystem read roots and no filesystem writes for agent commands, with command network access disabled. Keep the note library, credentials, other thread logs, and user home outside readable roots. Deny permission escalation. These permissions restrict model tools; app-server still needs its own authenticated transport to OpenAI.

Use an app-specific configuration with no inherited MCP servers, connectors, plugins, hooks, skills, memories, or subagents. Disable command and file tools where the supported CLI permits it, and reject all unexpected approval or tool requests. Do not rely on declining approvals alone: some read operations can run without an approval request. Do not assume one shell flag removes every execution tool.

The provider's access token is present in app-server's environment. If any command tool remains available, it must receive a sanitized environment that excludes this token and all unrelated credentials. Verify this for every execution path using a dummy sentinel credential. A command that can print or forward the sentinel fails the release gate. Restricting file reads alone does not prevent environment-variable disclosure.

Before shipping, verify the effective configuration and run real denial tests against the pinned binary. If filesystem or inherited-context isolation cannot be demonstrated, the integration fails the release gate. A stronger execution restriction or another supported integration is required before claiming that chat is locked to a note.

The assistant can still answer general questions. "Locked" means that its app-provided content, history, and edit authority belong to one note. It does not mean the model has no general knowledge.

## Safe editing

1. On Send, capture the current document from the matching live editor on the main actor, including pending keystrokes. Capture selected text only when explicitly requested. Read the store for a closed note.
2. Provide text and structured block context with snapshot references. Mark unsupported rich blocks as protected. Set input limits and report oversized notes instead of silently omitting content.
3. Constrain the final response with `outputSchema`: a readable reply and optional text-edit operations. Decode strictly and enforce allowed operation kinds, bounds, size limits, and protected block preservation. Never accept arbitrary replacement of the entire note object or asset paths.
4. Retain a validated proposal tied to the host's original session and snapshot. Display the proposed changes without mutating the document. Treat streamed content as provisional. Do not execute partial JSON or display the response envelope as chat prose. Version one may show activity while awaiting the final structured answer; improve incremental prose rendering only with a proper streaming parser.
5. On Apply, verify the note still exists and is the proposal's note. In one uninterrupted main-actor transaction, recapture the live document, compare its revision, validate the operations, and perform the editor mutation. Recheck at Apply even if validation succeeded earlier.
6. Apply text-storage changes inside one Undo group, preserve unaffected attributed text and rich block objects, and invoke the normal edit/save path. Do not call `load`. Reject stale proposals and offer regeneration against the current note.

For the initial release, Apply requires reopening the originating note. This keeps user edits and assistant edits in the same Undo system and prevents hidden background mutations. Chat may continue while another note is selected. Starting a draft uses an ordinary empty note and its own conversation.

Inform the conversation when a proposal was applied, dismissed, rejected as stale, or undone. A generated proposal is not evidence that the document changed. Each later turn includes a fresh snapshot, so the current note takes precedence over historical drafts.

## Persistence and recovery

Store the session index, messages, composer drafts, and proposal decisions under local Application Support. Partition by library identity and account/workspace identity, then note UUID and conversation UUID. Canonical library location must distinguish development libraries from the user's real library. Codex stores its own resumable threads in the private app-specific home. Notas owns the binding and user-visible history. Never parse undocumented rollout files.

Use atomic durable updates for the local session record. Correlate messages with local send IDs and server turn IDs. After a crash or transport loss, reconcile stored thread history before offering retry. A dropped `turn/start` response may still have started a turn. A client message ID is a correlation aid unless the installed server explicitly guarantees deduplication. Never blindly replay a send or auto-apply a persisted proposal.

Allow one active turn per conversation. Use bounded concurrent work across notes. Closing the pane detaches the view without reassigning the stream. App quit interrupts active work and closes the child process with a deadline.

On missing Codex history, show the local transcript and offer a new conversation. Do not silently recreate history and imply native resumption. Account changes stop active work and select a separate partition. Keep earlier-account transcripts available locally without resuming them under another account. Handle revocation and refresh failure through the selected authentication route. App sign-out must not sign the user out of an unrelated developer CLI installation.

Deleting a note stops its turn, invalidates proposals, and retains its local history according to a recoverable-trash policy. Restoring the same note UUID can restore the binding. Duplicating or importing a note creates a new UUID and conversation. Sharing exports note content and assets, never account credentials or chats.

The current library does not continuously reconcile external iCloud edits. A digest of local memory cannot detect an unseen external write. This feature must not claim to solve cross-device concurrent editing. Compare the package's last-seen disk version before committing AI changes and refuse known external conflicts; full iCloud conflict resolution is separate work.

## Delivery and verification

Build in units that end with observable behavior:

1. Connection and authentication: establish registration and eligibility for the selected route, launch from Finder, discover the CLI, perform browser sign-in, validate Sol medium through completed inference, and display available usage state and errors. Establish the permission policy first.
2. Read-only chat: native pane, fresh snapshots, per-note conversations, Stop, draft retention, restart and history reconciliation. Prove isolation with two scratch notes containing different sentinel strings and verify direct reads outside the allowed roots fail.
3. Text proposals: deterministic validation, preview, revision conflict handling, one-step Undo and Redo, and preservation of rich payloads and asset bytes. Include IME composition, rapid tab switches, delete during generation, and changes typed before the debounce fires.
4. Reliability: app-server termination during Send and streaming, lost responses, duplicate events, logout and account switching, unavailable model, exhausted usage, missing binary, corrupted local history, and incompatible CLI upgrade. No duplicate edits or silent model changes.

Use protocol fixture tests for framing, error handling, and event routing. Test edit behavior through the actual editor with literal expected documents. Run `scripts/test.sh`, then manually exercise the shipped app on an isolated `NOTAS_LIBRARY`. Source compilation alone does not prove this feature.

App Store distribution needs a separate packaging and sandbox feasibility check. The current direct Mac app build has no App Sandbox entitlement. Do not assume spawning a user-installed CLI will work unchanged in an App Store build.

## Alternatives and synthesis

Two independent design reviews explored structured responses and app-owned `note_read` / `note_propose` dynamic tools. Both found that live-editor capture, revision checks, host-owned session binding, and editor-owned Undo are necessary.

An independent cross-review selected the structured-response design. It scored isolation 4/5, editor preservation 5/5, authentication 4/5, interface stability 4/5, and crash recovery 4/5 before implementation. Its main corrections were token inheritance into commands and account-wide interruption during token-refresh restarts; both are explicit gates above. These scores compare proposals and are not test results.

Choose structured responses for the first release. Dynamic tools let the model reread within a turn and produce ordinary chat prose, but add an experimental protocol, tool dispatch, and mid-turn state coordination. They do not remove the need to restrict built-in tools. Avoid a dual implementation with automatic fallback; that doubles the paths that must prove isolation. A later tool-based design should preserve the same snapshot and edit contract.

Adopt the tool candidate's snapshot-scoped references and the structured candidate's single right-panel enum. Reject the proposed persistent block-ID migration for version one. Index plus expected content digest is unambiguous when the entire snapshot revision must match; durable IDs become useful if later requirements include rebasing edits across document changes. Also reject silent model fallback, automatic transcript replay after missing history, and account-crossing thread resumption.

Direct Codex writes to note packages lose because they bypass live editor ownership. A process for every note increases resource use and authentication coordination without replacing permission checks. An embedded terminal or shell-output parser exposes process behavior to the UI without providing the structured history, login, and event contract of app-server.

## Sources and verified limits

- [Codex app-server](https://developers.openai.com/codex/app-server/) documents embedded clients, stdio, thread and turn lifecycle, model discovery, response schemas, restricted reads, and experimental dynamic tools.
- [Codex authentication](https://developers.openai.com/codex/auth/) documents subscription login, browser authentication, credential caching, and keyring storage. Subscription limits and model access remain account-dependent.
- [Codex configuration](https://learn.chatgpt.com/docs/config-file/config-basic) documents feature controls. Exact enforcement must be tested against the installed binary.
- [Sign in with ChatGPT quickstart](https://developers.openai.com/siwc/quickstart) describes registration, plan-usage consent, and current eligibility.
- [Sign in with ChatGPT through app-server](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server) documents the Responses provider, token renewal, and the limits of model discovery.
- [Plan usage preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) describes supported requests and confirms that local thread resumption works with Responses storage disabled.

Locally verified on October 20: CLI version `0.163.0`; JSON Schema generation succeeded; an app-server launched with a temporary isolated home and completed the stdio `initialize` response followed by `initialized`. No credentials were read and no model turn was started. Login, subscribed model access, actual inference, tool isolation, and editor mutation remain implementation gates.
