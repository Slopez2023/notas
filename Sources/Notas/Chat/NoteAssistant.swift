import AppKit
import Observation

struct NoteChatMessage: Codable, Identifiable {
    var id = UUID()
    let role: Role
    var text: String
    var proposal: AssistantProposal?
    enum Role: String, Codable { case user, assistant, notice }
}

struct NoteChatSession: Codable, Identifiable {
    var id = UUID()
    let noteID: UUID
    var draft = ""
    var messages: [NoteChatMessage] = []
    var awaitingReply = false
    var baseRevision: String?
    var diskRevision: String?
}

@MainActor
@Observable
final class NoteAssistant {
    private(set) var sessions: [UUID: NoteChatSession] = [:]
    private(set) var archives: [NoteChatSession] = []
    private(set) var busyNotes: Set<UUID> = []
    private(set) var hasKey = false
    var error: String?
    var modelLabel: String { ChatClient.modelName }
    var status: String { hasKey ? "\(ChatClient.modelName) · medium reasoning" : "Add an OpenCode API key to chat about this note." }
    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let io = DispatchQueue(label: "notas.assistant.persistence")
    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored var baseURL = ChatClient.defaultBaseURL
    @ObservationIgnored private var snapshots: [UUID: NoteDocument] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    private struct Saved: Codable {
        let version: Int
        let sessions: [NoteChatSession]
        let archives: [NoteChatSession]
    }

    init(app: AppState, storageRoot: URL? = nil) {
        self.app = app
        let library = app.store.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let identity = (try? NoteEdit.revision(NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: library)])]))) ?? UUID().uuidString
        let support = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notas/Assistant/\(identity)", isDirectory: true)
        stateURL = support.appendingPathComponent("sessions.json")
        if let data = try? Data(contentsOf: stateURL) {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: data)
                guard saved.version == 1 else { throw AssistantError.message("Chat history uses an unsupported version.") }
                sessions = Dictionary(saved.sessions.map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
                archives = saved.archives
                // A reply that was in flight when the app closed is gone; never resend it automatically.
                for id in sessions.keys where sessions[id]?.awaitingReply == true {
                    sessions[id]?.awaitingReply = false
                    sessions[id]?.messages.append(NoteChatMessage(role: .notice, text: "Notas closed before this reply arrived. Send your message again."))
                }
            } catch { self.error = "Chat history couldn't be loaded. The saved file has been kept. \(error.localizedDescription)" }
        }
        // `scripts/run.sh` exports a key from the project's .env.local. Adopt it once so later launches use the Keychain.
        if AssistantKeychain.read() == nil, let fromEnvironment = ProcessInfo.processInfo.environment["OPENCODE_API_KEY"], !fromEnvironment.isEmpty {
            try? AssistantKeychain.save(fromEnvironment)
        }
        apiKey = AssistantKeychain.read()
        hasKey = apiKey != nil
    }

    func session(for noteID: UUID) -> NoteChatSession {
        sessions[noteID] ?? NoteChatSession(noteID: noteID)
    }

    private func ensureSession(_ noteID: UUID) {
        if sessions[noteID] == nil { sessions[noteID] = NoteChatSession(noteID: noteID) }
    }

    func setDraft(_ text: String, for noteID: UUID) {
        ensureSession(noteID)
        sessions[noteID]?.draft = String(text.prefix(16_000))
        persist()
    }

    func saveKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 }) else {
            error = "That doesn't look like an API key. Paste the key exactly as OpenCode shows it."; return
        }
        do { try AssistantKeychain.save(key) } catch { self.error = error.localizedDescription; return }
        apiKey = key; hasKey = true; error = nil
    }

    func removeKey() {
        guard busyNotes.isEmpty else { return }
        AssistantKeychain.delete()
        apiKey = nil; hasKey = false
    }

    func send(_ noteID: UUID) {
        guard let apiKey, !busyNotes.contains(noteID), let app else { return }
        ensureSession(noteID)
        guard let editor = app.activeEditor, app.activeNoteID == noteID, editor.noteID == noteID, !editor.hasMarkedText() else {
            error = "Open this note and finish typing before sending."; return
        }
        let prompt = sessions[noteID]?.draft.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { return }
        do {
            let document = editor.document
            let context = try NoteEdit.context(document)
            let revision = try NoteEdit.revision(document)
            let earlier = (sessions[noteID]?.messages ?? []).filter { $0.role != .notice }.suffix(20).map {
                ChatTurn(role: $0.role == .user ? "user" : "assistant", text: $0.text)
            }
            let decisions = sessions[noteID]?.messages.compactMap { message -> String? in
                guard let proposal = message.proposal else { return nil }
                return "Proposal \(proposal.id): \(proposal.state.rawValue)"
            }.suffix(10).joined(separator: "\n") ?? ""
            let turns = earlier + [ChatTurn(role: "user", text: "Current note snapshot:\n\(context)\nRecent proposal decisions:\n\(decisions)\nUser request:\n\(prompt)")]
            snapshots[noteID] = document
            if document.isEmpty { app.store.mutate(noteID, touch: false) { $0.retainsEmptyDocument = true } }
            sessions[noteID]?.messages.append(NoteChatMessage(role: .user, text: prompt))
            sessions[noteID]?.draft = ""
            sessions[noteID]?.baseRevision = revision
            sessions[noteID]?.diskRevision = diskRevision(noteID)
            sessions[noteID]?.awaitingReply = true
            try saveNow()
            busyNotes.insert(noteID)
            let conversation = sessions[noteID]!.id
            let client = ChatClient(apiKey: apiKey, baseURL: baseURL)
            tasks[noteID] = Task { [weak self] in
                do {
                    let text = try await client.complete(instructions: NoteEdit.instructions, turns: turns, schema: AssistantReply.schema)
                    guard let self, !Task.isCancelled, self.sessions[noteID]?.id == conversation else { return }
                    self.finish(noteID, text: text)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, !Task.isCancelled, self.sessions[noteID]?.id == conversation else { return }
                    self.fail(noteID, error.localizedDescription)
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func stop(_ noteID: UUID) {
        guard busyNotes.contains(noteID) else { return }
        tasks.removeValue(forKey: noteID)?.cancel()
        busyNotes.remove(noteID)
        snapshots[noteID] = nil
        sessions[noteID]?.awaitingReply = false
        addNotice("Stopped. No changes were applied.", to: noteID)
    }

    func newConversation(_ noteID: UUID) {
        guard !busyNotes.contains(noteID) else { return }
        if let old = sessions[noteID], !old.messages.isEmpty { archives.append(old) }
        sessions[noteID] = NoteChatSession(noteID: noteID)
        persist()
    }

    func dismiss(_ proposalID: UUID, noteID: UUID) {
        guard let i = sessions[noteID]?.messages.firstIndex(where: { $0.proposal?.id == proposalID }) else { return }
        sessions[noteID]?.messages[i].proposal?.state = .dismissed
        persist()
    }

    func apply(_ proposalID: UUID, noteID: UUID) {
        guard let app, let i = sessions[noteID]?.messages.firstIndex(where: { $0.proposal?.id == proposalID }),
              let proposal = sessions[noteID]?.messages[i].proposal, proposal.state == .pending,
              proposal.noteID == noteID, app.store.notes[noteID] != nil,
              let editor = app.activeEditor, editor.noteID == noteID, app.activeNoteID == noteID else {
            error = "Reopen the original note to apply this change."; return
        }
        do {
            guard !editor.hasMarkedText(), try NoteEdit.revision(editor.document) == proposal.revision else {
                throw AssistantError.message("The note changed since this suggestion. Ask for a fresh edit so your typing stays safe.")
            }
            if let disk = diskRevision(noteID), disk != proposal.diskRevision, disk != proposal.revision {
                throw AssistantError.message("The note changed on disk. Reopen Notas to load that version before editing with chat.")
            }
            let document = try NoteEdit.applying(proposal.operations, to: editor.document)
            editor.applyAssistantDocument(document)
            app.store.updateDocument(noteID, editor.document)
            sessions[noteID]?.messages[i].proposal?.state = .applied
            persist()
        } catch { self.error = error.localizedDescription }
    }

    func deleteNote(_ noteID: UUID) {
        stop(noteID)
        if let session = sessions.removeValue(forKey: noteID) { archives.append(session) }
        persist()
    }

    func shutdown() {
        tasks.values.forEach { $0.cancel() }
        persist()
        io.sync {}
    }

    private func fail(_ noteID: UUID, _ message: String) {
        busyNotes.remove(noteID); tasks[noteID] = nil; snapshots[noteID] = nil
        sessions[noteID]?.awaitingReply = false
        addNotice(message, to: noteID)
    }

    private func finish(_ noteID: UUID, text: String) {
        busyNotes.remove(noteID); tasks[noteID] = nil
        defer { snapshots[noteID] = nil; persist() }
        guard sessions[noteID]?.awaitingReply == true else { return }
        sessions[noteID]?.awaitingReply = false
        do {
            guard text.utf8.count <= 250_000 else { throw AssistantError.message("The reply was too large.") }
            let reply = try JSONDecoder().decode(AssistantReply.self, from: Data(text.utf8))
            var proposal: AssistantProposal?
            if !reply.operations.isEmpty, let revision = sessions[noteID]?.baseRevision {
                let live = app?.activeEditor.flatMap { $0.noteID == noteID ? $0.document : nil } ?? app?.store.notes[noteID]?.document
                guard let snapshot = snapshots[noteID] ?? live, try NoteEdit.revision(snapshot) == revision else {
                    throw AssistantError.message("The note changed. Ask for a fresh suggestion.")
                }
                _ = try NoteEdit.applying(reply.operations, to: snapshot)
                proposal = AssistantProposal(id: UUID(), noteID: noteID, revision: revision, operations: reply.operations,
                                             before: reply.operations.map { snapshot.blocks[$0.block].plainText },
                                             diskRevision: sessions[noteID]?.diskRevision)
            }
            sessions[noteID]?.messages.append(NoteChatMessage(role: .assistant, text: reply.reply, proposal: proposal))
        } catch { addNotice("The reply couldn't be read safely. No changes were applied. \(error.localizedDescription)", to: noteID) }
    }

    private func diskRevision(_ noteID: UUID) -> String? {
        guard let app else { return nil }
        let path = app.store.rootURL.appendingPathComponent("Notes/\(noteID.uuidString).notas/note.json")
        guard let data = try? Data(contentsOf: path), let note = try? LibraryStore.decoder.decode(Note.self, from: data) else { return nil }
        return try? NoteEdit.revision(note.document)
    }

    private func addNotice(_ text: String, to noteID: UUID) {
        guard sessions[noteID] != nil else { return }
        sessions[noteID]?.messages.append(NoteChatMessage(role: .notice, text: text))
        persist()
    }

    private func encodedState() throws -> Data {
        try JSONEncoder().encode(Saved(version: 1, sessions: Array(sessions.values), archives: archives))
    }

    private func saveNow() throws {
        let data = try encodedState(), url = stateURL
        try io.sync {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
        }
    }

    private func persist() {
        do { try saveNow() }
        catch { self.error = "Chat history couldn't be saved. \(error.localizedDescription)" }
    }
}
