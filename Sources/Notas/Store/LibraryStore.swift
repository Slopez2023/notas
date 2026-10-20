import CryptoKit
import Foundation
import Observation

/// Something the library could not do on its own and the user may need to see.
/// Issues describe state that is still held in memory or on disk; none of them means data was dropped.
struct LibraryIssue: Identifiable, Equatable {
    enum Kind: String, Equatable {
        /// The latest edit of a note has not reached its package.
        case writeFailed
        /// Disk and memory both changed the same note. Both complete versions are listed.
        case conflict
        /// Several packages decode to one note ID. Every package is listed.
        case duplicateID
        /// A package lives under a name that is not its decoded ID. It stays editable in place.
        case locationMismatch
        case unreadableNote
        case notebooksUnreadable
        case notebookWriteFailed
        case trashFailed
        /// A local copy of edits that never reached the library, left by an earlier run.
        case recoveredEdit
    }

    struct Version: Identifiable, Equatable {
        let id: UUID
        let title: String
        /// A package the user can open in Finder. Complete with its assets.
        let package: URL
        let note: Note?
    }

    let id: UUID
    let kind: Kind
    let noteID: UUID?
    let message: String
    var versions: [Version] = []
}

/// Thrown when a flush could not write everything. The retained values stay in memory.
struct PersistenceFailure: LocalizedError {
    struct Entry: Equatable {
        /// nil for notebook metadata.
        let noteID: UUID?
        let message: String
        /// A separate local copy of the latest value exists, so quitting would not lose it.
        let recovered: Bool
    }
    let entries: [Entry]

    /// True when quitting now would lose an edit: neither the library nor a recovery copy holds it.
    var hasUnrecoveredEdits: Bool { entries.contains { !$0.recovered } }

    var errorDescription: String? {
        let first = entries.first?.message ?? "Unknown error"
        return entries.count > 1 ? "\(first) (and \(entries.count - 1) more)" : first
    }
}

enum LibraryError: LocalizedError {
    case noteNotFound(UUID)
    case blocked(String)
    case issueNotFound
    case notebooksUnavailable
    case stagingBlocked(URL)
    case destinationConflict(UUID)

    var errorDescription: String? {
        switch self {
        case .noteNotFound: "That note is not in the library."
        case .blocked(let reason): reason
        case .issueNotFound: "That problem has already been resolved."
        case .notebooksUnavailable: "The notebook list needs recovery first, so notes cannot be placed in a notebook."
        case .stagingBlocked(let url): "A previous import left files that could not be removed: \(url.path)"
        case .destinationConflict: "A different note already uses this import's location."
        }
    }
}

/// Owns every notebook and note, and keeps them in sync with files on disk.
///
/// Layout (inside the library folder, by default `iCloud Drive/Notas`):
///   notebooks.json
///   Notes/<uuid>.notas/note.json
///   Trash/<uuid>.notas/note.json
///
/// Edits are acknowledged, not assumed: a value stays dirty until a write of exactly that
/// generation (or a later one) succeeded, and a failed write keeps the value in memory with a
/// visible issue. `notes` always holds the newest local value.
@MainActor
@Observable
final class LibraryStore {
    private(set) var notebooks: [Notebook] = []
    private(set) var notes: [UUID: Note] = [:]
    private(set) var issues: [LibraryIssue] = []
    let rootURL: URL
    let recoveryRoot: URL
    @ObservationIgnored var onLibraryChange: (() -> Void)?

    /// Everything the store remembers about one note beyond its current value.
    private struct NoteRecord {
        /// Where the package actually lives. Loading records it, so nothing reconstructs a path from the ID.
        var package: URL
        /// The last value known to be on disk, and the exact bytes it came from. nil for a note never written.
        var base: Note?
        var revision: FileRevision?
        /// Bumped by every local edit. A write acknowledges the generation it sent.
        var generation: UInt64 = 0
        var acknowledged: UInt64 = 0
        var failure: WriteFailure?
        var conflict: ConflictRecord?
        /// Local recovery packages written for this note and not yet superseded by a canonical write.
        var recoveries: [URL] = []
        var deleting = false
        var isDirty: Bool { generation > acknowledged }
    }
    private struct WriteFailure {
        let message: String
        let generation: UInt64
        let recovered: Bool
    }
    private struct ConflictRecord {
        let id: UUID
        /// The version on disk. It stays where it is until the user resolves the conflict.
        var remote: Note
        var remoteRevision: FileRevision
        var localRecovery: URL?
    }
    private struct DuplicateGroup {
        let id: UUID
        let noteID: UUID
        let versions: [(package: URL, note: Note)]
    }
    private struct NotebookState {
        var recovery: String?
        var generation: UInt64 = 0
        var acknowledged: UInt64 = 0
        var failure: WriteFailure?
        var isDirty: Bool { generation > acknowledged }
    }

    @ObservationIgnored private var records: [UUID: NoteRecord] = [:]
    @ObservationIgnored private var duplicates: [UUID: DuplicateGroup] = [:]
    @ObservationIgnored private var trashFailures: [UUID: String] = [:]
    @ObservationIgnored private var loadIssues: [LibraryIssue] = []
    @ObservationIgnored private var notebookState = NotebookState()
    /// Debounce timers only schedule a write. The records above are what remembers an edit.
    @ObservationIgnored private var debounce: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var writing: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var notebookWriting: Task<Void, Never>?
    /// Lowercased title and body per note, so a search doesn't rebuild them for every note on
    /// every keystroke. Dropped whenever a note's content may have changed.
    @ObservationIgnored private var searchIndex: [UUID: SearchEntry] = [:]
    private struct SearchEntry {
        let title: String
        let lowerBody: String
    }
    @ObservationIgnored private let io = DispatchQueue(label: "notas.library.io", qos: .utility)
    @ObservationIgnored private let ledger = DiskLedger()

    init(rootURL: URL = LibraryStore.defaultRoot(), recoveryRoot: URL? = nil) {
        self.rootURL = rootURL
        self.recoveryRoot = recoveryRoot ?? Self.defaultRecoveryRoot(for: rootURL)
    }

    nonisolated static func defaultRoot() -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["NOTAS_LIBRARY"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let iCloudDrive = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloudDrive.path) {
            return iCloudDrive.appendingPathComponent("Notas", isDirectory: true)
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Notas", isDirectory: true)
    }

    /// Recovery copies live outside the library so they survive whatever blocked the library.
    /// A library at a custom location keeps them beside it, so tests and scratch libraries never
    /// write into the real Application Support folder.
    nonisolated static func defaultRecoveryRoot(for root: URL) -> URL {
        if root.standardizedFileURL == defaultRoot().standardizedFileURL {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return support.appendingPathComponent("Notas", isDirectory: true).appendingPathComponent("Recovery", isDirectory: true)
        }
        return root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent)-recovery", isDirectory: true)
    }

    private var notesURL: URL { rootURL.appendingPathComponent("Notes", isDirectory: true) }
    private var trashURL: URL { rootURL.appendingPathComponent("Trash", isDirectory: true) }
    private var notebooksURL: URL { rootURL.appendingPathComponent("notebooks.json") }
    /// One folder per library, so two libraries never share a recovery package.
    private var recoveryDirectory: URL {
        let key = SHA256.hash(data: Data(rootURL.standardizedFileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return recoveryRoot.appendingPathComponent(key, isDirectory: true)
    }

    private func packageURL(for id: UUID, in folder: URL? = nil) -> URL {
        (folder ?? notesURL).appendingPathComponent("\(id.uuidString).notas", isDirectory: true)
    }

    private func recoveryPackage(for id: UUID, generation: UInt64) -> URL {
        recoveryDirectory.appendingPathComponent("\(id.uuidString)-\(generation).notas", isDirectory: true)
    }

    /// Assets live in the package the note was loaded from, wherever that is.
    func assets(for id: UUID) -> NoteAssets { NoteAssets(package: records[id]?.package ?? packageURL(for: id)) }

    // MARK: Loading

    func load() {
        let fm = FileManager.default
        debounce.values.forEach { $0.cancel() }
        debounce = [:]
        io.sync { ledger.removeAll() }

        // Decide whether this is a new library before creating any folder in it.
        var problems: [LibraryIssue] = []
        var populated = false
        var packages: [URL] = []
        switch StoreDisk.list(notesURL) {
        case .missing: break
        case .entries(let urls):
            packages = urls.filter { $0.pathExtension == "notas" }
            populated = !packages.isEmpty
        case .failed(let message):
            populated = true
            problems.append(LibraryIssue(id: derivedUUID("notes-folder"), kind: .unreadableNote, noteID: nil,
                                         message: "The Notes folder could not be read: \(message)"))
        }
        switch StoreDisk.list(trashURL) {
        case .entries(let urls) where urls.contains(where: { $0.pathExtension == "notas" }): populated = true
        case .failed: populated = true
        default: break
        }
        let metadata = StoreDisk.readNotebooks(at: notebooksURL)
        try? fm.createDirectory(at: notesURL, withIntermediateDirectories: true)

        records = [:]
        notes = [:]
        duplicates = [:]
        trashFailures = [:]
        searchIndex.removeAll()
        var loaded: [UUID: [(package: URL, note: Note, revision: FileRevision)]] = [:]
        for read in StoreDisk.readNotes(in: packages) {
            switch read.outcome {
            case .note(let note, let revision):
                loaded[note.id, default: []].append((read.url, note, revision))
            case .failure(let message):
                problems.append(LibraryIssue(id: derivedUUID("unreadable:" + read.url.lastPathComponent), kind: .unreadableNote, noteID: nil,
                                             message: "\(read.url.lastPathComponent) could not be read: \(message)",
                                             versions: [.init(id: derivedUUID("version:" + read.url.lastPathComponent),
                                                              title: read.url.lastPathComponent, package: read.url, note: nil)]))
            }
        }
        for (id, group) in loaded {
            if group.count == 1, let only = group.first {
                notes[id] = only.note
                records[id] = NoteRecord(package: only.package, base: only.note, revision: only.revision)
                if only.package.deletingPathExtension().lastPathComponent.uppercased() != id.uuidString {
                    problems.append(LibraryIssue(id: derivedUUID("location:" + only.package.lastPathComponent), kind: .locationMismatch, noteID: id,
                                                 message: "\(only.package.lastPathComponent) holds note \(id.uuidString). It is used where it is."))
                }
            } else {
                // Never pick one by enumeration order: every copy is kept and listed until the user decides.
                let versions = group.sorted { $0.package.lastPathComponent < $1.package.lastPathComponent }.map { ($0.package, $0.note) }
                duplicates[id] = DuplicateGroup(id: derivedUUID("duplicate:" + id.uuidString), noteID: id, versions: versions)
            }
        }

        notebookState = NotebookState()
        var seed = false
        switch metadata {
        case .notebooks(let list) where !list.isEmpty:
            notebooks = list.sorted { $0.order < $1.order }
        case .notebooks, .missing:
            notebooks = []
            if populated {
                notebookState.recovery = "The notebook list is missing or empty, but this library already has notes. It was not recreated."
            } else {
                seed = true
            }
        case .invalid(let message):
            notebooks = []
            notebookState.recovery = message
        }
        if seed { seedFirstRun() }

        loadIssues = problems + discoverRecoveries()
        refreshIssues()
    }

    private func seedFirstRun() {
        let personal = Notebook(id: UUID(), name: "Personal", color: .coral, order: 0)
        let ideas = Notebook(id: UUID(), name: "Ideas", color: .sun, order: 1)
        let lists = Notebook(id: UUID(), name: "Lists", color: .mint, order: 2)
        notebooks = [personal, ideas, lists]
        markNotebooksDirty()

        if notes.isEmpty && duplicates.isEmpty {
            var welcome = Note.new(in: personal.id)
            welcome.pinned = true
            welcome.tags = ["start-here"]
            welcome.document = WelcomeNote.document
            notes[welcome.id] = welcome
            records[welcome.id] = NoteRecord(package: packageURL(for: welcome.id))
            markDirty(welcome.id, immediate: true)
        }
    }

    /// Recovery copies from earlier runs, so edits that never reached the library are not forgotten.
    private func discoverRecoveries() -> [LibraryIssue] {
        guard case .entries(let urls) = StoreDisk.list(recoveryDirectory) else { return [] }
        return urls.filter { $0.pathExtension == "notas" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("note.json")),
                  let note = try? Self.decoder.decode(Note.self, from: data) else { return nil }
            return LibraryIssue(id: derivedUUID("recovered:" + url.path), kind: .recoveredEdit, noteID: note.id,
                                message: "Unsaved edits to “\(note.displayTitle)” were kept in \(url.path).",
                                versions: [.init(id: derivedUUID("version:" + url.path), title: note.displayTitle, package: url, note: note)])
        }
    }

    // MARK: Issues

    private func refreshIssues() {
        var list = loadIssues
        for (id, record) in records {
            if let failure = record.failure, record.isDirty {
                list.append(LibraryIssue(id: id, kind: .writeFailed, noteID: id,
                                         message: "“\(notes[id]?.displayTitle ?? "A note")” has changes that could not be saved: \(failure.message)"
                                            + (failure.recovered ? " A separate copy was kept on this Mac." : " No separate copy could be made.")))
            }
            if let conflict = record.conflict {
                var versions = [LibraryIssue.Version(id: derivedUUID("remote:" + conflict.id.uuidString), title: conflict.remote.displayTitle,
                                                     package: record.package, note: conflict.remote)]
                if let local = notes[id] {
                    versions.append(.init(id: derivedUUID("local:" + conflict.id.uuidString), title: local.displayTitle,
                                          package: conflict.localRecovery ?? record.package, note: local))
                }
                list.append(LibraryIssue(id: conflict.id, kind: .conflict, noteID: id,
                                         message: "“\(conflict.remote.displayTitle)” was changed on disk and here. Both versions are kept.", versions: versions))
            }
        }
        for (id, message) in trashFailures {
            list.append(LibraryIssue(id: derivedUUID("trash:" + id.uuidString), kind: .trashFailed, noteID: id,
                                     message: "“\(notes[id]?.displayTitle ?? "A note")” could not be moved to the Trash: \(message)"))
        }
        for group in duplicates.values {
            let versions = group.versions.map {
                LibraryIssue.Version(id: derivedUUID("version:" + $0.package.lastPathComponent), title: $0.note.displayTitle, package: $0.package, note: $0.note)
            }
            list.append(LibraryIssue(id: group.id, kind: .duplicateID, noteID: group.noteID,
                                     message: "\(group.versions.count) packages claim the same note. All are kept until you choose Keep Both.", versions: versions))
        }
        if let recovery = notebookState.recovery {
            list.append(LibraryIssue(id: derivedUUID("notebooks-unreadable"), kind: .notebooksUnreadable, noteID: nil,
                                     message: "Notebooks need recovery: \(recovery) notebooks.json was left exactly as it was."))
        }
        if let failure = notebookState.failure, notebookState.isDirty {
            list.append(LibraryIssue(id: derivedUUID("notebooks-write"), kind: .notebookWriteFailed, noteID: nil,
                                     message: "Notebook changes could not be saved: \(failure.message)"))
        }
        issues = list.sorted { ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString) }
    }

    /// Notebook IDs that notes refer to but the notebook list does not define. Shown, never rewritten.
    var unassignedNotebookIDs: [UUID] {
        let known = Set(notebooks.map(\.id))
        return Set(notes.values.map(\.notebookID)).subtracting(known).sorted { $0.uuidString < $1.uuidString }
    }

    var notebooksNeedRecovery: Bool { notebookState.recovery != nil }

    func hasUnsavedChanges(_ id: UUID) -> Bool { records[id]?.isDirty ?? false }

    var hasUnsavedNotebookChanges: Bool { notebookState.isDirty && notebooksWritable }

    var hasWriteInFlight: Bool { !writing.isEmpty || notebookWriting != nil }

    // MARK: Queries

    var sortedNotebooks: [Notebook] { notebooks.sorted { $0.order < $1.order } }

    func notebook(_ id: UUID) -> Notebook? { notebooks.first { $0.id == id } }

    func notes(in notebookID: UUID?) -> [Note] {
        notes.values
            .filter { notebookID == nil || $0.notebookID == notebookID }
            .sorted(by: Self.listOrder)
    }

    var pinnedNotes: [Note] { notes.values.filter(\.pinned).sorted(by: Self.listOrder) }

    func notes(taggedWith tag: String) -> [Note] {
        notes.values.filter { $0.tags.contains(tag) }.sorted(by: Self.listOrder)
    }

    var allTags: [String] {
        Array(Set(notes.values.flatMap(\.tags))).sorted()
    }

    func count(in notebookID: UUID) -> Int {
        notes.values.reduce(0) { $0 + ($1.notebookID == notebookID ? 1 : 0) }
    }

    private static func listOrder(_ a: Note, _ b: Note) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return a.modified > b.modified
    }

    // MARK: Notes

    /// The notebook a note lands in when the caller names none. While the notebook list needs recovery
    /// this is a notebook the existing notes already point at; an ID is never invented to get around it.
    private var defaultNotebookID: UUID? { notebooks.first?.id ?? unassignedNotebookIDs.first }

    @discardableResult
    func createNote(in notebookID: UUID?, style: NoteStyle = NoteStyle()) -> Note {
        let target = notebookID ?? defaultNotebookID ?? UUID()
        var note = Note.new(in: target)
        note.style = style
        notes[note.id] = note
        records[note.id] = NoteRecord(package: packageURL(for: note.id))
        markDirty(note.id)
        return note
    }

    /// Replace a note's content. Saves after a short pause so typing stays smooth.
    func updateDocument(_ id: UUID, _ document: NoteDocument) {
        guard var note = notes[id], records[id]?.deleting != true, note.document != document else { return }
        searchIndex[id] = nil
        note.document = document
        note.modified = Date()
        notes[id] = note
        markDirty(id)
    }

    func mutate(_ id: UUID, touch: Bool = true, _ change: (inout Note) -> Void) {
        guard var note = notes[id], records[id]?.deleting != true else { return }
        searchIndex[id] = nil
        change(&note)
        if touch { note.modified = Date() }
        notes[id] = note
        markDirty(id)
    }

    func togglePin(_ id: UUID) { mutate(id, touch: false) { $0.pinned.toggle() } }

    func move(_ id: UUID, to notebookID: UUID) {
        guard !notebooksNeedRecovery || unassignedNotebookIDs.contains(notebookID) else { return }
        mutate(id, touch: false) { $0.notebookID = notebookID }
    }

    func addTag(_ tag: String, to id: UUID) {
        let clean = Self.normalizeTag(tag)
        guard !clean.isEmpty else { return }
        mutate(id, touch: false) { if !$0.tags.contains(clean) { $0.tags.append(clean) } }
    }

    func removeTag(_ tag: String, from id: UUID) {
        mutate(id, touch: false) { $0.tags.removeAll { $0 == tag } }
    }

    static func normalizeTag(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Moves the note's package to the library's Trash folder (recoverable from Finder).
    /// The latest value is written first, and the note leaves the library only once the move succeeded.
    /// On any failure the note stays, editable, with an issue explaining why.
    func trash(_ id: UUID) async throws {
        try beginTrash(id)
        do {
            await persist(id, force: true)
            let package = try finishableTrashSource(id)
            let (trashURL, ledger) = (self.trashURL, self.ledger)
            _ = try await StoreDisk.runIO(on: io) { Result { try StoreDisk.moveToTrash(package, id: id, trash: trashURL, ledger: ledger) } }.get()
            forget(id)
        } catch {
            endTrash(id, failure: error)
            throw error
        }
    }

    /// Blocking variant for callers that cannot await. Same rules; failures are reported through `issues`.
    func trash(_ id: UUID) {
        guard (try? beginTrash(id)) != nil else { return }
        do {
            if let job = makeJob(id), records[id]?.isDirty == true {
                let ledger = self.ledger
                apply(io.sync { StoreDisk.perform(job, ledger: ledger) }, for: job)
            }
            let package = try finishableTrashSource(id)
            _ = try io.sync { try StoreDisk.moveToTrash(package, id: id, trash: trashURL, ledger: ledger) }
            forget(id)
        } catch {
            endTrash(id, failure: error)
        }
    }

    private func beginTrash(_ id: UUID) throws {
        guard notes[id] != nil, let record = records[id] else {
            if duplicates[id] != nil { throw LibraryError.blocked("Several packages share this note's ID. Choose Keep Both before deleting.") }
            throw LibraryError.noteNotFound(id)
        }
        guard !record.deleting else { throw LibraryError.blocked("This note is already being deleted.") }
        guard record.conflict == nil else { throw LibraryError.blocked("This note has an unresolved conflict. Choose Keep Both before deleting.") }
        records[id]?.deleting = true
        debounce[id]?.cancel()
        debounce[id] = nil
        trashFailures[id] = nil
    }

    /// The package to move, once the latest value is known to be in it.
    private func finishableTrashSource(_ id: UUID) throws -> URL {
        guard let record = records[id] else { throw LibraryError.noteNotFound(id) }
        if record.isDirty {
            let reason = record.failure?.message ?? (record.conflict != nil ? "the note changed on disk" : "the latest edit could not be written")
            throw LibraryError.blocked("The latest version could not be saved before moving it: \(reason)")
        }
        return record.package
    }

    private func endTrash(_ id: UUID, failure: Error) {
        records[id]?.deleting = false
        trashFailures[id] = failure.localizedDescription
        refreshIssues()
    }

    private func forget(_ id: UUID) {
        debounce[id]?.cancel()
        debounce[id] = nil
        if let stale = records[id]?.recoveries, !stale.isEmpty { io.async { stale.forEach { try? FileManager.default.removeItem(at: $0) } } }
        records[id] = nil
        notes[id] = nil
        searchIndex[id] = nil
        trashFailures[id] = nil
        refreshIssues()
        onLibraryChange?()
    }

    /// Drops a note that was created but never written in. Keeps the library free of blank notes.
    func discardIfEmpty(_ id: UUID) {
        guard let note = notes[id], note.document.isEmpty,
              note.tags.isEmpty, note.retainsEmptyDocument != true else { return }
        // Nothing was ever written for it, so there is nothing to recover.
        if let record = records[id], record.base == nil, writing[id] == nil { forget(id); return }
        trash(id)
    }

    // MARK: Notebooks

    /// Notebook changes wait for recovery: the list on disk is not understood, so nothing may replace it.
    private var notebooksWritable: Bool { notebookState.recovery == nil }

    @discardableResult
    func createNotebook(name: String, color: NotebookColor? = nil) -> Notebook {
        let used = Set(notebooks.map(\.color))
        let pick = color ?? NotebookColor.allCases.first { !used.contains($0) } ?? .slate
        let notebook = Notebook(id: UUID(), name: name, color: pick, order: (notebooks.map(\.order).max() ?? -1) + 1)
        // While recovery is pending the notebook is returned but not stored; callers see the issue.
        guard notebooksWritable else { return notebook }
        notebooks.append(notebook)
        markNotebooksDirty()
        return notebook
    }

    func renameNotebook(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard notebooksWritable, !trimmed.isEmpty, let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].name = trimmed
        markNotebooksDirty()
    }

    func recolorNotebook(_ id: UUID, to color: NotebookColor) {
        guard notebooksWritable, let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].color = color
        markNotebooksDirty()
    }

    /// Deletes a notebook and moves its notes into the first remaining notebook.
    func deleteNotebook(_ id: UUID) {
        guard notebooksWritable, notebooks.count > 1, let fallback = sortedNotebooks.first(where: { $0.id != id }) else { return }
        notebooks.removeAll { $0.id == id }
        for note in notes.values where note.notebookID == id {
            move(note.id, to: fallback.id)
        }
        markNotebooksDirty()
    }

    func moveNotebook(_ id: UUID, by offset: Int) {
        guard notebooksWritable else { return }
        var ordered = sortedNotebooks
        guard let i = ordered.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(ordered.count - 1, i + offset))
        guard i != j else { return }
        ordered.swapAt(i, j)
        for (n, nb) in ordered.enumerated() {
            if let k = notebooks.firstIndex(where: { $0.id == nb.id }) { notebooks[k].order = n }
        }
        markNotebooksDirty()
    }

    // MARK: Search

    struct SearchHit: Identifiable {
        let note: Note
        let score: Int
        let snippet: String?
        var id: UUID { note.id }
    }

    func search(_ query: String, limit: Int = 30) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            return notes.values.sorted { $0.modified > $1.modified }.prefix(limit)
                .map { SearchHit(note: $0, score: 0, snippet: nil) }
        }
        let terms = q.split(separator: " ").map(String.init)
        var ranked: [(note: Note, score: Int)] = []
        for note in notes.values {
            let entry = searchEntry(for: note)
            var score = 0
            var matchedAll = true
            for term in terms {
                if entry.title.hasPrefix(term) { score += 100 }
                else if entry.title.contains(term) { score += 60 }
                else if note.tags.contains(where: { $0.hasPrefix(term) }) { score += 40 }
                else if entry.lowerBody.contains(term) { score += 10 }
                else { matchedAll = false; break }
            }
            guard matchedAll else { continue }
            ranked.append((note, score + (note.pinned ? 5 : 0)))
        }
        ranked.sort { ($0.score, $0.note.modified) > ($1.score, $1.note.modified) }
        // Snippets are only worth building for the rows that get shown.
        return ranked.prefix(limit).map { hit in
            SearchHit(note: hit.note, score: hit.score, snippet: Self.snippet(in: hit.note.document.bodyText, around: terms[0]))
        }
    }

    private func searchEntry(for note: Note) -> SearchEntry {
        if let cached = searchIndex[note.id] { return cached }
        let entry = SearchEntry(title: note.title.lowercased(), lowerBody: note.document.bodyText.lowercased())
        searchIndex[note.id] = entry
        return entry
    }

    private static func snippet(in text: String, around term: String) -> String? {
        guard let r = text.range(of: term, options: .caseInsensitive) else { return nil }
        let start = text.index(r.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        let piece = text[start..<end].replacingOccurrences(of: "\n", with: " ")
        return (start > text.startIndex ? "…" : "") + piece.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Persistence

    private func markDirty(_ id: UUID, immediate: Bool = false) {
        guard records[id] != nil else { return }
        records[id]?.generation &+= 1
        onLibraryChange?()
        debounce[id]?.cancel()
        debounce[id] = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled, let self else { return }
            self.debounce[id] = nil
            guard self.records[id]?.deleting != true else { return }
            await self.persist(id, force: false)
        }
    }

    private func markNotebooksDirty() {
        notebookState.generation &+= 1
        onLibraryChange?()
        Task { [weak self] in await self?.persistNotebooks(force: false) }
    }

    /// Writes the newest value of one note until the store has nothing newer for it.
    /// A value whose write failed is not retried here unless `force` asks for one more attempt.
    private func persist(_ id: UUID, force: Bool) async {
        var attempted = false
        while let record = records[id], notes[id] != nil, record.isDirty, record.conflict == nil {
            if let running = writing[id] { await running.value; continue }
            if let failure = record.failure, failure.generation == record.generation, attempted || !force { return }
            attempted = true
            let task = Task { await self.writeOnce(id) }
            writing[id] = task
            await task.value
        }
    }

    private func writeOnce(_ id: UUID) async {
        defer { writing[id] = nil }
        guard let job = makeJob(id) else { return }
        let ledger = self.ledger
        let receipt = await StoreDisk.runIO(on: io) { StoreDisk.perform(job, ledger: ledger) }
        apply(receipt, for: job)
    }

    private func makeJob(_ id: UUID) -> WriteJob? {
        guard let record = records[id], let note = notes[id] else { return nil }
        guard let data = try? Self.encoder.encode(note) else {
            records[id]?.failure = WriteFailure(message: "The note could not be encoded.", generation: record.generation, recovered: false)
            refreshIssues()
            return nil
        }
        return WriteJob(id: id, generation: record.generation, package: record.package, data: data, local: note, base: record.base,
                        expected: record.revision, recoveryDirectory: recoveryPackage(for: id, generation: record.generation))
    }

    /// Records what a write achieved. Only the generation that was actually written is acknowledged,
    /// so an edit that arrived during the write stays dirty and is reconciled with what was committed.
    private func apply(_ receipt: WriteReceipt, for job: WriteJob) {
        let id = job.id
        guard var record = records[id] else { return }
        let hadIssue = record.failure != nil || record.conflict != nil
        switch receipt {
        case .written(let committed, let revision, let adopted):
            guard job.generation > record.acknowledged else { return }
            let stale = record.recoveries
            record.base = committed
            record.revision = revision
            record.acknowledged = job.generation
            record.failure = nil
            record.conflict = nil
            record.recoveries = []
            records[id] = record
            if !stale.isEmpty { io.async { stale.forEach { try? FileManager.default.removeItem(at: $0) } } }
            if adopted, let current = notes[id] {
                if record.generation == job.generation {
                    // The commit brought in content from disk that memory did not have yet.
                    adopt(committed, for: id)
                } else {
                    reconcileNewerEdit(current, sent: job.local, committed: committed, id: id)
                }
            }
        case .failed(let message, let recovery):
            guard job.generation > record.acknowledged else { return }
            record.failure = WriteFailure(message: message, generation: job.generation, recovered: recovery != nil)
            if let recovery, !record.recoveries.contains(recovery) { record.recoveries.append(recovery) }
            records[id] = record
        case .conflict(let remote, let revision, let recovery):
            guard job.generation > record.acknowledged else { return }
            record.conflict = ConflictRecord(id: record.conflict?.id ?? UUID(), remote: remote, remoteRevision: revision, localRecovery: recovery)
            if let recovery, !record.recoveries.contains(recovery) { record.recoveries.append(recovery) }
            record.failure = nil
            records[id] = record
        }
        if hadIssue || records[id]?.failure != nil || records[id]?.conflict != nil { refreshIssues() }
    }

    private func adopt(_ note: Note, for id: UUID) {
        notes[id] = note
        searchIndex[id] = nil
        onLibraryChange?()
    }

    /// A newer local edit met a commit that brought in disk content. Merge it against what was sent;
    /// when both changed the same field, keep both versions instead of choosing one.
    private func reconcileNewerEdit(_ current: Note, sent: Note, committed: Note, id: UUID) {
        switch StoreDisk.merge(base: sent, local: current, remote: committed) {
        case .merged(let merged):
            if merged != current { adopt(merged, for: id) }
        case .conflict:
            guard let revision = records[id]?.revision else { return }
            let recovery = recoveryPackage(for: id, generation: records[id]?.generation ?? 0)
            let source = records[id]?.package
            var localData: Data?
            localData = try? Self.encoder.encode(current)
            let saved: Bool = io.sync {
                guard let localData, let source else { return false }
                return StoreDisk.writeRecovery(data: localData, package: source, to: recovery)
            }
            records[id]?.conflict = ConflictRecord(id: UUID(), remote: committed, remoteRevision: revision, localRecovery: saved ? recovery : nil)
            if saved { records[id]?.recoveries.append(recovery) }
        }
    }

    private func persistNotebooks(force: Bool) async {
        guard notebooksWritable else { return }
        var attempted = false
        while notebookState.isDirty {
            if let running = notebookWriting { await running.value; continue }
            if let failure = notebookState.failure, failure.generation == notebookState.generation, attempted || !force { return }
            attempted = true
            let task = Task { await self.writeNotebooksOnce() }
            notebookWriting = task
            await task.value
        }
    }

    private func writeNotebooksOnce() async {
        defer { notebookWriting = nil }
        guard let job = makeNotebookJob() else { return }
        apply(await StoreDisk.runIO(on: io) { StoreDisk.perform(job) }, for: job)
    }

    private func makeNotebookJob() -> NotebookJob? {
        guard let data = try? Self.encoder.encode(notebooks) else {
            notebookState.failure = WriteFailure(message: "The notebook list could not be encoded.", generation: notebookState.generation, recovered: false)
            refreshIssues()
            return nil
        }
        return NotebookJob(generation: notebookState.generation, data: data, url: notebooksURL, root: rootURL,
                           recoveryFile: recoveryDirectory.appendingPathComponent("notebooks-\(notebookState.generation).json"))
    }

    private func apply(_ receipt: NotebookReceipt, for job: NotebookJob) {
        let hadIssue = notebookState.failure != nil
        switch receipt {
        case .written:
            guard job.generation > notebookState.acknowledged else { return }
            notebookState.acknowledged = job.generation
            notebookState.failure = nil
        case .failed(let message, let recovered):
            notebookState.failure = WriteFailure(message: message, generation: job.generation, recovered: recovered)
        }
        if hadIssue || notebookState.failure != nil { refreshIssues() }
    }

    private func pendingFailures() -> [PersistenceFailure.Entry] {
        var entries: [PersistenceFailure.Entry] = []
        for id in records.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let record = records[id], record.isDirty else { continue }
            let title = notes[id]?.displayTitle ?? id.uuidString
            if let conflict = record.conflict {
                entries.append(.init(noteID: id, message: "“\(title)” was changed on disk and here; both versions are kept.", recovered: conflict.localRecovery != nil))
            } else if let failure = record.failure {
                entries.append(.init(noteID: id, message: "“\(title)”: \(failure.message)", recovered: failure.recovered && failure.generation == record.generation))
            } else {
                entries.append(.init(noteID: id, message: "“\(title)” has not been saved.", recovered: false))
            }
        }
        if notebookState.isDirty, notebooksWritable {
            entries.append(.init(noteID: nil, message: notebookState.failure.map { "Notebooks: \($0.message)" } ?? "Notebook changes have not been saved.",
                                 recovered: notebookState.failure?.recovered ?? false))
        }
        return entries
    }

    /// Writes everything that's still waiting and reports what could not be written.
    /// Failed values stay in memory; calling again retries them.
    func flush() async throws {
        debounce.values.forEach { $0.cancel() }
        debounce = [:]
        for id in records.keys.filter({ records[$0]?.isDirty == true }).sorted(by: { $0.uuidString < $1.uuidString }) {
            await persist(id, force: true)
        }
        await persistNotebooks(force: true)
        let entries = pendingFailures()
        if !entries.isEmpty { throw PersistenceFailure(entries: entries) }
    }

    /// Blocking variant for quit and tests that cannot await. Returns false when anything is still unsaved.
    @discardableResult
    func flush() -> Bool {
        debounce.values.forEach { $0.cancel() }
        debounce = [:]
        let ledger = self.ledger
        for id in records.keys.filter({ records[$0]?.isDirty == true && records[$0]?.conflict == nil }) {
            guard let job = makeJob(id) else { continue }
            apply(io.sync { StoreDisk.perform(job, ledger: ledger) }, for: job)
        }
        if notebooksWritable, notebookState.isDirty, let job = makeNotebookJob() {
            apply(io.sync { StoreDisk.perform(job) }, for: job)
        }
        io.sync {}
        return pendingFailures().isEmpty
    }

    // MARK: Resolving identity problems

    /// Removes a recovery copy found at launch, once the user has dealt with it.
    func dismissRecovery(_ issueID: UUID) throws {
        guard let issue = loadIssues.first(where: { $0.id == issueID && $0.kind == .recoveredEdit }) else { throw LibraryError.issueNotFound }
        for version in issue.versions { try FileManager.default.removeItem(at: version.package) }
        loadIssues.removeAll { $0.id == issueID }
        refreshIssues()
    }

    /// Publishes every version as its own note, then moves the originals to the Trash.
    /// Safe to repeat after an interruption: copies get stable IDs and are reused when they exist.
    func keepBothVersions(of issueID: UUID) async throws {
        if let group = duplicates.values.first(where: { $0.id == issueID }) {
            try await keepAll(of: group)
        } else if let (noteID, record) = records.first(where: { $0.value.conflict?.id == issueID }), let conflict = record.conflict {
            try await keepBoth(of: conflict, noteID: noteID)
        } else {
            throw LibraryError.issueNotFound
        }
    }

    private func keepAll(of group: DuplicateGroup) async throws {
        let notesURL = self.notesURL
        let copies = group.versions.map { (package: $0.package, note: $0.note, id: derivedUUID("keep-both:\(group.id):\($0.package.lastPathComponent)")) }
        let published = try await StoreDisk.runIO(on: io) {
            Result { try copies.map { try StoreDisk.publishCopy(of: $0.package, as: $0.note, id: $0.id, in: notesURL) } }
        }.get()
        for (note, revision, package) in published where records[note.id] == nil {
            register(note, package: package, revision: revision)
        }
        let (trashURL, ledger) = (self.trashURL, self.ledger)
        let originals = group.versions.map(\.package)
        try await StoreDisk.runIO(on: io) {
            Result { try originals.forEach { try StoreDisk.moveToTrash($0, id: group.noteID, trash: trashURL, ledger: ledger, missingIsFine: true) } }
        }.get()
        duplicates[group.noteID] = nil
        refreshIssues()
        onLibraryChange?()
    }

    private func keepBoth(of conflict: ConflictRecord, noteID: UUID) async throws {
        guard let record = records[noteID], let local = notes[noteID] else { throw LibraryError.issueNotFound }
        let notesURL = self.notesURL
        let fresh = derivedUUID("keep-both:\(conflict.id):local")
        let source = record.package
        let (note, revision, package) = try await StoreDisk.runIO(on: io) {
            Result { try StoreDisk.publishCopy(of: source, as: local, id: fresh, in: notesURL) }
        }.get()
        if records[note.id] == nil { register(note, package: package, revision: revision) }
        // The disk version stays as the note; the local version is now its own note.
        if var current = records[noteID] {
            let stale = current.recoveries
            current.base = conflict.remote
            current.revision = conflict.remoteRevision
            current.acknowledged = current.generation
            current.failure = nil
            current.conflict = nil
            current.recoveries = []
            records[noteID] = current
            if !stale.isEmpty { io.async { stale.forEach { try? FileManager.default.removeItem(at: $0) } } }
        }
        adopt(conflict.remote, for: noteID)
        refreshIssues()
    }

    private func register(_ note: Note, package: URL, revision: FileRevision) {
        notes[note.id] = note
        records[note.id] = NoteRecord(package: package, base: note, revision: revision)
        searchIndex[note.id] = nil
        onLibraryChange?()
    }

    // MARK: Imports

    /// Prepares the hidden folder a capture is assembled in before it is published. One location per
    /// capture ID, so leftovers from an earlier attempt are ours to remove; if they cannot be removed
    /// the attempt stops instead of allocating more files beside them.
    func beginCaptureStaging(for id: UUID) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: notesURL, withIntermediateDirectories: true)
        let staging = notesURL.appendingPathComponent(".capture-\(id.uuidString)", isDirectory: true)
        if fm.fileExists(atPath: staging.path) {
            do { try StoreDisk.removeTree(staging) } catch { throw LibraryError.stagingBlocked(staging) }
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    func discardCaptureStaging(_ staging: URL) {
        try? StoreDisk.removeTree(staging)
    }

    /// The note an earlier attempt already published for this capture, if any. A package with this ID
    /// that is not that note is a conflict, never something to overwrite or adopt.
    func publishedCapture(_ id: UUID) throws -> Note? {
        if let note = notes[id] { return note }
        let package = packageURL(for: id)
        guard FileManager.default.fileExists(atPath: package.path) else { return nil }
        guard let data = try? Data(contentsOf: package.appendingPathComponent("note.json")),
              let note = try? Self.decoder.decode(Note.self, from: data), note.id == id else {
            throw LibraryError.destinationConflict(id)
        }
        register(note, package: package, revision: FileRevision(data))
        return note
    }

    /// Writes the note into the staged folder and publishes the whole package with one move.
    func publishCapture(_ note: Note, staging: URL) throws -> Note {
        if let existing = try publishedCapture(note.id) { return existing }
        let data = try Self.encoder.encode(note)
        try data.write(to: staging.appendingPathComponent("note.json"), options: .atomic)
        let destination = packageURL(for: note.id)
        try FileManager.default.moveItem(at: staging, to: destination)
        register(note, package: destination, revision: FileRevision(data))
        return note
    }

    /// The notebook a capture should land in, or an error while the notebook list needs recovery.
    func captureNotebookID(requested: UUID?) throws -> UUID {
        if let id = requested.flatMap({ notebook($0)?.id }) ?? sortedNotebooks.first?.id { return id }
        throw LibraryError.notebooksUnavailable
    }

    static let encoder: JSONEncoder = makeEncoder()

    nonisolated static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static let decoder: JSONDecoder = makeDecoder()

    nonisolated static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension LibraryStore {
    func importSharedNote(_ file: SharedNoteFile) throws -> Note {
        let fm = FileManager.default
        let id = UUID()
        let notesDirectory = rootURL.appendingPathComponent("Notes", isDirectory: true)
        try fm.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        let staging = notesDirectory.appendingPathComponent(".import-\(id.uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let document = try file.content.imported(into: NoteAssets(package: staging))
        let notebook: Notebook?
        if let existing = notebooks.first(where: { $0.name == file.notebookName && $0.color == file.notebookColor }) {
            notebook = existing
        } else if let name = file.notebookName {
            guard !notebooksNeedRecovery else { throw LibraryError.notebooksUnavailable }
            notebook = createNotebook(name: name, color: file.notebookColor)
        } else {
            notebook = sortedNotebooks.first
        }
        guard let notebookID = notebook?.id ?? (notebooksNeedRecovery ? nil : UUID()) else { throw LibraryError.notebooksUnavailable }
        var note = Note.new(in: notebookID)
        note.id = id
        note.style = file.style
        note.tags = file.tags
        note.pinned = file.pinned
        note.created = file.created
        note.modified = file.modified
        note.document = document
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(note)
        try data.write(to: staging.appendingPathComponent("note.json"), options: .atomic)
        let destination = notesDirectory.appendingPathComponent("\(id.uuidString).notas", isDirectory: true)
        try fm.moveItem(at: staging, to: destination)
        // The package is complete before the library exposes the note.
        register(note, package: destination, revision: FileRevision(data))
        return note
    }
}

// MARK: - File-level helpers

/// Exact bytes of a file, by digest, so a revision is never inferred from a modification date.
struct FileRevision: Hashable {
    let digest: Data
    init(_ data: Data) { digest = Data(SHA256.hash(data: data)) }
}

/// What the writer knows about the files it replaced. Touched only on the library's I/O queue.
/// It lets a write recognise the previous write's result even while that write's receipt is still
/// waiting for the main actor.
private final class DiskLedger: @unchecked Sendable {
    private var revisions: [URL: FileRevision] = [:]
    func revision(for url: URL) -> FileRevision? { revisions[url] }
    func set(_ revision: FileRevision, for url: URL) { revisions[url] = revision }
    func remove(_ url: URL) { revisions[url] = nil }
    func removeAll() { revisions = [:] }
}

private struct WriteJob {
    let id: UUID
    let generation: UInt64
    let package: URL
    let data: Data
    let local: Note
    let base: Note?
    let expected: FileRevision?
    let recoveryDirectory: URL
}

private enum WriteReceipt {
    /// `committed` is what is now on disk. `adopted` means external content was merged into it.
    case written(committed: Note, FileRevision, adopted: Bool)
    case failed(String, recovery: URL?)
    case conflict(remote: Note, FileRevision, recovery: URL?)
}

private struct NotebookJob {
    let generation: UInt64
    let data: Data
    let url: URL
    let root: URL
    let recoveryFile: URL
}

private enum NotebookReceipt {
    case written
    case failed(String, recovered: Bool)
}

private enum MergeResult {
    case merged(Note)
    case conflict
}

private struct PackageRead {
    enum Outcome {
        case note(Note, FileRevision)
        case failure(String)
    }
    let url: URL
    let outcome: Outcome
}

private enum NotebookRead {
    case missing
    case invalid(String)
    case notebooks([Notebook])
}

private enum Listing {
    case missing
    case entries([URL])
    case failed(String)
}

/// A stable ID for something that has none of its own, so an interrupted operation can be repeated.
private func derivedUUID(_ seed: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
}

private enum StoreDisk {
    static func runIO<T>(on queue: DispatchQueue, _ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    static func isMissing(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) { return true }
        return false
    }

    static func list(_ directory: URL) -> Listing {
        do {
            return .entries(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
        } catch {
            return isMissing(error) ? .missing : .failed(error.localizedDescription)
        }
    }

    static func readNotebooks(at url: URL) -> NotebookRead {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            return isMissing(error) ? .missing : .invalid("notebooks.json could not be read (\(error.localizedDescription)).")
        }
        do { return .notebooks(try LibraryStore.makeDecoder().decode([Notebook].self, from: data)) } catch {
            return .invalid("notebooks.json is not valid (\(error.localizedDescription)).")
        }
    }

    /// Decodes every note package, spread across the CPU cores. Decoding dominates launch time
    /// for big libraries, and each note is independent.
    static func readNotes(in packages: [URL]) -> [PackageRead] {
        let count = packages.count
        guard count > 0 else { return [] }
        // Each worker writes only its own indices, so sharing the buffer is safe.
        struct Slots: @unchecked Sendable { let base: UnsafeMutablePointer<PackageRead?> }
        let storage = UnsafeMutablePointer<PackageRead?>.allocate(capacity: count)
        storage.initialize(repeating: nil, count: count)
        defer { storage.deinitialize(count: count); storage.deallocate() }
        let slots = Slots(base: storage)
        let workers = count < 8 ? 1 : min(ProcessInfo.processInfo.activeProcessorCount, 8)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let decoder = LibraryStore.makeDecoder()
            for i in stride(from: worker, to: count, by: workers) {
                let url = packages[i]
                do {
                    let data = try Data(contentsOf: url.appendingPathComponent("note.json"))
                    slots.base[i] = PackageRead(url: url, outcome: .note(try decoder.decode(Note.self, from: data), FileRevision(data)))
                } catch {
                    slots.base[i] = PackageRead(url: url, outcome: .failure(error.localizedDescription))
                }
            }
        }
        return (0..<count).compactMap { storage[$0] }
    }

    // MARK: Merging

    /// Three-way merge of one note. A field changed on only one side takes that side's value; a field
    /// both sides changed differently is a conflict. Timestamps never decide a winner.
    static func merge(base: Note?, local: Note, remote: Note) -> MergeResult {
        guard let base else { return local == remote ? .merged(local) : .conflict }
        var out = remote
        var conflicted = false
        func take<T: Equatable>(_ key: WritableKeyPath<Note, T>) {
            let b = base[keyPath: key], l = local[keyPath: key], r = remote[keyPath: key]
            if l == b || l == r { out[keyPath: key] = r } else if r == b { out[keyPath: key] = l } else { conflicted = true }
        }
        take(\.notebookID); take(\.tags); take(\.pinned); take(\.style)
        take(\.document); take(\.retainsEmptyDocument); take(\.created)
        guard !conflicted else { return .conflict }
        // The modified date describes whichever content survived.
        if out.document == local.document, out.document != remote.document {
            out.modified = local.modified
        } else if out.document == remote.document, out.document != local.document {
            out.modified = remote.modified
        } else {
            out.modified = max(local.modified, remote.modified)
        }
        return .merged(out)
    }

    // MARK: Writing a note

    /// Replaces a note's file only if it still holds what the store last saw (or what the previous
    /// write left). Anything else is merged or reported; it is never overwritten blindly.
    static func perform(_ job: WriteJob, ledger: DiskLedger) -> WriteReceipt {
        let key = job.package.appendingPathComponent("note.json")
        var receipt: WriteReceipt = .failed("The note could not be coordinated for writing.", recovery: nil)
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: key, options: .forMerging, error: &coordinationError) { url in
            receipt = replace(job, at: url, key: key, ledger: ledger)
        }
        if let coordinationError { receipt = .failed(coordinationError.localizedDescription, recovery: nil) }
        switch receipt {
        case .written: return receipt
        case .failed(let message, _): return .failed(message, recovery: recover(job))
        case .conflict(let remote, let revision, _): return .conflict(remote: remote, revision, recovery: recover(job))
        }
    }

    private static func replace(_ job: WriteJob, at url: URL, key: URL, ledger: DiskLedger) -> WriteReceipt {
        let current: Data?
        do { current = try Data(contentsOf: url) } catch {
            guard isMissing(error) else { return .failed("The saved note could not be read: \(error.localizedDescription)", recovery: nil) }
            current = nil
        }
        let currentRevision = current.map(FileRevision.init)
        var data = job.data
        var committed = job.local
        var adopted = false
        if currentRevision != (ledger.revision(for: key) ?? job.expected) {
            guard let current, let currentRevision else {
                return .failed("The note was removed from the library folder by something else.", recovery: nil)
            }
            if currentRevision == FileRevision(job.data) {
                ledger.set(currentRevision, for: key)
                return .written(committed: job.local, currentRevision, adopted: false)
            }
            let remote: Note
            do { remote = try LibraryStore.makeDecoder().decode(Note.self, from: current) } catch {
                return .failed("The note on disk changed and could not be read: \(error.localizedDescription)", recovery: nil)
            }
            guard remote.id == job.id else { return .failed("The note on disk now belongs to a different note.", recovery: nil) }
            switch merge(base: job.base, local: job.local, remote: remote) {
            case .conflict:
                return .conflict(remote: remote, currentRevision, recovery: nil)
            case .merged(let merged):
                guard let encoded = try? LibraryStore.makeEncoder().encode(merged) else {
                    return .failed("The merged note could not be encoded.", recovery: nil)
                }
                data = encoded
                committed = merged
                adopted = merged != job.local
            }
        }
        do {
            try FileManager.default.createDirectory(at: job.package, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return .failed(error.localizedDescription, recovery: nil)
        }
        let revision = FileRevision(data)
        ledger.set(revision, for: key)
        return .written(committed: committed, revision, adopted: adopted)
    }

    private static func recover(_ job: WriteJob) -> URL? {
        writeRecovery(data: job.data, package: job.package, to: job.recoveryDirectory) ? job.recoveryDirectory : nil
    }

    /// A complete, ordinary package (note.json plus assets) outside the library folder.
    static func writeRecovery(data: Data, package: URL, to directory: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("note.json"), options: .atomic)
            let assets = package.appendingPathComponent("assets", isDirectory: true)
            if fm.fileExists(atPath: assets.path) {
                let copy = directory.appendingPathComponent("assets", isDirectory: true)
                if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }
                try fm.copyItem(at: assets, to: copy)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Writing notebooks

    static func perform(_ job: NotebookJob) -> NotebookReceipt {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: job.root, withIntermediateDirectories: true)
            try job.data.write(to: job.url, options: .atomic)
            return .written
        } catch {
            var recovered = false
            do {
                try fm.createDirectory(at: job.recoveryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try job.data.write(to: job.recoveryFile, options: .atomic)
                recovered = true
            } catch {}
            return .failed(error.localizedDescription, recovered: recovered)
        }
    }

    // MARK: Moving packages

    static func removeTree(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// `<base>.<ext>` in the folder, or the first free `<base> 2.<ext>`, `<base> 3.<ext>`… Nothing existing is replaced.
    static func uniqueDestination(in folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent("\(base).\(ext)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).\(ext)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Moves the actual package, wherever it was found, to a free name in the Trash. A copy already
    /// in the Trash is never touched.
    @discardableResult
    static func moveToTrash(_ package: URL, id: UUID, trash: URL, ledger: DiskLedger, missingIsFine: Bool = false) throws -> URL {
        let fm = FileManager.default
        if missingIsFine, !fm.fileExists(atPath: package.path) { return package }
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = uniqueDestination(in: trash, base: id.uuidString, ext: "notas")
        try fm.moveItem(at: package, to: destination)
        ledger.remove(package.appendingPathComponent("note.json"))
        return destination
    }

    /// Publishes a copy of `package` under a new note ID. An existing copy with that ID is reused,
    /// so repeating an interrupted operation adds nothing.
    static func publishCopy(of package: URL, as note: Note, id: UUID, in notes: URL) throws -> (Note, FileRevision, URL) {
        let fm = FileManager.default
        var copy = note
        copy.id = id
        let data = try LibraryStore.makeEncoder().encode(copy)
        let destination = notes.appendingPathComponent("\(id.uuidString).notas", isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            guard let existing = try? Data(contentsOf: destination.appendingPathComponent("note.json")),
                  let decoded = try? LibraryStore.makeDecoder().decode(Note.self, from: existing), decoded.id == id else {
                throw LibraryError.destinationConflict(id)
            }
            return (decoded, FileRevision(existing), destination)
        }
        let staging = notes.appendingPathComponent(".copy-\(id.uuidString)", isDirectory: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let assets = package.appendingPathComponent("assets", isDirectory: true)
            if fm.fileExists(atPath: assets.path) { try fm.copyItem(at: assets, to: staging.appendingPathComponent("assets", isDirectory: true)) }
            try data.write(to: staging.appendingPathComponent("note.json"), options: .atomic)
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return (copy, FileRevision(data), destination)
    }
}
