#if DEBUG
import AppKit

@MainActor
enum ChatStabilityTests {
    static func run() async -> Bool {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notas-chat-stability-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        var blocked: [String] = []
        do { try await scalars(root: root) } catch { failures.append(error.localizedDescription) }
        do { try await streamsAndEdits(root: root, blocked: &blocked) } catch { failures.append(error.localizedDescription) }
        do { try await history(root: root) } catch { failures.append(error.localizedDescription) }
        do { try await previews() } catch { failures.append(error.localizedDescription) }
        if !blocked.isEmpty { print("BLOCKED: \(blocked.joined(separator: "; "))") }
        if failures.isEmpty {
            print("✓ chat stability checks passed")
            return true
        }
        print("✗ chat stability failed: \(failures.joined(separator: " | "))")
        return false
    }

    private static func scalars(root: URL) async throws {
        let base = document(["T", "A", "B", "C"])
        for sample in ["\r", "\n", "\u{2029}", "\u{FFFC}", "\u{0000}", "\r\n"] {
            var rejected = false
            do {
                _ = try NoteEdit.applying([AssistantOperation(action: .replace, block: 1, text: "X\(sample)Y", kind: "body")], to: base)
            } catch { rejected = true }
            try check(rejected, "scalar \(sample.debugDescription) is rejected before an edit is offered")
        }
        _ = root
    }

    private static func streamsAndEdits(root: URL, blocked: inout [String]) async throws {
        let session = fixtureSession()
        let credentials = MemoryCredentials(key: "fixture-key")
        let harness = try Harness(root: root.appendingPathComponent("edits"), credentials: credentials, session: session)
        let base = document(["T", "A", "B", "C"])
        let note = try harness.open(base)
        try check(harness.editor.document == base, "editor opens [T, A, B, C]")

        func reply(_ name: String, _ operations: [AssistantOperation], terminal: String) throws -> (String, Data) {
            let text = String(decoding: try JSONEncoder().encode(AssistantReply(reply: "Fixture reply", operations: operations)), as: UTF8.self)
            return try stream(text, terminal: terminal, host: name)
        }
        let crlf = [AssistantOperation(action: .replace, block: 1, text: "X\r\nY", kind: "body"),
                    AssistantOperation(action: .replace, block: 3, text: "C2", kind: "body")]
        let good = AssistantOperation(action: .replace, block: 1, text: "NEW", kind: "body")
        let partial = [AssistantOperation(action: .replace, block: 1, text: "A2", kind: "body"),
                       AssistantOperation(action: .replace, block: 3, text: "C2", kind: "body")]
        ChatFixtureProtocol.store(try reply("crlf", crlf, terminal: "normal"))
        ChatFixtureProtocol.store(try reply("failed", [good], terminal: "failed"))
        ChatFixtureProtocol.store(try reply("done", [good], terminal: "done"))
        ChatFixtureProtocol.store(try reply("refusal", [good], terminal: "refusal"))
        ChatFixtureProtocol.store(try reply("refusaltext", [good], terminal: "refusal-after-text"))
        ChatFixtureProtocol.store(try reply("valid", partial, terminal: "normal"))
        ChatFixtureProtocol.store(try stream(#"{"reply":"Hello \ud83d\ude00 world","operations":[]}"#, terminal: "normal", host: "emoji"))

        try await harness.send("crlf", note: note, draft: "Reject the line break")
        try check(harness.last?.role == .notice && harness.last?.text.contains("invalid") == true,
                  "CRLF send finishes as an invalid-edit notice")
        try check(harness.assistant.session(for: note).messages.allSatisfy { $0.proposal == nil }, "CRLF send offers no proposal")
        try check(harness.editor.document == base, "CRLF send leaves [T, A, B, C]")

        try await harness.send("failed", note: note, draft: "Take the failure")
        try check(harness.last?.role == .notice && harness.last?.text.contains("Failure") == true, "nested response.failed becomes an error notice")
        try check(harness.last?.proposal == nil && harness.editor.document == base, "failed stream leaves [T, A, B, C] with no proposal")

        try await harness.send("done", note: note, draft: "Stop at done")
        try check(harness.last?.role == .notice && harness.last?.text.contains("didn't return a reply") == true,
                  "[DONE] does not promote the buffered JSON")
        try check(harness.last?.proposal == nil && harness.editor.document == base, "[DONE] leaves the document unchanged")

        try await harness.send("refusal", note: note, draft: "Respect the refusal")
        try check(harness.last?.role == .notice && harness.last?.text.contains("declined") == true, "completed refusal becomes a refusal notice")
        try check(harness.last?.proposal == nil && harness.editor.document == base, "refusal leaves [T, A, B, C] with no proposal")

        try await harness.send("refusaltext", note: note, draft: "Refusal after text")
        try check(harness.last?.role == .notice && harness.last?.text.contains("declined") == true,
                  "refusal after an output-text part stays a refusal")
        try check(harness.last?.proposal == nil && harness.editor.document == base, "earlier deltas do not supply a proposal")

        try await harness.send("valid", note: note, draft: "Apply the safe edits")
        guard let proposal = harness.last?.proposal, harness.last?.role == .assistant else {
            throw failure("normal terminal success produces a proposal")
        }
        try check(harness.editor.document == base, "a proposal does not change the note by itself")
        harness.assistant.error = nil
        harness.assistant.apply(proposal.id, noteID: note, only: 0)
        try check(harness.assistant.error == nil && texts(harness.editor.document) == ["T", "A2", "B", "C"],
                  "the first valid change leaves B untouched")
        harness.assistant.apply(proposal.id, noteID: note)
        try check(harness.assistant.error == nil && texts(harness.editor.document) == ["T", "A2", "B", "C2"],
                  "the remaining valid change yields [T, A2, B, C2]")

        try await harness.send("emoji", note: note, draft: "Show the emoji")
        try check(harness.last?.role == .assistant && harness.last?.text == "Hello 😀 world" && harness.last?.proposal == nil,
                  "final JSON decoding is the authoritative reply")
        try check(ChatFixtureProtocol.authorizations.allSatisfy { $0 == "Bearer fixture-key" },
                  "fixture requests use the in-memory credential")

        try persistedCRLF(in: harness, base: base)
        try await trailingBlocks(in: harness, blocked: &blocked)
    }

    private static func persistedCRLF(in harness: Harness, base: NoteDocument) throws {
        let created = harness.library.createNote(in: nil)
        harness.library.updateDocument(created.id, base)
        harness.library.flush()
        let note = created.id
        harness.app.open(note, newTab: true)
        harness.editor.noteID = note
        harness.editor.load(base)
        harness.app.activeEditor = harness.editor
        let proposalID = UUID()
        let session = NoteChatSession(noteID: note, messages: [NoteChatMessage(
            role: .assistant, text: "Old suggestion",
            proposal: AssistantProposal(id: proposalID, noteID: note, revision: try NoteEdit.revision(base), operations: [
                AssistantOperation(action: .replace, block: 1, text: "X\r\nY", kind: "body"),
                AssistantOperation(action: .replace, block: 3, text: "C2", kind: "body")
            ], before: ["A", "C"], diskRevision: nil, locations: nil, removesFormatting: nil)
        )])
        let storage = harness.library.rootURL.deletingLastPathComponent().appendingPathComponent("persisted-crlf")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let saved = try JSONEncoder().encode(HistoryFile(version: 1, sessions: [session], archives: []))
        try saved.write(to: storage.appendingPathComponent("sessions.json"))
        let loaded = NoteAssistant(app: harness.app, storageRoot: storage, credentials: harness.credentials.access, urlSession: harness.session)
        loaded.error = nil
        loaded.apply(proposalID, noteID: note, only: 0)
        try check(loaded.error?.contains("invalid") == true, "an old CRLF proposal is rejected when accepted")
        try check(harness.editor.document == base, "rejecting the old CRLF proposal leaves [T, A, B, C]")
        try check(loaded.session(for: note).messages.contains { $0.proposal?.state == .pending } , "the rejected proposal is not marked applied")
        loaded.shutdown()
    }

    private static func trailingBlocks(in harness: Harness, blocked: inout [String]) async throws {
        let title = NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "T")])])
        let cases: [(String, NoteDocument, AssistantOperation)] = [
            ("checklist", NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .checklist, checked: false, runs: [])]),
             AssistantOperation(action: .insertAfter, block: 0, text: "", kind: "checklist")),
            ("heading", NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .heading1, runs: [])]),
             AssistantOperation(action: .insertAfter, block: 0, text: "", kind: "heading1")),
            ("bullet", NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .bullet, runs: [])]),
             AssistantOperation(action: .insertAfter, block: 0, text: "", kind: "bullet")),
            ("newline", NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [])]),
             AssistantOperation(action: .insertAfter, block: 0, text: "", kind: "body"))
        ]
        for (label, expected, operation) in cases {
            let actual = RichTextCodec.document(from: RichTextCodec.attributedString(from: expected))
            if label != "newline", actual != expected {
                print("C5 BLOCKED on the editor codec for \(label). Strict expected \(describe(expected)). Codec produced \(describe(actual)).")
                blocked.append("C5 \(label)")
                continue
            }
            try check(actual == expected, "\(label) round-trips before acceptance")
            let host = "trail-\(label)"
            ChatFixtureProtocol.store(try stream(String(decoding: try JSONEncoder().encode(AssistantReply(reply: "Add \(label)", operations: [operation])), as: UTF8.self), terminal: "normal", host: host))
            let note = try harness.open(title)
            try await harness.send(host, note: note, draft: "Add \(label)")
            guard let proposal = harness.last?.proposal else { throw failure("\(label) acceptance produced no proposal") }
            harness.assistant.error = nil
            harness.editor.undoManager?.groupsByEvent = false
            harness.assistant.apply(proposal.id, noteID: note)
            try check(harness.assistant.error == nil && harness.editor.document == expected,
                      "accept \(label) yields \(describe(expected))")
            harness.library.updateDocument(note, harness.editor.document)
            let _: Bool = harness.library.flush()
            let reloaded = LibraryStore(rootURL: harness.library.rootURL)
            reloaded.load()
            try check(reloaded.notes[note]?.document == expected, "reopen \(label) yields \(describe(expected))")
            harness.editor.undoManager?.undo()
            try check(harness.editor.document == title, "undo \(label) restores [title T]")
        }
    }

    private static func history(root: URL) async throws {
        let credentials = MemoryCredentials(key: "fixture-key")
        try await preserved(root: root.appendingPathComponent("corrupt"), credentials: credentials, bytes: Data("{truncated".utf8), label: "corrupt history")
        let version2 = try JSONEncoder().encode(HistoryFile(version: 2, sessions: [NoteChatSession(noteID: UUID(), messages: [NoteChatMessage(role: .user, text: "Keep this history")])], archives: []))
        try await preserved(root: root.appendingPathComponent("version2"), credentials: credentials, bytes: version2, label: "unsupported v2 history")
        try await validV1(root: root.appendingPathComponent("valid"), credentials: credentials)
        try await recover(root: root.appendingPathComponent("recover"), credentials: credentials, bytes: Data("{truncated".utf8))
    }

    private static func preserved(root: URL, credentials: MemoryCredentials, bytes: Data, label: String) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sessions.json")
        try bytes.write(to: file)
        let parent = root.deletingLastPathComponent()
        let quiet = try Harness(root: parent.appendingPathComponent("\(root.lastPathComponent)-quiet"), credentials: credentials, session: fixtureSession(), assistantRoot: root)
        try check(quiet.assistant.error?.contains("kept") == true, "\(label) is reported and kept")
        let untouched = quiet.assistant.shutdown()
        try check(untouched == nil && Data(contentsOf: file) == bytes, "\(label) with no new draft is not rewritten on shutdown")
        try check(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).allSatisfy { $0.lastPathComponent == "sessions.json" },
                  "\(label) shutdown writes no recovery when nothing changed")

        let live = try Harness(root: parent.appendingPathComponent("\(root.lastPathComponent)-live"), credentials: credentials, session: fixtureSession(), assistantRoot: root)
        let note = try live.open(document(["T"]))
        live.assistant.setDraft("Recovered draft", for: note)
        live.assistant.setModel(.grok, for: note)
        try await Task.sleep(for: .milliseconds(700))
        try check(Data(contentsOf: file) == bytes, "\(label) stays byte-identical after a draft change")
        live.assistant.error = nil
        live.assistant.send(note)
        try await Task.sleep(for: .milliseconds(50))
        try check(!live.assistant.busyNotes.contains(note) && live.assistant.session(for: note).messages.isEmpty,
                  "\(label) does not start a reply")
        try check(live.assistant.session(for: note).draft == "Recovered draft", "the draft remains when history cannot be saved")
        try check(Data(contentsOf: file) == bytes, "a refused send does not rewrite \(label)")
        _ = live.assistant.shutdown()
        try check(Data(contentsOf: file) == bytes, "\(label) stays byte-identical across shutdown")
        let others = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != "sessions.json" }
        let recovery = others.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        try check(recovery.contains("Recovered draft"), "\(label) recovery contains the draft in a separate file")
    }

    private static func validV1(root: URL, credentials: MemoryCredentials) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let note = UUID()
        let original = try JSONEncoder().encode(HistoryFile(version: 1, sessions: [NoteChatSession(noteID: note, draft: "Old draft")], archives: []))
        let file = root.appendingPathComponent("sessions.json")
        try original.write(to: file)
        let harness = try Harness(root: root.appendingPathComponent("library"), credentials: credentials, session: fixtureSession(), assistantRoot: root)
        try check(harness.assistant.error == nil, "valid v1 history loads")
        harness.assistant.setDraft("Keep this draft", for: note)
        try await Task.sleep(for: .milliseconds(700))
        _ = harness.assistant.shutdown()
        let saved = try JSONDecoder().decode(HistoryFile.self, from: Data(contentsOf: file))
        try check(saved.version == 1 && saved.sessions.contains { $0.noteID == note && $0.draft == "Keep this draft" },
                  "valid v1 history persists Keep this draft")
    }

    private static func recover(root: URL, credentials: MemoryCredentials, bytes: Data) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sessions.json")
        try bytes.write(to: file)
        let harness = try Harness(root: root.appendingPathComponent("library"), credentials: credentials, session: fixtureSession(), assistantRoot: root)
        let note = try harness.open(document(["T"]))
        harness.assistant.setDraft("Recovered draft", for: note)
        try harness.assistant.recoverHistory()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard let backupURL = files.first(where: { $0.lastPathComponent.hasPrefix("sessions-backup-") }) else {
            throw failure("explicit recovery did not write a backup")
        }
        let backup = try Data(contentsOf: backupURL)
        try check(backup == bytes, "explicit recovery keeps the original bytes in a backup")
        let saved = try JSONDecoder().decode(HistoryFile.self, from: Data(contentsOf: file))
        try check(saved.version == 1 && saved.sessions.contains { $0.draft == "Recovered draft" }, "explicit recovery initializes v1 with the draft")
        harness.assistant.setDraft("After recovery", for: note)
        _ = harness.assistant.shutdown()
        let after = try JSONDecoder().decode(HistoryFile.self, from: Data(contentsOf: file))
        try check(after.sessions.contains { $0.draft == "After recovery" }, "a recovered history file accepts later drafts")
        try check(Data(contentsOf: backupURL) == bytes, "the backup remains the original rejected bytes")
    }

    private static func previews() async throws {
        let raw = #"{"reply":"Hello \ud83d\ude00 world","operations":[]}"#
        guard let high = raw.range(of: "\\ud83d"), let low = raw.range(of: "\\ude00") else {
            throw failure("emoji fixture is missing its escapes")
        }
        var cursor = high.lowerBound
        while cursor < low.upperBound {
            let prefix = String(raw[..<cursor])
            let preview = ChatClient.visibleReply(in: prefix)
            try check(preview == "Hello ", "incomplete surrogate \(prefix.debugDescription) previews \(preview.debugDescription)")
            cursor = raw.index(after: cursor)
        }
        try check(ChatClient.visibleReply(in: String(raw[..<low.upperBound])) == "Hello 😀", "a complete surrogate pair previews the emoji")
        let decoded = try JSONDecoder().decode(AssistantReply.self, from: Data(raw.utf8)).reply
        try check(decoded == "Hello 😀 world" && ChatClient.visibleReply(in: raw) == decoded, "the complete preview matches JSON decoding")
        let controls = #"{"reply":"Say \"hi\"\n\r\t\u0041\u000A\u0000","operations":[]}"#
        let controlsDecoded = try JSONDecoder().decode(AssistantReply.self, from: Data(controls.utf8)).reply
        try check(controlsDecoded == "Say \"hi\"\n\r\tA\n\u{0}" && ChatClient.visibleReply(in: controls) == controlsDecoded,
                  "escaped quotes and BMP controls survive and match JSON decoding")

        let first = EditDifference.between("A\u{1}B", "C")
        let second = EditDifference.between("A", "B\u{1}C")
        let firstAgain = EditDifference.between("A\u{1}B", "C")
        let secondAgain = EditDifference.between("A", "B\u{1}C")
        try check(reconstructed(first, original: true) == "A\u{1}B" && reconstructed(first, original: false) == "C",
                  "the first U+0001 pair reconstructs A, separator, B against C")
        try check(reconstructed(second, original: true) == "A" && reconstructed(second, original: false) == "B\u{1}C",
                  "the second U+0001 pair reconstructs A against B, separator, C")
        try check(firstAgain == first && secondAgain == second, "the diff cache returns each pair independently")
    }

    private static func reconstructed(_ parts: [EditDifference], original: Bool) -> String {
        parts.filter { original ? $0.kind != .added : $0.kind != .removed }.map(\.text).joined()
    }

    private static func stream(_ text: String, terminal: String, host: String) throws -> (String, Data) {
        let delta = try sse(["type": "response.output_text.delta", "delta": text])
        let done = Data("data: [DONE]\n\n".utf8)
        let body: Data
        switch terminal {
        case "failed":
            body = delta + (try sse(["type": "response.failed", "response": ["status": "failed", "error": ["message": "Failure"]]])) + done
        case "done":
            body = delta + done
        case "refusal":
            body = delta + (try sse(["type": "response.completed", "response": [
                "status": "completed",
                "output": [["type": "message", "content": [["type": "refusal", "refusal": "Declined"]]]]
            ]]))
        case "refusal-after-text":
            body = delta + (try sse(["type": "response.output_text.done", "text": text])) + (try sse(["type": "response.completed", "response": [
                "status": "completed",
                "output": [["type": "message", "content": [
                    ["type": "output_text", "text": text],
                    ["type": "refusal", "refusal": "Declined"]
                ]]]
            ]]))
        default:
            body = delta + (try sse(["type": "response.completed", "response": [
                "status": "completed",
                "output": [["type": "reasoning", "id": "rs"], ["type": "message", "content": [["type": "output_text", "text": text]]]]
            ]])) + done
        }
        return (host, body)
    }

    private static func sse(_ object: [String: Any]) throws -> Data {
        var data = Data("data: ".utf8)
        data.append(try JSONSerialization.data(withJSONObject: object))
        data.append(Data("\n\n".utf8))
        return data
    }

    private static func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatFixtureProtocol.self]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    private static func document(_ lines: [String]) -> NoteDocument {
        NoteDocument(blocks: lines.enumerated().map { index, text in
            Block(kind: index == 0 ? .title : .body, runs: [InlineRun(text: text)])
        })
    }

    private static func texts(_ document: NoteDocument) -> [String] { document.blocks.map(\.plainText) }

    private static func describe(_ document: NoteDocument) -> String {
        document.blocks.map { "\($0.kind.rawValue)(\($0.plainText.debugDescription), checked: \(String(describing: $0.checked)))" }.joined(separator: ", ")
    }

    private static func check(_ condition: Bool, _ label: String) throws {
        guard condition else {
            print("FAIL: \(label)")
            throw failure(label)
        }
        print("PASS: \(label)")
    }

    private static func failure(_ label: String) -> AssistantError { .message("FAIL: \(label)") }
}

private struct HistoryFile: Codable {
    let version: Int
    let sessions: [NoteChatSession]
    let archives: [NoteChatSession]
}

private final class MemoryCredentials {
    var key: String?
    init(key: String?) { self.key = key }
    var access: AssistantCredentialAccess {
        AssistantCredentialAccess(read: { self.key }, save: { self.key = $0 }, delete: { self.key = nil })
    }
}

@MainActor
private final class Harness {
    let library: LibraryStore
    let app: AppState
    let assistant: NoteAssistant
    let editor: NotasTextView
    let credentials: MemoryCredentials
    let session: URLSession
    let assistantRoot: URL
    private let window: NSWindow

    var last: NoteChatMessage? {
        guard let id = app.activeNoteID else { return nil }
        return assistant.session(for: id).messages.last
    }

    init(root: URL, credentials: MemoryCredentials, session: URLSession, assistantRoot: URL? = nil) throws {
        self.credentials = credentials
        self.session = session
        self.assistantRoot = assistantRoot ?? root.appendingPathComponent("assistant")
        library = LibraryStore(rootURL: root.appendingPathComponent("library"))
        library.load()
        let preferences = UserDefaults(suiteName: "notas.chat.stability.\(UUID().uuidString)")!
        app = AppState(store: library, preferences: preferences)
        assistant = NoteAssistant(app: app, storageRoot: self.assistantRoot, credentials: credentials.access, urlSession: session)
        editor = NotasTextView.make()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        app.activeEditor = editor
    }

    func open(_ document: NoteDocument) throws -> UUID {
        let note = library.createNote(in: nil)
        library.updateDocument(note.id, document)
        library.flush()
        app.open(note.id, newTab: true)
        editor.noteID = note.id
        editor.load(document)
        app.activeEditor = editor
        editor.undoManager?.groupsByEvent = false
        return note.id
    }

    func send(_ host: String, note: UUID, draft: String) async throws {
        assistant.baseURL = URL(string: "https://\(host).invalid/v1")!
        assistant.error = nil
        assistant.setDraft(draft, for: note)
        assistant.send(note)
        for _ in 0..<200 {
            if !assistant.busyNotes.contains(note) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AssistantError.message("FAIL: \(host) timed out")
    }
}

private final class ChatFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    nonisolated(unsafe) static var authorizations: [String] = []

    static func store(_ payload: (String, Data)) {
        Self.lock.lock()
        bodies[payload.0] = payload.1
        Self.lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        let key = url.host?.split(separator: ".").first.map(String.init) ?? ""
        Self.lock.lock()
        let body = Self.bodies[key]
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            Self.authorizations.append(authorization)
        }
        Self.lock.unlock()
        guard let body, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]) else {
            client.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
