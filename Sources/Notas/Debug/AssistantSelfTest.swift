#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum AssistantSelfTest {
    static func runLive() async -> Bool {
        let modelArgument = CommandLine.arguments.first { $0.hasPrefix("--model=") }
        guard let model = ChatModel(rawValue: modelArgument.map { String($0.dropFirst("--model=".count)) } ?? "gpt-6-luna") else {
            print("FAIL: unknown live-test model"); return false
        }
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
            let text = try await ChatClient(apiKey: key, model: model).complete(
                instructions: NoteEdit.instructions,
                turns: [ChatTurn(role: "user", text: "Current note snapshot:\n\(context)\nUser request:\nChange the milk line to oat milk.")],
                schema: AssistantReply.schema)
            let reply = try JSONDecoder().decode(AssistantReply.self, from: Data(text.utf8))
            let edited = try NoteEdit.applying(reply.operations, to: doc)
            print(String(format: "PASS: %@ live reply in %.1fs: %@", model.label, Date().timeIntervalSince(started), reply.reply))
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
            try check(EditDifference.between("Bring milk today.", "Bring tea today.") == [
                EditDifference(kind: .unchanged, text: "Bring "), EditDifference(kind: .removed, text: "milk"),
                EditDifference(kind: .added, text: "tea"), EditDifference(kind: .unchanged, text: " today.")
            ], "preview highlights only the changed word")
            let previewPairs = [("", "New paragraph"), ("Delete me", ""), ("same", "same"),
                                ("Hello, world!", "Hello world."), ("one  two\tthree", "one two three"),
                                ("café 👩🏽‍💻 東京", "café 👨‍💻 京都"), ("a b a b", "b a b a"),
                                (String(repeating: "old ", count: 600), String(repeating: "new ", count: 600))]
            for (before, after) in previewPairs {
                let parts = EditDifference.between(before, after)
                try check(parts.filter { $0.kind != .added }.map(\.text).joined() == before
                          && parts.filter { $0.kind != .removed }.map(\.text).joined() == after,
                          "preview preserves exact original and proposed text, including whitespace and Unicode")
            }
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
            try check(NoteEdit.effort(for: "Improve this") == "low" && NoteEdit.effort(for: "Rewrite the whole note") == "medium",
                      "small edits use brief reasoning and a restructure uses medium")
            try check(ChatClient.visibleReply(in: "{\"reply\":\"Hello\"}") == "Hello"
                      && ChatClient.visibleReply(in: "{\"reply\":\"Hello") == "Hello"
                      && ChatClient.visibleReply(in: "{\"reply\":\"Say \\\"hi\\\"\"}") == "Say \"hi\""
                      && ChatClient.visibleReply(in: "{\"operations\":[") == "",
                      "a streaming reply shows the answer text without raw JSON")
            let base = NoteDocument(blocks: ["T", "A", "B", "C"].enumerated().map { index, text in
                Block(kind: index == 0 ? .title : .body, runs: [InlineRun(text: text)])
            })
            let insertX = AssistantOperation(action: .insertAfter, block: 1, text: "X", kind: "body")
            let insertY = AssistantOperation(action: .insertAfter, block: 1, text: "Y", kind: "body")
            let afterX = try NoteEdit.applying([insertX], to: base)
            let rebasedY = NoteEdit.rebase([insertY], after: [insertX])
            try check(rebasedY.first?.operation.block == 2, "an accepted insertion moves the next insertion after it")
            let withY = try NoteEdit.applying(rebasedY.map(\.operation), to: afterX)
            try check(withY.blocks.map(\.plainText) == ["T", "A", "X", "Y", "B", "C"], "rebased insertions keep acceptance order")
            let replaceA = AssistantOperation(action: .replace, block: 1, text: "A2", kind: "body")
            let replaceB = AssistantOperation(action: .replace, block: 2, text: "B2", kind: "body")
            try check(NoteEdit.rebase([replaceB], after: [replaceA]).first?.operation.block == 2, "a replacement does not shift later blocks")
            let deleteA = AssistantOperation(action: .delete, block: 1, text: "", kind: "body")
            let shifted = NoteEdit.rebase([replaceB], after: [deleteA])
            try check(shifted.first?.operation.block == 1, "deleting an earlier block shifts the next edit")
            let afterDelete = try NoteEdit.applying([deleteA], to: base)
            let deletedApplied = try NoteEdit.applying(shifted.map(\.operation), to: afterDelete)
            try check(deletedApplied.blocks.map(\.plainText) == ["T", "B2", "C"], "a shifted replacement edits the same paragraph")
            try check(NoteEdit.rebase([replaceA], after: [deleteA]).isEmpty, "an edit to a deleted block is dropped")

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
            try check(assistant.session(for: note.id).selectedModel == .luna, "new notes default to GPT 6 Luna")
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
            try check(reply?.thought == "Checking the requested edit.", "a reasoning summary is kept with the reply")
            let seen = ((try? String(contentsOf: requests, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            try check(seen.first?["authorization"] as? String == "Bearer test-opencode-key" && (seen.first?["session"] as? String)?.isEmpty == false,
                      "request carries the bearer key and OpenCode session header")
            try check(seen.first?["model"] as? String == "gpt-6-luna" && seen.first?["effort"] as? String == "low"
                      && seen.first?["summary"] as? String == "auto" && seen.first?["stream"] as? Bool == true
                      && seen.first?["strict"] as? Bool == true && (seen.first?["path"] as? String)?.hasSuffix("/responses") == true,
                      "Luna streams a brief reply with a reasoning summary and a strict JSON schema")
            guard let proposal = reply?.proposal else { throw AssistantError.message("Missing proposal") }
            try check(proposal.locations == ["Paragraph 1"], "proposal persists a human-readable location from the snapshot")
            try check(proposal.removesFormatting == [true], "review records formatting loss on the affected replacement")
            guard var legacyProposal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal)) as? [String: Any] else {
                throw AssistantError.message("Could not encode legacy proposal fixture")
            }
            legacyProposal.removeValue(forKey: "locations")
            legacyProposal.removeValue(forKey: "removesFormatting")
            let legacyPreview = try JSONDecoder().decode(AssistantProposal.self, from: JSONSerialization.data(withJSONObject: legacyProposal))
            try check(legacyPreview.locations == nil && NoteEditPreview.fallbackLocation(of: legacyPreview.operations[0], original: legacyPreview.before[0]) == "\"Original\"",
                      "old proposals still load and use their saved original text as context")
            let sectionDoc = NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "Trip")]),
                Block(kind: .heading1, runs: [InlineRun(text: "The plan")]), Block(kind: .body, runs: [InlineRun(text: "Leave Friday")])])
            try check(NoteEditPreview.location(of: AssistantOperation(action: .replace, block: 2, text: "Leave Saturday", kind: "body"), in: sectionDoc)
                      == "The plan · paragraph 1", "locations identify the section instead of exposing block indices")
            var mixedDoc = sectionDoc
            mixedDoc.blocks.insert(Block(kind: .bullet, runs: [InlineRun(text: "Buy tickets")]), at: 2)
            try check(NoteEditPreview.location(of: AssistantOperation(action: .replace, block: 3, text: "Leave Saturday", kind: "body"), in: mixedDoc)
                      == "The plan · paragraph 1"
                      && NoteEditPreview.location(of: AssistantOperation(action: .delete, block: 2, text: "", kind: "bullet"), in: mixedDoc)
                      == "The plan · bullet 1", "mixed block types get accurate labels and paragraph numbering")
            try check(!NoteEditPreview.removesFormatting(AssistantOperation(action: .replace, block: 2, text: "New tickets", kind: "bullet"), in: mixedDoc),
                      "plain text replacements do not show a formatting-loss warning")
            try check(editor.document == doc, "generation never mutates the note")

            undo?.beginUndoGrouping()
            editor.insertText("!", replacementRange: NSRange(location: 0, length: 0))
            undo?.endUndoGrouping()
            assistant.apply(proposal.id, noteID: note.id)
            try check(assistant.error?.contains("note changed") == true && editor.document.title == "!Test", "typing before Apply rejects stale proposal")
            assistant.error = nil
            editor.load(doc)
            assistant.apply(proposal.id, noteID: note.id, only: 0)
            try check(editor.document.blocks[1].plainText == "Improved"
                      && assistant.session(for: note.id).messages.contains { $0.proposal?.id == proposal.id && $0.proposal?.state == .applied },
                      "accepting the only change applies it")
            undo?.undo()
            try check(editor.document == doc, "coordinator Apply remains one undoable operation")

            let other = library.createNote(in: nil)
            app.open(other.id, newTab: true)
            assistant.apply(proposal.id, noteID: other.id)
            try check(assistant.error != nil, "proposal cannot retarget another note")
            app.open(note.id)
            assistant.error = nil
            assistant.setDraft("Keep this draft", for: other.id)
            for model in [ChatModel.luna56, .muse, .deepseekFlash, .grok] {
                assistant.setModel(model, for: note.id)
                assistant.setDraft("Try the selected model", for: note.id)
                assistant.send(note.id)
                try await waitUntil { !assistant.busyNotes.contains(note.id) }
                if model == .deepseekFlash {
                    guard let deepseekProposal = assistant.session(for: note.id).messages.last?.proposal else {
                        throw AssistantError.message("Missing DeepSeek proposal")
                    }
                    assistant.apply(deepseekProposal.id, noteID: note.id)
                    try check(editor.document.blocks[1].plainText == "Improved", "DeepSeek JSON reply produces a validated editor change")
                    undo?.undo()
                    try check(editor.document == doc, "DeepSeek edit undoes in one step")
                }
            }
            let modelRequests = try String(contentsOf: requests, encoding: .utf8).split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            try check(modelRequests.compactMap { $0["model"] as? String }
                      == ["gpt-6-luna", "gpt-5.6-luna", "muse-spark-1.3-contributor", "deepseek-v4.1-flash", "grok-4.7"],
                      "each picker choice reaches OpenCode with its exact model ID")
            try check(modelRequests[2]["path"] as? String == "/v1/responses" && modelRequests[2]["strict"] as? Bool == true,
                      "Muse uses Responses with a strict schema")
            try check(modelRequests[3]["path"] as? String == "/v1/chat/completions" && modelRequests[3]["effort"] as? String == "high"
                      && modelRequests[3]["format"] as? String == "json_object" && modelRequests[3]["system_schema"] as? Bool == true,
                      "DeepSeek uses Chat Completions, high reasoning, JSON mode, and the note edit schema")
            try check(assistant.session(for: note.id).messages.filter { $0.role == .assistant }.map(\.modelLabel)
                      == ["GPT 6 Luna", "GPT 5.6 Luna", "Muse Spark 1.3 Contributor", "DeepSeek V4.1 Flash", "Grok 4.7"], "switching models preserves each reply's author")
            try check(assistant.session(for: other.id).selectedModel == .luna, "model selection is isolated to its note")
            let legacy = Data("""
                {"id":"00000000-0000-0000-0000-000000000001","noteID":"00000000-0000-0000-0000-000000000002",
                 "draft":"Old draft","awaitingReply":false,"messages":[
                 {"id":"00000000-0000-0000-0000-000000000003","role":"assistant","text":"Old reply"}]}
                """.utf8)
            let oldSession = try JSONDecoder().decode(NoteChatSession.self, from: legacy)
            try check(oldSession.selectedModel == .luna && oldSession.messages.first?.modelLabel == "GPT 6 Luna",
                      "existing conversations without model fields still load as Luna")
            // History is sent on follow-ups; a rejected key surfaces an actionable message; Stop cancels cleanly.
            editor.load(doc)
            assistant.setDraft("Follow up", for: note.id)
            assistant.send(note.id)
            try await waitUntil { !assistant.busyNotes.contains(note.id) }
            let after = ((try? String(contentsOf: requests, encoding: .utf8)) ?? "").split(separator: "\n").count
            try check(after == 6, "one request per message")
            assistant.setDraft("FAIL401", for: note.id)
            assistant.send(note.id)
            try await waitUntil { !assistant.busyNotes.contains(note.id) }
            try check(assistant.session(for: note.id).messages.last?.text.contains("rejected the API key") == true, "rejected key explains how to recover")
            assistant.setDraft("SLOW", for: note.id)
            assistant.send(note.id)
            try await Task.sleep(for: .milliseconds(300))
            try check(assistant.busyNotes.contains(note.id), "slow reply keeps the note busy")
            assistant.setModel(.luna, for: note.id)
            assistant.setModel(.luna56, for: other.id)
            try check(assistant.session(for: note.id).selectedModel == .grok && assistant.session(for: other.id).selectedModel == .luna56,
                      "an active request locks only its note's model picker")
            assistant.stop(note.id)
            try check(!assistant.busyNotes.contains(note.id) && assistant.session(for: note.id).messages.last?.text.contains("Stopped") == true, "Stop ends the request without changes")
            try await Task.sleep(for: .milliseconds(300))
            try check(editor.document == doc && assistant.session(for: note.id).messages.last?.role == .notice, "late reply after Stop is discarded")
            assistant.newConversation(note.id)
            try check(assistant.archives.contains { $0.noteID == note.id } && assistant.session(for: other.id).draft == "Keep this draft", "new conversation archives history without touching another note")
            try check(assistant.session(for: note.id).selectedModel == .grok, "new conversation keeps this note's model choice")
            assistant.shutdown()

            let restored = NoteAssistant(app: app, storageRoot: root.appendingPathComponent("Chat"))
            try check(restored.session(for: other.id).draft == "Keep this draft" && !restored.archives.isEmpty, "history and per-note drafts survive reload")
            try check(restored.session(for: note.id).selectedModel == .grok && restored.session(for: other.id).selectedModel == .luna56
                      && restored.archives.first?.messages.filter { $0.role == .assistant }.prefix(5).map(\.modelLabel)
                      == ["GPT 6 Luna", "GPT 5.6 Luna", "Muse Spark 1.3 Contributor", "DeepSeek V4.1 Flash", "Grok 4.7"], "model choices and reply attribution survive reload and archiving")
            restored.shutdown()
            assistant.setDraft("NOCHANGE", for: note.id)
            assistant.send(note.id)
            try await waitUntil { !assistant.busyNotes.contains(note.id) }
            try check(assistant.session(for: note.id).messages.last?.role == .assistant
                      && assistant.session(for: note.id).messages.last?.proposal == nil && editor.document == doc,
                      "unchanged replacements do not produce misleading edit cards")
            assistant.shutdown()
            let deepseek = ChatClient(apiKey: "test-opencode-key", baseURL: assistant.baseURL, model: .deepseekFlash)
            for (prompt, expected) in [("TRUNCATED", "cut off"), ("REFUSAL", "declined"), ("EMPTY", "didn't return a reply")] {
                var failure = ""
                do {
                    _ = try await deepseek.complete(instructions: "Return JSON.", turns: [ChatTurn(role: "user", text: prompt)], schema: AssistantReply.schema)
                } catch { failure = error.localizedDescription }
                try check(failure.contains(expected), "DeepSeek rejects \(prompt.lowercased()) replies without exposing reasoning")
            }
            let _: Bool = library.flush() // the blocking overload; the async one needs await
            if let directory = ProcessInfo.processInfo.environment["NOTAS_REVIEW_PREVIEWS"] {
                try renderReviewPreviews(to: URL(fileURLWithPath: directory))
                try check(true, "native review cards rendered in light and dark themes")
            }
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

    private static func renderReviewPreviews(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let proposal = AssistantProposal(id: UUID(), noteID: UUID(), revision: "preview", operations: [
            AssistantOperation(action: .replace, block: 2, text: "We should leave on Friday to make the most of the weekend.", kind: "body"),
            AssistantOperation(action: .insertAfter, block: 3, text: "Bring a jacket for the cold evenings.", kind: "body")
        ], before: ["We should leave on friday so we can have more time there.", "Packing"], diskRevision: nil,
           locations: ["The plan · paragraph 1", "After Packing · heading"], removesFormatting: [false, false])
        for theme in ["paper", "midnight"] {
            let style = ResolvedStyle(style: NoteStyle(themeID: theme), systemIsDark: theme == "midnight", appAccent: .violet)
            let content = NoteProposalCard(proposal: proposal, style: style, readOnly: false, busy: false, accept: {}, acceptOne: { _ in }, skip: { _ in }, keepOriginal: {})
                .foregroundStyle(style.text).padding(16)
                .frame(width: 356, height: 660, alignment: .topLeading)
                .background(style.background).environment(\.colorScheme, style.colorScheme)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw AssistantError.message("Could not render review card")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw AssistantError.message("Could not encode review card image")
            }
            try data.write(to: directory.appendingPathComponent("review-\(theme).png"))
            window.close()
        }
    }
}
#endif
