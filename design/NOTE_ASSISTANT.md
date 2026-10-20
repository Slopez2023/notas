# Note chat assistant

A collapsible chat pane (⌥⌘J) beside the editor. Each note has its own persistent conversation; the assistant can discuss the note and propose text edits that the user applies with one undoable action.

## How it works

Notas calls an OpenAI-compatible **Responses** endpoint directly over HTTPS (`Chat/ChatClient.swift`). The default is OpenCode Go (`https://opencode.ai/inference/go/openai/v1`) with `gpt-6-luna` at `medium` reasoning. The endpoint requires an `x-opencode-session` header, which the client sends. Replies are constrained with a strict JSON schema: `{ reply, operations[] }`.

An earlier design drove the Codex CLI (`codex app-server`) as a child process. It was removed: the chat needs no tools, so the sandbox, login, version pinning, and process lifecycle protected nothing and were the main source of failure.

## Why it is locked to one note

The model receives only that note's snapshot plus that conversation's text. It has no tools, file access, or knowledge of other notes, and its replies are bound by the host to the session that asked. Model-supplied IDs cannot retarget an edit.

## Safe editing

- On Send the live editor's document is captured (including keystrokes not yet debounced); unsupported rich blocks are marked protected.
- The reply is decoded strictly. `NoteEdit.applying` rejects out-of-range blocks, protected blocks, newlines, and structural changes.
- A valid proposal is shown as a preview (Apply / Dismiss). Generation never mutates the note.
- Apply rechecks the live document's revision (a digest of the full semantic document), so anything typed since is never overwritten, then mutates through the editor in one Undo group. `load` is never called, so Undo history survives.
- Apply requires the originating note to be open. A note changed on disk since the request is refused.

## Key and privacy

The API key is stored in the macOS Keychain (`AssistantKeychain`) and sent only as the bearer token to the endpoint. It is never written to the library, chat history, or logs. For development, `scripts/run.sh` exports `OPENCODE_API_KEY` from the gitignored `.env.local`; the app adopts it into the Keychain once.

Sending a message shares that note's text (and the conversation) with OpenCode and its model provider. Photos, sketches, and attachment files are not sent. The in-app screen says so before first use.

## Persistence

Sessions, drafts, and proposal decisions live in Application Support, partitioned by library path (so scratch libraries never touch the real library's chats). A reply in flight when the app quits is not replayed; the transcript notes it and the user sends again. New conversation archives the old one; deleting a note archives its chat. Chat is never included in shared notes.

## Tests

- `scripts/test.sh`: library, editor, codec self-test.
- `scripts/test-assistant.sh`: edit reducer, editor Undo/Redo, stale-proposal rejection, session isolation, persistence, Keychain, request shape (bearer, session header, model, effort, strict schema), rejected-key message, Stop and late-reply discard, against a local stand-in server (`scripts/fixtures/mock-responses.py`).
- `scripts/test-assistant.sh --live`: one tiny real request using `.env.local`, validated through the same edit pipeline.

## Not done

Streaming prose (replies arrive whole, typically in a few seconds), other providers behind the same client, iCloud external-edit reconciliation, App Store sandbox review.
