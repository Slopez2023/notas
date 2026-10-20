#if DEBUG
import AppKit

@MainActor
enum AssistantSelfTest {
    static func run(realCodex: Bool) async -> Bool {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notas-assistant-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var passes = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw AssistantError.message("FAIL: \(label)") }
            passes += 1
            print("PASS: \(label)")
        }
        do {
            if realCodex {
                let connection = CodexConnection(home: root.appendingPathComponent("Codex"))
                defer { connection.stop() }
                try await connection.start()
                try check(true, "real Codex handshake and denied private read")
                let config = try await connection.request("config/read", [:])
                let effective = config["config"] as? [String: Any] ?? [:]
                try check(effective["default_permissions"] as? String == "notas", "effective named permission profile")
                let features = effective["features"] as? [String: Any] ?? [:]
                try check(features["shell_tool"] as? Bool == false && features["apps"] as? Bool == false && features["hooks"] as? Bool == false,
                          "effective command, connector, and hook restrictions")
                let result = try await connection.request("command/exec", ["command": ["/usr/bin/env"], "cwd": connection.scratch.path,
                                                                            "permissionProfile": "notas", "timeoutMs": 3000])
                let environment = result["stdout"] as? String ?? ""
                try check(!environment.contains("CODEX_HOME=") && !environment.contains("OPENAI_API_KEY=") && !environment.contains("T3_"),
                          "tool environment excludes host credentials and orchestration variables")
                let sentinel = root.appendingPathComponent("note-b.txt")
                try Data("NOTE_B_SENTINEL".utf8).write(to: sentinel)
                let denied = try await connection.request("command/exec", ["command": ["/bin/cat", sentinel.path],
                                                                            "cwd": connection.scratch.path, "permissionProfile": "notas", "timeoutMs": 3000])
                try check(denied["exitCode"] as? Int != 0 && !(denied["stdout"] as? String ?? "").contains("NOTE_B_SENTINEL"),
                          "neighbor note cannot be read")
                let write = try await connection.request("command/exec", ["command": ["/usr/bin/touch", connection.scratch.appendingPathComponent("write-probe").path],
                                                                           "cwd": connection.scratch.path, "permissionProfile": "notas", "timeoutMs": 3000])
                try check(write["exitCode"] as? Int != 0, "scratch writes denied")
                print("✓ \(passes) live Codex checks passed; no sign-in or inference requested")
                return true
            }

            let doc = NoteDocument(blocks: [
                Block(kind: .title, runs: [InlineRun(text: "Test")]),
                Block(kind: .body, runs: [InlineRun(text: "Original", marks: .bold)]),
                Block(kind: .table, runs: [], payload: BlockPayload(table: TableData(rows: [["Keep", "these"]]))),
                Block(kind: .body, runs: [InlineRun(text: "Unchanged", marks: .italic)])
            ])
            let ops = [AssistantOperation(action: .replace, block: 1, text: "Revised", kind: "body"),
                       AssistantOperation(action: .insertAfter, block: 2, text: "Added", kind: "checklist")]
            let edited = try NoteEdit.applying(ops, to: doc)
            try check(edited.blocks.map(\.plainText) == ["Test", "Revised", "Keep these", "Added", "Unchanged"], "literal edit result and insertion order")
            try check(edited.blocks[2] == doc.blocks[2] && edited.blocks[4] == doc.blocks[3], "rich payload and unaffected formatting preserved")
            for invalid in [AssistantOperation(action: .delete, block: 0, text: "", kind: "title"),
                            AssistantOperation(action: .replace, block: 2, text: "bad", kind: "body"),
                            AssistantOperation(action: .replace, block: 1, text: "one\ntwo", kind: "body"),
                            AssistantOperation(action: .replace, block: 500, text: "bad", kind: "body")] {
                var rejected = false
                do { _ = try NoteEdit.applying([invalid], to: doc) } catch { rejected = true }
                try check(rejected, "unsafe operation rejected: \(invalid.action) block \(invalid.block)")
            }

            let library = LibraryStore(rootURL: root.appendingPathComponent("Library"))
            library.load()
            let preferences = UserDefaults(suiteName: "notas.assistant.test.\(UUID())")!
            let app = AppState(store: library, preferences: preferences)
            let note = library.createNote(in: nil)
            library.updateDocument(note.id, doc)
            app.open(note.id)
            let editor = NotasTextView.make()
            editor.noteID = note.id
            editor.load(doc)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor
            defer { window.close() }
            app.activeEditor = editor
            let undo = editor.undoManager
            try check(undo != nil, "editor has a real undo manager")
            undo?.groupsByEvent = false
            editor.applyAssistantDocument(edited)
            try check(editor.document == edited, "editor displays the proposed semantic document")
            undo?.undo()
            try check(editor.document == doc, "one Undo restores original rich document")
            undo?.redo()
            try check(editor.document == edited, "Redo restores assistant change")
            editor.load(doc)

            let assistant = NoteAssistant(app: app, storageRoot: root.appendingPathComponent("Chat"))
            assistant.binaryPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/fixtures/fake-codex.py").path
            await assistant.connect()
            try check(assistant.connected && assistant.modelAvailable, "fake server authenticates and advertises Sol medium")
            assistant.setDraft("Improve this", for: note.id)
            assistant.send(note.id)
            try await waitUntil { !assistant.busyNotes.contains(note.id) }
            let reply = assistant.session(for: note.id).messages.last
            try check(reply?.text == "Here is a clearer version.", "production transport handles fragmented JSONL and empty completion items")
            guard let proposal = reply?.proposal else { throw AssistantError.message("Missing proposal") }
            try check(editor.document == doc, "generation never mutates the note")

            undo?.beginUndoGrouping()
            editor.insertText("!", replacementRange: NSRange(location: 0, length: 0))
            undo?.endUndoGrouping()
            assistant.apply(proposal.id, noteID: note.id)
            try check(assistant.error?.contains("note changed") == true && editor.document.title == "!Test", "typing before Apply rejects stale proposal")
            assistant.error = nil
            editor.load(doc)
            assistant.apply(proposal.id, noteID: note.id)
            try check(editor.document.blocks[1].plainText == "Improved", "validated proposal applies through the editor")
            undo?.undo()
            try check(editor.document == doc, "coordinator Apply remains one undoable operation")

            let other = library.createNote(in: nil)
            app.open(other.id, newTab: true)
            assistant.apply(proposal.id, noteID: other.id)
            try check(assistant.error != nil, "proposal cannot retarget another note")
            app.open(note.id)
            assistant.error = nil
            assistant.setDraft("Keep this draft", for: other.id)
            assistant.newConversation(note.id)
            try check(assistant.archives.contains { $0.noteID == note.id } && assistant.session(for: other.id).draft == "Keep this draft", "new conversation archives history without touching another note")
            assistant.shutdown()

            let restored = NoteAssistant(app: app, storageRoot: root.appendingPathComponent("Chat"))
            try check(restored.session(for: other.id).draft == "Keep this draft" && !restored.archives.isEmpty, "history and per-note drafts survive reload")
            restored.shutdown()
            library.flush()
            try check(try NoteEdit.revision(doc) != NoteEdit.revision(edited), "revisions distinguish semantic edits")
            print("✓ \(passes) assistant checks passed")
            return true
        } catch {
            print(error.localizedDescription)
            return false
        }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AssistantError.message("Timed out waiting for assistant test response")
    }
}
#endif
