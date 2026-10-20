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
    var threadID: String?
    var turnID: String?
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
    private(set) var connected = false
    private(set) var connecting = false
    private(set) var signingIn = false
    private(set) var account: String?
    private(set) var modelAvailable = false
    private(set) var status = "Connect your ChatGPT account to chat about this note."
    var error: String?
    var binaryPath: String {
        didSet { app?.defaults.set(binaryPath, forKey: "codexExecutable") }
    }
    private var partition: UUID
    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private let connection: CodexConnection
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let io = DispatchQueue(label: "notas.assistant.persistence")
    @ObservationIgnored private var resumed: Set<String> = []
    @ObservationIgnored private var finalText: [String: String] = [:]
    @ObservationIgnored private var snapshots: [UUID: NoteDocument] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var deadlines: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var loginID: String?

    private struct Saved: Codable {
        let version: Int
        let partition: UUID
        let account: String?
        let sessions: [NoteChatSession]
        let archives: [NoteChatSession]
    }

    init(app: AppState, storageRoot: URL? = nil) {
        self.app = app
        binaryPath = app.defaults.string(forKey: "codexExecutable") ?? ""
        let library = app.store.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let identity = (try? NoteEdit.revision(NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: library)])]))) ?? UUID().uuidString
        let support = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notas/Assistant/\(identity)", isDirectory: true)
        stateURL = support.appendingPathComponent("sessions.json")
        connection = CodexConnection(home: support.appendingPathComponent("Codex", isDirectory: true))
        partition = UUID()
        if let data = try? Data(contentsOf: stateURL) {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: data)
                guard saved.version == 1 else { throw AssistantError.message("Chat history uses an unsupported version.") }
                partition = saved.partition; account = saved.account
                sessions = Dictionary(saved.sessions.map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
                archives = saved.archives
            } catch { self.error = "Chat history couldn't be loaded. The saved file has been kept. \(error.localizedDescription)" }
        }
        connection.onEvent = { [weak self] method, params in self?.receive(method, params) }
        connection.onDisconnect = { [weak self] reason in
            guard let self else { return }
            self.connected = false; self.connecting = false; self.modelAvailable = false
            self.signingIn = false; self.loginID = nil; self.resumed.removeAll()
            for id in self.busyNotes { self.addNotice(reason, to: id) }
            self.busyNotes.removeAll()
            self.deadlines.values.forEach { $0.cancel() }; self.deadlines.removeAll()
            self.status = reason
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
        persist()
    }

    func connect() async {
        guard !connecting else { return }
        connecting = true; error = nil
        defer { connecting = false }
        connection.executable = binaryPath.isEmpty ? nil : URL(fileURLWithPath: binaryPath)
        do {
            try await connection.start()
            connected = true
            try await refreshAccount()
        } catch { self.error = error.localizedDescription }
    }

    func reconnect() async {
        guard busyNotes.isEmpty else { return }
        connection.stop(reason: "Reconnecting to Codex…")
        await connect()
    }

    func signIn() async {
        if !connected { await connect() }
        guard connected, !signingIn else { return }
        error = nil
        do {
            // A new browser sign-in always gets a fresh conversation partition, even for the same email/workspace.
            stopAll()
            archivePartition()
            let result = try await connection.request("account/login/start", ["type": "chatgpt"])
            guard let address = result["authUrl"] as? String, let url = URL(string: address),
                  url.scheme == "https", let host = url.host,
                  host == "auth.openai.com" || host == "auth0.openai.com" || host == "chatgpt.com" else {
                throw AssistantError.message("Codex returned an unexpected sign-in URL.")
            }
            loginID = result["loginId"] as? String
            signingIn = true
            status = "Finish signing in with ChatGPT in your browser."
            NSWorkspace.shared.open(url)
        } catch { self.error = error.localizedDescription }
    }

    func cancelSignIn() async {
        if let loginID { _ = try? await connection.request("account/login/cancel", ["loginId": loginID]) }
        signingIn = false; loginID = nil
        status = "Sign-in cancelled."
    }

    func signOut() async {
        stopAll()
        do {
            _ = try await connection.request("account/logout", [:])
            archivePartition()
            account = nil; modelAvailable = false
            status = "Signed out of Notas chat."
            persist()
        } catch { self.error = error.localizedDescription }
    }

    private func refreshAccount() async throws {
        let result = try await connection.request("account/read", [:])
        guard let info = result["account"] as? [String: Any], info["type"] as? String == "chatgpt" else {
            account = nil; modelAvailable = false
            status = "Sign in with ChatGPT to use your subscription."
            return
        }
        let identity = (info["email"] as? String ?? "ChatGPT account") + " · " + (info["planType"] as? String ?? "ChatGPT")
        if let previous = account, previous != identity { archivePartition() }
        account = identity
        modelAvailable = false
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try await connection.request("model/list", params)
            for model in result["data"] as? [[String: Any]] ?? [] where model["model"] as? String == CodexConnection.model {
                let efforts = model["supportedReasoningEfforts"] as? [[String: Any]] ?? []
                modelAvailable = efforts.contains { $0["reasoningEffort"] as? String == "medium" }
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil && !modelAvailable
        status = modelAvailable ? "Sol · medium reasoning" : "Sol medium isn't available. Check your ChatGPT plan and Codex version."
        persist()
    }

    func send(_ noteID: UUID) {
        guard connected, account != nil, modelAvailable, !busyNotes.contains(noteID), let app else { return }
        ensureSession(noteID)
        guard sessions[noteID]?.awaitingReply == false else {
            error = "Recover the previous response before sending another message."; return
        }
        guard let editor = app.activeEditor, app.activeNoteID == noteID, editor.noteID == noteID, !editor.hasMarkedText() else {
            error = "Open this note and finish typing before sending."; return
        }
        let prompt = sessions[noteID]?.draft.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { return }
        do {
            let document = editor.document
            snapshots[noteID] = document
            let context = try NoteEdit.context(document)
            let revision = try NoteEdit.revision(document)
            let user = NoteChatMessage(role: .user, text: prompt)
            if document.isEmpty { app.store.mutate(noteID, touch: false) { $0.retainsEmptyDocument = true } }
            sessions[noteID]?.messages.append(user)
            sessions[noteID]?.draft = ""
            sessions[noteID]?.baseRevision = revision
            sessions[noteID]?.diskRevision = diskRevision(noteID)
            sessions[noteID]?.awaitingReply = true
            sessions[noteID]?.turnID = nil
            try saveNow()
            busyNotes.insert(noteID)
            let conversation = sessions[noteID]!.id
            tasks[noteID] = Task { [weak self] in
                guard let self else { return }
                do {
                    let thread = try await self.prepareThread(noteID)
                    guard self.sessions[noteID]?.id == conversation, !Task.isCancelled else { return }
                    let applied = self.sessions[noteID]?.messages.compactMap { message -> String? in
                        guard let proposal = message.proposal else { return nil }
                        return "Proposal \(proposal.id): \(proposal.state.rawValue)"
                    }.suffix(10).joined(separator: "\n") ?? ""
                    let result = try await self.connection.request("turn/start", [
                        "threadId": thread, "model": CodexConnection.model, "effort": "medium", "permissions": "notas",
                        "approvalPolicy": "never", "clientUserMessageId": user.id.uuidString,
                        "outputSchema": AssistantReply.schema,
                        "input": [["type": "text", "text": "Current note snapshot:\n\(context)\nRecent proposal decisions:\n\(applied)\nUser request:\n\(prompt)"]]
                    ])
                    if let turn = result["turn"] as? [String: Any], let turnID = turn["id"] as? String,
                       self.sessions[noteID]?.awaitingReply == true {
                        self.sessions[noteID]?.turnID = turnID
                    }
                    self.persist()
                    if self.busyNotes.contains(noteID) { self.startDeadline(noteID) }
                } catch {
                    self.busyNotes.remove(noteID)
                    self.addNotice(error.localizedDescription, to: noteID)
                    self.persist()
                }
                self.tasks[noteID] = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    private func prepareThread(_ noteID: UUID) async throws -> String {
        var params: [String: Any] = ["model": CodexConnection.model, "permissions": "notas", "approvalPolicy": "never",
                                     "cwd": connection.scratch.path, "baseInstructions": NoteEdit.instructions]
        if let thread = sessions[noteID]?.threadID {
            if !resumed.contains(thread) {
                params["threadId"] = thread
                _ = try await connection.request("thread/resume", params)
                resumed.insert(thread)
            }
            return thread
        }
        let result = try await connection.request("thread/start", params)
        guard let thread = (result["thread"] as? [String: Any])?["id"] as? String else {
            throw AssistantError.message("Codex didn't create a conversation.")
        }
        sessions[noteID]?.threadID = thread
        resumed.insert(thread)
        try saveNow()
        return thread
    }

    func recover(_ noteID: UUID) async {
        guard connected, !busyNotes.contains(noteID) else { return }
        busyNotes.insert(noteID)
        defer { busyNotes.remove(noteID); persist() }
        do {
            guard sessions[noteID]?.threadID != nil else {
                sessions[noteID]?.awaitingReply = false
                addNotice("The request didn't reach a saved conversation. You can send a new message.", to: noteID)
                return
            }
            let thread = try await prepareThread(noteID)
            let result = try await connection.request("thread/turns/list", ["threadId": thread, "limit": 1, "sortDirection": "desc", "itemsView": "full"])
            guard let turn = (result["data"] as? [[String: Any]])?.first else {
                sessions[noteID]?.awaitingReply = false
                addNotice("No response was saved. Your message wasn't sent again.", to: noteID)
                return
            }
            if turn["status"] as? String == "inProgress" {
                if let id = turn["id"] as? String { _ = try await connection.request("turn/interrupt", ["threadId": thread, "turnId": id]) }
                throw AssistantError.message("The previous request was still running. It was stopped. Recover once more to read its saved result.")
            }
            let ownIDs = Set((sessions[noteID]?.messages ?? []).filter { $0.role == .user }.map { $0.id.uuidString })
            let items = turn["items"] as? [[String: Any]] ?? []
            let matches = turn["id"] as? String == sessions[noteID]?.turnID || items.contains {
                $0["type"] as? String == "userMessage" && ownIDs.contains($0["clientId"] as? String ?? "")
            }
            if matches, sessions[noteID]?.awaitingReply == true {
                finish(noteID, turn: turn, items: items)
            } else {
                sessions[noteID]?.awaitingReply = false
                addNotice("History reconciled. Your interrupted message wasn't automatically sent again.", to: noteID)
            }
        } catch { self.error = "Recovery failed. \(error.localizedDescription) Start a new conversation if the saved thread is unavailable." }
    }

    func stop(_ noteID: UUID) {
        tasks[noteID]?.cancel()
        guard let thread = sessions[noteID]?.threadID else {
            busyNotes.remove(noteID); return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                // A delayed turn/start acknowledgement must be reconciled, never replayed.
                if let turn = self.sessions[noteID]?.turnID {
                    _ = try await self.connection.request("turn/interrupt", ["threadId": thread, "turnId": turn])
                } else {
                    self.connection.stop(reason: "Stopped before Codex acknowledged the request. Recover before sending again.")
                }
            } catch { self.error = error.localizedDescription }
        }
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
        if busyNotes.contains(noteID) { stop(noteID) }
        if let session = sessions.removeValue(forKey: noteID) { archives.append(session) }
        persist()
    }

    func shutdown() {
        tasks.values.forEach { $0.cancel() }
        deadlines.values.forEach { $0.cancel() }
        persist()
        io.sync {}
        connection.stop()
    }

    private func receive(_ method: String, _ params: [String: Any]) {
        if method == "account/login/completed" {
            signingIn = false; loginID = nil
            if params["success"] as? Bool == true { Task { do { try await refreshAccount() } catch { self.error = error.localizedDescription } } }
            else { error = params["error"] as? String ?? "ChatGPT sign-in didn't complete." }
            return
        }
        if method == "account/updated" {
            if params["authMode"] is NSNull { stopAll(); account = nil; modelAvailable = false; persist() }
            return
        }
        guard let thread = params["threadId"] as? String,
              let noteID = sessions.first(where: { $0.value.threadID == thread })?.key else { return }
        if method == "turn/started", let turn = params["turn"] as? [String: Any] {
            sessions[noteID]?.turnID = turn["id"] as? String
            persist()
        } else if method == "item/completed", let item = params["item"] as? [String: Any],
                  item["type"] as? String == "agentMessage", let text = item["text"] as? String {
            if let id = item["id"] as? String { finalText[id] = text }
            if let turn = params["turnId"] as? String { finalText[thread + "/" + turn] = text }
        } else if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
            let items = turn["items"] as? [[String: Any]] ?? []
            finish(noteID, turn: turn, items: items)
            busyNotes.remove(noteID)
            deadlines.removeValue(forKey: noteID)?.cancel()
            persist()
        } else if method == "error", params["willRetry"] as? Bool != true {
            error = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex couldn't complete this request."
        } else if method == "notas/blockedTool" {
            stop(noteID)
            addNotice("Codex requested a tool outside this note's permissions. The request was blocked.", to: noteID)
        }
    }

    private func finish(_ noteID: UUID, turn: [String: Any], items: [[String: Any]]) {
        guard sessions[noteID]?.awaitingReply == true else { return }
        sessions[noteID]?.awaitingReply = false
        let state = turn["status"] as? String ?? "failed"
        guard state == "completed" else {
            let detail = (turn["error"] as? [String: Any])?["message"] as? String
            addNotice(detail ?? (state == "interrupted" ? "Stopped. No changes were applied." : "Codex couldn't finish this reply. No changes were applied."), to: noteID)
            return
        }
        let agents = items.filter { $0["type"] as? String == "agentMessage" }
        let key = (sessions[noteID]?.threadID ?? "") + "/" + (turn["id"] as? String ?? "")
        let text = agents.last?["text"] as? String ?? agents.last.flatMap { $0["id"] as? String }.flatMap { finalText[$0] } ?? finalText[key]
        do {
            guard let text, text.utf8.count <= 250_000 else { throw AssistantError.message("Codex didn't return a complete response.") }
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
        for item in agents { if let id = item["id"] as? String { finalText[id] = nil } }
        finalText[key] = nil
        snapshots[noteID] = nil
    }

    private func startDeadline(_ noteID: UUID) {
        deadlines[noteID]?.cancel()
        deadlines[noteID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            self?.stop(noteID)
            self?.addNotice("This response took too long and was stopped. Recover it before sending again.", to: noteID)
        }
    }

    private func stopAll() {
        for id in busyNotes { stop(id) }
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        busyNotes.removeAll()
    }

    private func archivePartition() {
        archives += sessions.values.filter { !$0.messages.isEmpty }
        sessions.removeAll(); resumed.removeAll(); finalText.removeAll()
        partition = UUID()
        persist()
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
        try JSONEncoder().encode(Saved(version: 1, partition: partition, account: account,
                                       sessions: Array(sessions.values), archives: archives))
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
