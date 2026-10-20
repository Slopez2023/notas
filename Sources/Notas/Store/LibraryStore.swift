import Foundation
import Observation

/// Owns every notebook and note, and keeps them in sync with files on disk.
///
/// Layout (inside the library folder, by default `iCloud Drive/Notas`):
///   notebooks.json
///   Notes/<uuid>.notas/note.json
///   Trash/<uuid>.notas/note.json
@MainActor
@Observable
final class LibraryStore {
    private(set) var notebooks: [Notebook] = []
    private(set) var notes: [UUID: Note] = [:]
    let rootURL: URL
    @ObservationIgnored var onLibraryChange: (() -> Void)?

    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    /// Lowercased title and body per note, so a search doesn't rebuild them for every note on
    /// every keystroke. Dropped whenever a note's content may have changed.
    @ObservationIgnored private var searchIndex: [UUID: SearchEntry] = [:]
    private struct SearchEntry {
        let title: String
        let lowerBody: String
    }
    @ObservationIgnored private let io = DispatchQueue(label: "notas.library.io", qos: .utility)

    init(rootURL: URL = LibraryStore.defaultRoot()) {
        self.rootURL = rootURL
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

    private var notesURL: URL { rootURL.appendingPathComponent("Notes", isDirectory: true) }
    private var trashURL: URL { rootURL.appendingPathComponent("Trash", isDirectory: true) }
    private var notebooksURL: URL { rootURL.appendingPathComponent("notebooks.json") }

    private func packageURL(for id: UUID, in folder: URL? = nil) -> URL {
        (folder ?? notesURL).appendingPathComponent("\(id.uuidString).notas", isDirectory: true)
    }

    func assets(for id: UUID) -> NoteAssets { NoteAssets(package: packageURL(for: id)) }

    // MARK: Loading

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: notesURL, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: notebooksURL),
           let decoded = try? Self.decoder.decode([Notebook].self, from: data) {
            notebooks = decoded.sorted { $0.order < $1.order }
        }

        let packages = ((try? fm.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "notas" }
        notes = Dictionary(Self.readNotes(in: packages).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        searchIndex.removeAll()

        // Notes that were opened but never written in aren't worth keeping.
        for (id, note) in notes where note.document.isEmpty && note.tags.isEmpty {
            trash(id)
        }

        if notebooks.isEmpty {
            seedFirstRun()
        }
        // Any note pointing at a missing notebook goes to the first one.
        if let fallback = notebooks.first?.id {
            for (id, note) in notes where !notebooks.contains(where: { $0.id == note.notebookID }) {
                notes[id]?.notebookID = fallback
                scheduleSave(id)
            }
        }
    }

    /// Decodes every note package, spread across the CPU cores. Decoding dominates launch time
    /// for big libraries, and each note is independent.
    nonisolated private static func readNotes(in packages: [URL]) -> [Note] {
        let count = packages.count
        guard count > 0 else { return [] }
        // Each worker writes only its own indices, so sharing the buffer is safe.
        struct Slots: @unchecked Sendable { let base: UnsafeMutablePointer<Note?> }
        let storage = UnsafeMutablePointer<Note?>.allocate(capacity: count)
        storage.initialize(repeating: nil, count: count)
        defer { storage.deinitialize(count: count); storage.deallocate() }
        let slots = Slots(base: storage)
        let workers = count < 8 ? 1 : min(ProcessInfo.processInfo.activeProcessorCount, 8)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let decoder = makeDecoder()
            for i in stride(from: worker, to: count, by: workers) {
                guard let data = try? Data(contentsOf: packages[i].appendingPathComponent("note.json")) else { continue }
                slots.base[i] = try? decoder.decode(Note.self, from: data)
            }
        }
        return (0..<count).compactMap { storage[$0] }
    }

    private func seedFirstRun() {
        let personal = Notebook(id: UUID(), name: "Personal", color: .coral, order: 0)
        let ideas = Notebook(id: UUID(), name: "Ideas", color: .sun, order: 1)
        let lists = Notebook(id: UUID(), name: "Lists", color: .mint, order: 2)
        notebooks = [personal, ideas, lists]
        saveNotebooks()

        if notes.isEmpty {
            var welcome = Note.new(in: personal.id)
            welcome.pinned = true
            welcome.tags = ["start-here"]
            welcome.document = WelcomeNote.document
            notes[welcome.id] = welcome
            writeNow(welcome)
        }
    }

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

    @discardableResult
    func createNote(in notebookID: UUID?, style: NoteStyle = NoteStyle()) -> Note {
        let target = notebookID ?? notebooks.first?.id ?? UUID()
        var note = Note.new(in: target)
        note.style = style
        notes[note.id] = note
        scheduleSave(note.id)
        return note
    }

    /// Replace a note's content. Saves after a short pause so typing stays smooth.
    func updateDocument(_ id: UUID, _ document: NoteDocument) {
        guard var note = notes[id], note.document != document else { return }
        searchIndex[id] = nil
        note.document = document
        note.modified = Date()
        notes[id] = note
        scheduleSave(id)
    }

    func mutate(_ id: UUID, touch: Bool = true, _ change: (inout Note) -> Void) {
        guard var note = notes[id] else { return }
        searchIndex[id] = nil
        change(&note)
        if touch { note.modified = Date() }
        notes[id] = note
        scheduleSave(id)
    }

    func togglePin(_ id: UUID) { mutate(id, touch: false) { $0.pinned.toggle() } }

    func move(_ id: UUID, to notebookID: UUID) { mutate(id, touch: false) { $0.notebookID = notebookID } }

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
    func trash(_ id: UUID) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = nil
        notes[id] = nil
        searchIndex[id] = nil
        onLibraryChange?()
        let from = packageURL(for: id)
        let to = packageURL(for: id, in: trashURL)
        let trashURL = trashURL
        io.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try? fm.moveItem(at: from, to: to)
        }
    }

    /// Drops a note that was created but never written in. Keeps the library free of blank notes.
    func discardIfEmpty(_ id: UUID) {
        guard let note = notes[id], note.document.isEmpty,
              note.tags.isEmpty else { return }
        trash(id)
    }

    // MARK: Notebooks

    @discardableResult
    func createNotebook(name: String, color: NotebookColor? = nil) -> Notebook {
        let used = Set(notebooks.map(\.color))
        let pick = color ?? NotebookColor.allCases.first { !used.contains($0) } ?? .slate
        let notebook = Notebook(id: UUID(), name: name, color: pick, order: (notebooks.map(\.order).max() ?? -1) + 1)
        notebooks.append(notebook)
        saveNotebooks()
        return notebook
    }

    func renameNotebook(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].name = trimmed
        saveNotebooks()
    }

    func recolorNotebook(_ id: UUID, to color: NotebookColor) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].color = color
        saveNotebooks()
    }

    /// Deletes a notebook and moves its notes into the first remaining notebook.
    func deleteNotebook(_ id: UUID) {
        guard notebooks.count > 1, let fallback = sortedNotebooks.first(where: { $0.id != id }) else { return }
        notebooks.removeAll { $0.id == id }
        for note in notes.values where note.notebookID == id {
            move(note.id, to: fallback.id)
        }
        saveNotebooks()
    }

    func moveNotebook(_ id: UUID, by offset: Int) {
        var ordered = sortedNotebooks
        guard let i = ordered.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(ordered.count - 1, i + offset))
        guard i != j else { return }
        ordered.swapAt(i, j)
        for (n, nb) in ordered.enumerated() {
            if let k = notebooks.firstIndex(where: { $0.id == nb.id }) { notebooks[k].order = n }
        }
        saveNotebooks()
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

    private func scheduleSave(_ id: UUID) {
        onLibraryChange?()
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let note = self.notes[id] else { return }
            self.pendingSaves[id] = nil
            self.writeNow(note)
        }
    }

    /// Writes everything that's still waiting. Called on quit.
    func flush() {
        for (id, task) in pendingSaves {
            task.cancel()
            if let note = notes[id] { writeSync(note) }
        }
        pendingSaves.removeAll()
        io.sync {}
    }

    func persistCapture(_ note: Note) throws {
        let data = try Self.encoder.encode(note)
        let dir = packageURL(for: note.id)
        try io.sync {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("note.json"), options: .atomic)
        }
        notes[note.id] = note
        searchIndex[note.id] = nil
        onLibraryChange?()
    }

    private func writeNow(_ note: Note) {
        guard let data = try? Self.encoder.encode(note) else { return }
        let dir = packageURL(for: note.id)
        io.async { Self.write(data, to: dir) }
    }

    private func writeSync(_ note: Note) {
        guard let data = try? Self.encoder.encode(note) else { return }
        let dir = packageURL(for: note.id)
        io.sync { Self.write(data, to: dir) }
    }

    nonisolated private static func write(_ data: Data, to dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("note.json"), options: .atomic)
    }

    private func saveNotebooks() {
        onLibraryChange?()
        guard let data = try? Self.encoder.encode(notebooks) else { return }
        let url = notebooksURL
        let root = rootURL
        io.async {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

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
        let notebook = notebooks.first { $0.name == file.notebookName && $0.color == file.notebookColor }
            ?? file.notebookName.map { createNotebook(name: $0, color: file.notebookColor) }
            ?? sortedNotebooks.first
        var note = Note.new(in: notebook?.id ?? UUID())
        note.id = id
        note.style = file.style
        note.tags = file.tags
        note.pinned = file.pinned
        note.created = file.created
        note.modified = file.modified
        note.document = document
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.encoder.encode(note).write(to: staging.appendingPathComponent("note.json"), options: .atomic)
        let destination = notesDirectory.appendingPathComponent("\(id.uuidString).notas", isDirectory: true)
        try fm.moveItem(at: staging, to: destination)
        // The package is complete before the library exposes the note.
        notes[note.id] = note
        onLibraryChange?()
        return note
    }
}
