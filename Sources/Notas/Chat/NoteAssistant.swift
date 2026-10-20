import AppKit
import Observation

struct NoteChatMessage: Codable, Identifiable {
    var id = UUID()
    let role: Role
    var text: String
    var thought: String?
    var proposal: AssistantProposal?
    var modelID: String?
    var modelLabel: String { modelID.map { ChatModel(rawValue: $0)?.label ?? $0 } ?? ChatModel.luna.label }
    enum Role: String, Codable { case user, assistant, notice }
}

struct NoteChatSession: Codable, Identifiable {
    var id = UUID()
    let noteID: UUID
    var draft = ""
    var messages: [NoteChatMessage] = []
    var awaitingReply = false
    var baseRevision: String?
    var modelID: String?
    var selectedModel: ChatModel { modelID.flatMap(ChatModel.init(rawValue:)) ?? .luna }
}

@MainActor
@Observable
final class NoteAssistant {
    private(set) var sessions: [UUID: NoteChatSession] = [:]
    private(set) var archives: [NoteChatSession] = []
    private(set) var busyNotes: Set<UUID> = []
    private(set) var hasKey = false
    var error: String?
    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let io = DispatchQueue(label: "notas.assistant.persistence")
    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored var baseURL = ChatClient.defaultBaseURL
    @ObservationIgnored private let credentials: AssistantCredentialAccess
    @ObservationIgnored private let urlSession: URLSession?
    @ObservationIgnored private var historyAccess: HistoryAccess = .writable
    @ObservationIgnored private var historyDirty = false
    @ObservationIgnored private var snapshots: [UUID: NoteDocument] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var draftSaves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var placeholders: [UUID: UUID] = [:]

    private enum HistoryAccess {
        case writable
        case recoveryRequired(String)
    }

    private struct Saved: Codable {
        let version: Int
        let sessions: [NoteChatSession]
        let archives: [NoteChatSession]
    }

    init(app: AppState, storageRoot: URL? = nil, credentials: AssistantCredentialAccess? = nil, urlSession: URLSession? = nil) {
        self.app = app
        self.credentials = credentials ?? .keychain
        self.urlSession = urlSession
        let library = app.store.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let identity = (try? NoteEdit.revision(NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: library)])]))) ?? UUID().uuidString
        let support = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notas/Assistant/\(identity)", isDirectory: true)
        stateURL = support.appendingPathComponent("sessions.json")
        loadHistory()
        if credentials == nil {
            // `scripts/run.sh` exports a key from the project's .env.local. Adopt it once so later launches use the Keychain.
            if AssistantKeychain.read() == nil, let fromEnvironment = ProcessInfo.processInfo.environment["OPENCODE_API_KEY"], !fromEnvironment.isEmpty {
                try? AssistantKeychain.save(fromEnvironment)
            }
        }
        apiKey = self.credentials.read()
        hasKey = apiKey != nil
    }

    private func loadHistory() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateURL.path) else {
            historyAccess = .writable
            return
        }
        do {
            let data = try Data(contentsOf: stateURL)
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            guard saved.version == 1 else { throw AssistantError.message("Chat history uses an unsupported version.") }
            sessions = Dictionary(saved.sessions.map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
            archives = saved.archives
            // A reply that was in flight when the app closed is gone; never resend it automatically.
            for id in sessions.keys where sessions[id]?.awaitingReply == true {
                sessions[id]?.awaitingReply = false
                sessions[id]?.messages.append(NoteChatMessage(role: .notice, text: "Notas closed before this reply arrived. Send your message again."))
            }
            historyAccess = .writable
        } catch {
            historyAccess = .recoveryRequired(error.localizedDescription)
            self.error = "Chat history couldn't be loaded. The saved file has been kept. \(error.localizedDescription)"
        }
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
        historyDirty = true
        draftSaves[noteID]?.cancel()
        draftSaves[noteID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.draftSaves[noteID] = nil
            self.persist()
        }
    }

    func setModel(_ model: ChatModel, for noteID: UUID) {
        guard !busyNotes.contains(noteID) else { return }
        ensureSession(noteID)
        sessions[noteID]?.modelID = model.rawValue
        draftSaves.removeValue(forKey: noteID)?.cancel()
        persist()
    }

    func saveKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 }) else {
            error = "That doesn't look like an API key. Paste the key exactly as OpenCode shows it."; return
        }
        do { try credentials.save(key) } catch { self.error = error.localizedDescription; return }
        apiKey = key; hasKey = true; error = nil
    }

    func removeKey() {
        guard busyNotes.isEmpty else { return }
        credentials.delete()
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
        if case .recoveryRequired = historyAccess {
            historyDirty = true
            persist()
            error = "Chat history couldn't be saved. The saved file has been kept."
            return
        }
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
            sessions[noteID]?.awaitingReply = true
            draftSaves.removeValue(forKey: noteID)?.cancel()
            do { try saveNow() } catch {
                sessions[noteID]?.awaitingReply = false
                if sessions[noteID]?.messages.last?.role == .user { sessions[noteID]?.messages.removeLast() }
                sessions[noteID]?.draft = prompt
                self.error = "Chat history couldn't be saved. \(error.localizedDescription)"
                return
            }
            busyNotes.insert(noteID)
            let conversation = sessions[noteID]!.id
            let model = sessions[noteID]!.selectedModel
            let client = ChatClient(apiKey: apiKey, baseURL: baseURL, model: model, session: urlSession)
            let placeholderID = UUID()
            if !model.usesChatCompletions {
                placeholders[noteID] = placeholderID
                sessions[noteID]?.messages.append(NoteChatMessage(id: placeholderID, role: .assistant, text: "", modelID: model.rawValue))
            }
            tasks[noteID] = Task { [weak self] in
                do {
                    var completed: CompletedReply?
                    for try await event in client.reply(to: turns, effort: NoteEdit.effort(for: prompt)) {
                        guard let self, !Task.isCancelled, self.sessions[noteID]?.id == conversation, self.sessions[noteID]?.awaitingReply == true else { return }
                        switch event {
                        case .preview(let preview):
                            self.present(preview, noteID: noteID, messageID: placeholderID)
                        case .completed(let reply):
                            completed = reply
                        }
                    }
                    guard let self, !Task.isCancelled, self.sessions[noteID]?.id == conversation, self.sessions[noteID]?.awaitingReply == true else { return }
                    guard let completed else {
                        self.fail(noteID, "The assistant didn't return a reply.")
                        return
                    }
                    self.finish(noteID, completed: completed, model: model, messageID: model.usesChatCompletions ? nil : placeholderID)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, !Task.isCancelled, self.sessions[noteID]?.id == conversation, self.sessions[noteID]?.awaitingReply == true else { return }
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
        dropPlaceholder(noteID)
        addNotice("Stopped. No changes were applied.", to: noteID)
    }

    func newConversation(_ noteID: UUID) {
        guard !busyNotes.contains(noteID) else { return }
        draftSaves.removeValue(forKey: noteID)?.cancel()
        let modelID = sessions[noteID]?.modelID
        if let old = sessions[noteID], !old.messages.isEmpty { archives.append(old) }
        sessions[noteID] = NoteChatSession(noteID: noteID)
        sessions[noteID]?.modelID = modelID
        persist()
    }

    func dismiss(_ proposalID: UUID, noteID: UUID) {
        guard let i = sessions[noteID]?.messages.firstIndex(where: { $0.proposal?.id == proposalID }) else { return }
        sessions[noteID]?.messages[i].proposal?.state = .dismissed
        persist()
    }

    func apply(_ proposalID: UUID, noteID: UUID, only index: Int? = nil) {
        guard let app, let i = sessions[noteID]?.messages.firstIndex(where: { $0.proposal?.id == proposalID }),
              var proposal = sessions[noteID]?.messages[i].proposal, proposal.state == .pending,
              proposal.noteID == noteID, app.store.notes[noteID] != nil,
              let editor = app.activeEditor, editor.noteID == noteID, app.activeNoteID == noteID else {
            error = "Reopen the original note to apply this change."; return
        }
        if let index, !proposal.operations.indices.contains(index) {
            error = "That change is no longer in this suggestion."; return
        }
        do {
            guard !editor.hasMarkedText(), try NoteEdit.revision(editor.document) == proposal.revision else {
                throw AssistantError.message("The note changed since this suggestion. Ask for a fresh edit so your typing stays safe.")
            }
            let chosen = index.map { [proposal.operations[$0]] } ?? proposal.operations
            let document = try NoteEdit.applying(chosen, to: editor.document)
            let roundTrip = RichTextCodec.document(from: RichTextCodec.attributedString(from: document))
            guard roundTrip == document else {
                throw AssistantError.message("The assistant returned an invalid text edit. Ask it to try again.")
            }
            let version = try persistenceGuard(for: noteID)
            if let stored = proposal.diskRevision, stored != version.token {
                throw AssistantError.message("The note changed on disk. Reopen Notas to load that version before editing with chat.")
            }
            editor.applyAssistantDocument(document)
            guard editor.noteID == noteID, editor.document == document else {
                editor.undoManager?.undo()
                throw AssistantError.message("The assistant returned an invalid text edit. Ask it to try again.")
            }
            app.store.updateDocument(noteID, editor.document)
            if let index, proposal.operations.count > 1 {
                var rest = proposal.operations
                rest.remove(at: index)
                var before = proposal.before
                if before.indices.contains(index) { before.remove(at: index) }
                var locations = proposal.locations
                if var values = locations, values.indices.contains(index) {
                    values.remove(at: index)
                    locations = values
                }
                var formatting = proposal.removesFormatting
                if var values = formatting, values.indices.contains(index) {
                    values.remove(at: index)
                    formatting = values
                }
                let rebased = NoteEdit.rebase(rest, after: chosen)
                proposal.operations = rebased.map(\.operation)
                proposal.before = rebased.map { before.indices.contains($0.offset) ? before[$0.offset] : "" }
                proposal.locations = locations.map { values in rebased.map { values.indices.contains($0.offset) ? values[$0.offset] : "" } }
                proposal.removesFormatting = formatting.map { values in rebased.map { values.indices.contains($0.offset) ? values[$0.offset] : false } }
                app.store.flush()
                let liveRevision = try NoteEdit.revision(editor.document)
                let acceptedRevision = try NoteEdit.revision(document)
                guard editor.noteID == noteID, app.activeNoteID == noteID, app.activeEditor === editor,
                      liveRevision == acceptedRevision else {
                    throw AssistantError.message("The note changed since this suggestion. Ask for a fresh edit so your typing stays safe.")
                }
                proposal.revision = try NoteEdit.revision(editor.document)
                proposal.diskRevision = try persistenceGuard(for: noteID).token
                if proposal.operations.isEmpty { proposal.state = .applied }
            } else {
                proposal.state = .applied
            }
            sessions[noteID]?.messages[i].proposal = proposal
            persist()
        } catch { self.error = error.localizedDescription }
    }

    func skip(_ proposalID: UUID, index: Int, noteID: UUID) {
        guard var proposal = sessions[noteID]?.messages.first(where: { $0.proposal?.id == proposalID })?.proposal,
              proposal.state == .pending, proposal.operations.indices.contains(index),
              let i = sessions[noteID]?.messages.firstIndex(where: { $0.proposal?.id == proposalID }) else { return }
        proposal.operations.remove(at: index)
        if proposal.before.indices.contains(index) { proposal.before.remove(at: index) }
        if var locations = proposal.locations, locations.indices.contains(index) {
            locations.remove(at: index)
            proposal.locations = locations
        }
        if var formatting = proposal.removesFormatting, formatting.indices.contains(index) {
            formatting.remove(at: index)
            proposal.removesFormatting = formatting
        }
        if proposal.operations.isEmpty { proposal.state = .dismissed }
        sessions[noteID]?.messages[i].proposal = proposal
        persist()
    }

    func deleteNote(_ noteID: UUID) {
        stop(noteID)
        if let session = sessions.removeValue(forKey: noteID) { archives.append(session) }
        persist()
    }

    /// Writes history, or a separate recovery file when the original cannot be replaced.
    /// Returns a persistence error the app can use to keep running.
    @discardableResult
    func shutdown() -> String? {
        tasks.values.forEach { $0.cancel() }
        draftSaves.values.forEach { $0.cancel() }
        var reported: String?
        do { try saveNow() }
        catch {
            reported = "Chat history couldn't be saved. \(error.localizedDescription)"
            self.error = reported
        }
        io.sync {}
        return reported
    }

    /// Copies the rejected original aside and starts a new v1 file. Failure leaves the write barrier in place.
    func recoverHistory() throws {
        guard case .recoveryRequired(let issue) = historyAccess else { return }
        let original = try Data(contentsOf: stateURL)
        let backup = stateURL.deletingLastPathComponent().appendingPathComponent("sessions-backup-\(UUID().uuidString).json")
        try original.write(to: backup, options: .atomic)
        historyAccess = .writable
        historyDirty = true
        do { try saveNow() }
        catch {
            historyAccess = .recoveryRequired(issue)
            throw error
        }
    }

    private func present(_ preview: AssistantPreview, noteID: UUID, messageID: UUID) {
        guard let i = sessions[noteID]?.messages.firstIndex(where: { $0.id == messageID }) else { return }
        let thought = String(preview.thought.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        sessions[noteID]?.messages[i].thought = thought.isEmpty ? nil : thought
        sessions[noteID]?.messages[i].text = preview.text
    }

    private func dropPlaceholder(_ noteID: UUID) {
        guard let id = placeholders.removeValue(forKey: noteID) else { return }
        sessions[noteID]?.messages.removeAll { $0.id == id }
    }

    private func fail(_ noteID: UUID, _ message: String) {
        busyNotes.remove(noteID); tasks[noteID] = nil; snapshots[noteID] = nil
        sessions[noteID]?.awaitingReply = false
        dropPlaceholder(noteID)
        addNotice(message, to: noteID)
    }

    private func finish(_ noteID: UUID, completed: CompletedReply, model: ChatModel, messageID: UUID? = nil) {
        busyNotes.remove(noteID); tasks[noteID] = nil
        placeholders[noteID] = nil
        defer { snapshots[noteID] = nil; persist() }
        guard sessions[noteID]?.awaitingReply == true else { return }
        sessions[noteID]?.awaitingReply = false
        let reply = completed.reply
        do {
            var proposal: AssistantProposal?
            if !reply.operations.isEmpty, let revision = sessions[noteID]?.baseRevision {
                let live = app?.activeEditor.flatMap { $0.noteID == noteID ? $0.document : nil } ?? app?.store.notes[noteID]?.document
                guard let snapshot = snapshots[noteID] ?? live, try NoteEdit.revision(snapshot) == revision else {
                    throw AssistantError.message("The note changed. Ask for a fresh suggestion.")
                }
                _ = try NoteEdit.applying(reply.operations, to: snapshot)
                let operations = reply.operations.filter { $0.action != .replace || snapshot.blocks[$0.block].plainText != $0.text }
                if !operations.isEmpty {
                    let version = try persistenceGuard(for: noteID)
                    proposal = AssistantProposal(id: UUID(), noteID: noteID, revision: revision, operations: operations,
                                                 before: operations.map { snapshot.blocks[$0.block].plainText },
                                                 diskRevision: version.token,
                                                 locations: operations.map { NoteEditPreview.location(of: $0, in: snapshot) },
                                                 removesFormatting: operations.map { NoteEditPreview.removesFormatting($0, in: snapshot) })
                }
            }
            let message = NoteChatMessage(id: messageID ?? UUID(), role: .assistant, text: reply.reply,
                                          thought: completed.thought,
                                          proposal: proposal, modelID: model.rawValue)
            if let messageID, let index = sessions[noteID]?.messages.firstIndex(where: { $0.id == messageID }) {
                sessions[noteID]?.messages[index] = message
            } else {
                sessions[noteID]?.messages.append(message)
            }
        } catch {
            if let messageID { sessions[noteID]?.messages.removeAll { $0.id == messageID } }
            addNotice("The reply couldn't be read safely. No changes were applied. \(error.localizedDescription)", to: noteID)
        }
    }

    private func persistenceGuard(for noteID: UUID) throws -> DocumentVersion {
        guard let store = app?.store else {
            throw AssistantError.message("The note changed on disk. Reopen Notas to load that version before editing with chat.")
        }
        do {
            var version = try store.documentVersion(for: noteID)
            if version.isUnsaved {
                store.flush()
                version = try store.documentVersion(for: noteID)
            }
            return version
        } catch let error as AssistantError {
            throw error
        } catch {
            throw AssistantError.message("The note changed on disk. Reopen Notas to load that version before editing with chat.")
        }
    }

    private func addNotice(_ text: String, to noteID: UUID) {
        guard sessions[noteID] != nil else { return }
        sessions[noteID]?.messages.append(NoteChatMessage(role: .notice, text: text))
        persist()
    }

    private func encodedState() throws -> Data {
        try JSONEncoder().encode(Saved(version: 1, sessions: Array(sessions.values), archives: archives))
    }

    private var recoveryURL: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("sessions-recovery.json")
    }

    private func saveNow() throws {
        let url: URL
        switch historyAccess {
        case .writable:
            url = stateURL
        case .recoveryRequired:
            guard historyDirty else { return }
            url = recoveryURL
        }
        let data = try encodedState()
        try io.sync {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
        }
    }

    private func persist() {
        historyDirty = true
        do { try saveNow() }
        catch { self.error = "Chat history couldn't be saved. \(error.localizedDescription)" }
    }
}
