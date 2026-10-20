#if DEBUG
import AppKit

@MainActor
enum AssistantSelfTest {
    static func runLive() async -> Bool {
        guard let key = ProcessInfo.processInfo.environment["OPENCODE_API_KEY"], !key.isEmpty else {
            print("FAIL: set OPENCODE_API_KEY (scripts/test-assistant.sh --live loads .env.local)"); return false
        }
        do {
            let doc = NoteDocument(blocks: [
                Block(kind: .title, runs: [InlineRun(text: "Groceries")]),
                Block(kind: .body, runs: [InlineRun(text: "milk")]),
                Block(kind: .table, runs: [], payload: BlockPayload(table: TableData(rows: [["Keep", "me"]])))
            ])
            let context = try NoteEdit.context(doc)
            let started = Date()
            let text = try await ChatClient(apiKey: key).complete(
                instructions: NoteEdit.instructions,
                turns: [ChatTurn(role: "user", text: "Current note snapshot:\n\(context)\nUser request:\nChange the milk line to oat milk.")],
                schema: AssistantReply.schema)
            let reply = try JSONDecoder().decode(AssistantReply.self, from: Data(text.utf8))
            let edited = try NoteEdit.applying(reply.operations, to: doc)
            print(String(format: "PASS: live reply in %.1fs: %@", Date().timeIntervalSince(started), reply.reply))
            guard edited.blocks.map(\.plainText).contains(where: { $0.lowercased().contains("oat milk") }), edited.blocks[2] == doc.blocks[2] else {
                print("FAIL: live edit didn't produce the requested change safely: \(edited.blocks.map(\.plainText))"); return false
            }
            print("PASS: live edit validates, requested change present, table untouched")
            do {
                _ = try await ChatClient(apiKey: "oc_sk_invalid").complete(instructions: "x", turns: [ChatTurn(role: "user", text: "hi")], schema: AssistantReply.schema)
                print("FAIL: invalid key was accepted"); return false
            } catch { print("PASS: invalid key is reported: \(error.localizedDescription)") }
            return true
        } catch { print("FAIL: \(error.localizedDescription)"); return false }
    }

    static func run() async -> Bool {
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
            let realService = AssistantKeychain.service
            AssistantKeychain.service = "notas.assistant.test.\(UUID())"
            defer { AssistantKeychain.delete(); AssistantKeychain.service = realService }
            try AssistantKeychain.save("first-key")
            try AssistantKeychain.save("second-key")
            try check(AssistantKeychain.read() == "second-key", "Keychain stores and replaces the OpenCode key")
            AssistantKeychain.delete()
            try check(AssistantKeychain.read() == nil, "Keychain removes the OpenCode key")

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

            let mock = Process(), pipe = Pipe()
            let requests = root.appendingPathComponent("mock-requests.log")
            mock.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            mock.arguments = ["python3", "-I", FileManager.default.currentDirectoryPath + "/scripts/fixtures/mock-responses.py", requests.path]
            mock.standardOutput = pipe
            try mock.run()
            defer { mock.terminate() }
            let port = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let assistant = NoteAssistant(app: app, storageRoot: root.appendingPathComponent("Chat"))
            assistant.baseURL = URL(string: "http://127.0.0.1:\(port)/v1")!
            try check(!assistant.hasKey || ProcessInfo.processInfo.environment["OPENCODE_API_KEY"] != nil, "no key means chat is not ready")
            assistant.saveKey("bad key with spaces")
            try check(!assistant.hasKey && assistant.error != nil, "malformed key is rejected before storing")
            assistant.error = nil
            assistant.saveKey("test-opencode-key")
            try check(assistant.hasKey, "valid key is accepted")
            assistant.setDraft("Improve this", for: note.id)
            assistant.send(note.id)
            try await waitUntil { !assistant.busyNotes.contains(note.id) }
            let reply = assistant.session(for: note.id).messages.last
            try check(reply?.text == "Here is a clearer version.", "reply is read from the Responses payload")
            let seen = ((try? String(contentsOf: requests, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            try check(seen.first?["authorization"] as? String == "Bearer test-opencode-key" && (seen.first?["session"] as? String)?.isEmpty == false,
                      "request carries the bearer key and OpenCode session header")
            try check(seen.first?["model"] as? String == "gpt-6-luna" && seen.first?["effort"] as? String == "medium" && seen.first?["strict"] as? Bool == true
                      && (seen.first?["path"] as? String)?.hasSuffix("/responses") == true, "Luna at medium with a strict JSON schema is requested")
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
            // History is sent on follow-ups; a rejected key surfaces an actionable message; Stop cancels cleanly.
            editor.load(doc)
            assistant.setDraft("Follow up", for: note.id)
            assistant.send(note.id)
            try await waitUntil { !assistant.busyNotes.contains(note.id) }
            let after = ((try? String(contentsOf: requests, encoding: .utf8)) ?? "").split(separator: "\n").count
            try check(after == 2, "one request per message")
            assistant.setDraft("FAIL401", for: note.id)
            assistant.send(note.id)
            try await waitUntil { !assistant.busyNotes.contains(note.id) }
            try check(assistant.session(for: note.id).messages.last?.text.contains("rejected the API key") == true, "rejected key explains how to recover")
            assistant.setDraft("SLOW", for: note.id)
            assistant.send(note.id)
            try await Task.sleep(for: .milliseconds(300))
            try check(assistant.busyNotes.contains(note.id), "slow reply keeps the note busy")
            assistant.stop(note.id)
            try check(!assistant.busyNotes.contains(note.id) && assistant.session(for: note.id).messages.last?.text.contains("Stopped") == true, "Stop ends the request without changes")
            try await Task.sleep(for: .milliseconds(300))
            try check(editor.document == doc && assistant.session(for: note.id).messages.last?.role == .notice, "late reply after Stop is discarded")
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
