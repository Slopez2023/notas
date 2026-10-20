#if DEBUG
import AppKit
#if canImport(NotasShared)
import NotasShared
#endif

/// Regression checks for the storage findings S1–S8. Run with `Notas --storage-stability`.
/// Every scenario runs against production `LibraryStore` and capture import code in a scratch
/// directory; nothing here touches the real library, Application Support, or Keychain.
@MainActor
enum StorageStabilityTests {
    private static var passes = 0
    private static var failures = 0

    private static let notebookID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    static func run() async -> Bool {
        _ = NSApplication.shared
        setvbuf(stdout, nil, _IOLBF, 0)
        await run("S1 blocked package keeps the save") { try await blockedPackage() }
        await run("S1 restart finds the recovery copy") { try await recoveryAfterRestart() }
        await run("S1 failed recovery prevents quit") { try await failedRecovery() }
        await run("S1 newer edit during an older write") { try await newerEditDuringWrite() }
        await run("S1 notebooks follow the same rule") { try await blockedNotebooks() }
        await run("S2 damaged notebook metadata") { try await damagedNotebookMetadata() }
        await run("S3 external edit and local pin") { try await externalEditMerge() }
        await run("S3 concurrent edits conflict") { try await concurrentEditConflict() }
        await run("S4 trash keeps the latest content") { try await trashLatestContent() }
        await run("S5 blocked trash keeps the note") { try await blockedTrash() }
        await run("S6 renamed package") { try await renamedPackage() }
        await run("S6 duplicate identities") { try await duplicateIdentities() }
        await run("S7 capture retries") { try await captureRetries() }
        await run("S8 capture title and body") { try await captureTitleAndBody() }
        print(failures == 0 ? "✓ \(passes) storage checks passed" : "✗ \(failures) failed, \(passes) passed")
        return failures == 0
    }

    private static func run(_ name: String, _ body: () async throws -> Void) async {
        let before = failures
        do { try await body() } catch { failures += 1; print("FAIL [\(name)]: unexpected error \(error)") }
        print("\(failures == before ? "ok  " : "FAIL") \(name)")
    }

    private static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if condition { passes += 1 } else { failures += 1; print("FAIL (line \(line)): \(message)") }
    }

    // MARK: Fixtures

    /// A scratch library with its own recovery folder and shared-container folder.
    private final class Sandbox {
        let root: URL
        var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
        var recovery: URL { root.appendingPathComponent("Recovery", isDirectory: true) }
        var shared: URL { root.appendingPathComponent("Shared", isDirectory: true) }
        var notes: URL { library.appendingPathComponent("Notes", isDirectory: true) }
        var trash: URL { library.appendingPathComponent("Trash", isDirectory: true) }
        var notebooksFile: URL { library.appendingPathComponent("notebooks.json") }
        private var stores: [LibraryStore] = []
        private var counter = 0

        @MainActor init() {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("notas-storage-stability-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        @MainActor func makeStore() -> LibraryStore {
            let store = LibraryStore(rootURL: library, recoveryRoot: recovery)
            store.load()
            stores.append(store)
            return store
        }

        func package(_ id: UUID) -> URL { notes.appendingPathComponent("\(id.uuidString).notas", isDirectory: true) }

        func writeNotebooks(_ notebooks: [Notebook]) throws {
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try LibraryStore.makeEncoder().encode(notebooks).write(to: notebooksFile)
        }

        @discardableResult
        func writeNote(_ note: Note, into directory: URL? = nil, folder: String? = nil) throws -> URL {
            let package = folder.map { (directory ?? notes).appendingPathComponent($0, isDirectory: true) } ?? (directory ?? notes).appendingPathComponent("\(note.id.uuidString).notas", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try LibraryStore.makeEncoder().encode(note).write(to: package.appendingPathComponent("note.json"))
            return package
        }

        /// Replaces `url` with a plain file so nothing can be created inside it. Returns where the original went.
        func obstruct(_ url: URL) throws -> URL? {
            counter += 1
            var aside: URL?
            if FileManager.default.fileExists(atPath: url.path) {
                let moved = root.appendingPathComponent("aside-\(counter)")
                try FileManager.default.moveItem(at: url, to: moved)
                aside = moved
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("in the way".utf8))
            return aside
        }

        func restore(_ url: URL, from aside: URL?) throws {
            try FileManager.default.removeItem(at: url)
            if let aside { try FileManager.default.moveItem(at: aside, to: url) }
        }

        func packages(in folder: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "notas" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        func notesOnDisk(in folder: URL) -> [Note] { packages(in: folder).compactMap(Self.readNote) }

        static func readNote(at package: URL) -> Note? {
            (try? Data(contentsOf: package.appendingPathComponent("note.json"))).flatMap { try? LibraryStore.makeDecoder().decode(Note.self, from: $0) }
        }

        @MainActor func cleanup() {
            // Make everything writable again so scratch files can go, and stop timers from writing into it.
            if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in walker { chmod(url.path, 0o755) }
            }
            stores.forEach { let _: Bool = $0.flush() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func doc(_ title: String, _ body: String? = nil) -> NoteDocument {
        var blocks = [Block(kind: .title, runs: [InlineRun(text: title)])]
        if let body { blocks.append(Block(kind: .body, runs: [InlineRun(text: body)])) }
        return NoteDocument(blocks: blocks)
    }

    /// Whole-second dates, so a note survives a JSON round trip unchanged.
    private static func note(_ title: String, _ body: String? = nil, id: UUID = UUID(), modified: TimeInterval = 1_700_000_000) -> Note {
        Note(id: id, notebookID: notebookID, tags: [], created: Date(timeIntervalSince1970: 1_700_000_000),
             modified: Date(timeIntervalSince1970: modified), pinned: false, style: NoteStyle(), document: doc(title, body))
    }

    private static let mintNotebook = Notebook(id: notebookID, name: "Recipes", color: .mint, order: 0)

    /// Lets the I/O queue finish its asynchronous cleanup before the test looks at the disk.
    private static func drain(_ store: LibraryStore) { let _: Bool = store.flush() }

    /// The blocking overload, reached through a synchronous function so the async one is not chosen.
    private static func blockingTrash(_ store: LibraryStore, _ id: UUID) { store.trash(id) }

    private static func flushFailure(_ store: LibraryStore) async -> PersistenceFailure? {
        do { try await store.flush(); return nil } catch { return error as? PersistenceFailure }
    }

    private static func yield(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 20_000 { await Task.yield(); spins += 1 }
    }

    // MARK: S1

    private static func blockedPackage() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let original = note("Original")
        try sb.writeNote(original)
        let store = sb.makeStore()

        let aside = try sb.obstruct(sb.package(original.id))
        store.updateDocument(original.id, doc("Latest edit"))
        let failure = await flushFailure(store)
        check(failure != nil, "flush reports a blocked package")
        check(failure?.hasUnrecoveredEdits == false, "a recovery copy exists while the package is blocked")
        check(store.notes[original.id]?.document == doc("Latest edit"), "memory keeps the latest edit")
        check(store.hasUnsavedChanges(original.id), "the note is still dirty")
        check(store.issues.contains { $0.kind == .writeFailed && $0.noteID == original.id }, "a persistence issue is visible")
        check(sb.notesOnDisk(in: sb.recovery.appendingPathComponent(try recoveryFolder(sb))).map(\.document) == [doc("Latest edit")], "recovery package holds the latest edit")

        // Retrying without a fix keeps the value and still fails.
        check(await flushFailure(store) != nil, "retrying a blocked save fails again")
        check(store.notes[original.id]?.document == doc("Latest edit"), "memory still keeps the latest edit")

        try sb.restore(sb.package(original.id), from: aside)
        check(await flushFailure(store) == nil, "retry succeeds after storage recovers")
        check(!store.hasUnsavedChanges(original.id), "the note is clean after the acknowledged write")
        check(!store.issues.contains { $0.kind == .writeFailed }, "the persistence issue clears")
        drain(store)
        check(sb.packages(in: sb.recovery.appendingPathComponent(try recoveryFolder(sb))).isEmpty, "the recovery copy is removed once the library has the edit")
        check(sb.makeStore().notes[original.id]?.document == doc("Latest edit"), "reloaded disk contains exactly Latest edit")
    }

    private static func recoveryFolder(_ sb: Sandbox) throws -> String {
        try FileManager.default.contentsOfDirectory(atPath: sb.recovery.path).first ?? "missing"
    }

    private static func recoveryAfterRestart() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let original = note("Original")
        try sb.writeNote(original)
        let store = sb.makeStore()
        _ = try sb.obstruct(sb.package(original.id))
        store.updateDocument(original.id, doc("Latest edit"))
        check(await flushFailure(store) != nil, "the blocked save fails")

        // The app quits and starts again; the edit is offered back instead of forgotten.
        let restarted = sb.makeStore()
        let recovered = restarted.issues.first { $0.kind == .recoveredEdit && $0.noteID == original.id }
        check(recovered?.versions.first?.note?.document == doc("Latest edit"), "the recovered edit is visible after restart")
        if let recovered {
            try restarted.dismissRecovery(recovered.id)
            check(!restarted.issues.contains { $0.kind == .recoveredEdit } && sb.makeStore().issues.allSatisfy { $0.kind != .recoveredEdit }, "dismissing removes the recovery copy")
        }
    }

    private static func failedRecovery() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let original = note("Original")
        try sb.writeNote(original)
        let store = sb.makeStore()

        let packageAside = try sb.obstruct(sb.package(original.id))
        let recoveryAside = try sb.obstruct(sb.recovery)
        store.updateDocument(original.id, doc("Latest edit"))
        let failure = await flushFailure(store)
        check(failure?.hasUnrecoveredEdits == true, "with no recovery copy, quitting would lose the edit")
        check(store.flush() == false, "the blocking flush does not report success")
        check(store.notes[original.id]?.document == doc("Latest edit"), "the pending value is retained")
        check(store.issues.contains { $0.kind == .writeFailed && $0.noteID == original.id }, "the failure is visible")

        try sb.restore(sb.recovery, from: recoveryAside)
        try sb.restore(sb.package(original.id), from: packageAside)
        check(await flushFailure(store) == nil, "flush succeeds after both locations recover")
        check(sb.makeStore().notes[original.id]?.document == doc("Latest edit"), "the retained value reached disk")
    }

    private static func newerEditDuringWrite() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let original = note("Original")
        try sb.writeNote(original)
        let store = sb.makeStore()

        store.updateDocument(original.id, doc("Older"))
        var finished = false
        let flushing = Task { _ = await flushFailure(store); finished = true }
        await yield { store.hasWriteInFlight }
        check(store.hasWriteInFlight, "the older write is in flight")
        store.updateDocument(original.id, doc("Newer"))
        var sawCleanWithStaleDisk = false
        var spins = 0
        while !finished, spins < 20_000 {
            if !store.hasUnsavedChanges(original.id), sb.notesOnDisk(in: sb.notes).first?.document != doc("Newer") { sawCleanWithStaleDisk = true }
            await Task.yield(); spins += 1
        }
        await flushing.value
        check(!sawCleanWithStaleDisk, "a note is never clean while disk holds an older generation")
        check(!store.hasUnsavedChanges(original.id), "the newer generation was written and acknowledged")
        check(sb.makeStore().notes[original.id]?.document == doc("Newer"), "disk holds the newer edit")
    }

    private static func blockedNotebooks() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        let first = Notebook(id: notebookID, name: "Recipes", color: .mint, order: 0)
        try sb.writeNotebooks([first])
        try sb.writeNote(note("Anchor"))
        let store = sb.makeStore()
        check(store.notebook(notebookID)?.color == .mint, "fixture notebook loads with its color")

        try FileManager.default.removeItem(at: sb.notebooksFile)
        try FileManager.default.createDirectory(at: sb.notebooksFile, withIntermediateDirectories: true)
        let created = store.createNotebook(name: "Pantry", color: .sky)
        let failure = await flushFailure(store)
        check(failure != nil && failure?.entries.contains { $0.noteID == nil } == true, "flush reports the notebook write")
        check(store.notebook(created.id)?.name == "Pantry", "memory keeps the new notebook")
        check(store.issues.contains { $0.kind == .notebookWriteFailed }, "a notebook persistence issue is visible")

        try FileManager.default.removeItem(at: sb.notebooksFile)
        check(await flushFailure(store) == nil, "notebook retry succeeds after storage recovers")
        check(!store.issues.contains { $0.kind == .notebookWriteFailed }, "the notebook issue clears")
        let reloaded = sb.makeStore()
        check(reloaded.notebook(created.id)?.name == "Pantry" && reloaded.notebook(created.id)?.color == .sky, "reloaded notebook keeps its ID, name and color")
        check(reloaded.notebook(notebookID)?.color == .mint, "the other notebook is unchanged")

        // A newer notebook edit during an older write stays dirty until it is written.
        store.renameNotebook(created.id, to: "Pantry A")
        var finished = false
        let flushing = Task { _ = await flushFailure(store); finished = true }
        await yield { store.hasWriteInFlight }
        store.renameNotebook(created.id, to: "Pantry B")
        var sawCleanWithStaleDisk = false
        var spins = 0
        while !finished, spins < 20_000 {
            let onDisk = (try? Data(contentsOf: sb.notebooksFile)).flatMap { try? LibraryStore.makeDecoder().decode([Notebook].self, from: $0) }
            if !store.hasUnsavedNotebookChanges, onDisk?.first(where: { $0.id == created.id })?.name != "Pantry B" { sawCleanWithStaleDisk = true }
            await Task.yield(); spins += 1
        }
        await flushing.value
        check(!sawCleanWithStaleDisk, "notebooks are never clean while disk holds an older generation")
        check(sb.makeStore().notebook(created.id)?.name == "Pantry B", "disk holds the newer notebook name")
    }

    // MARK: S2

    private static func damagedNotebookMetadata() async throws {
        let truncated = Data("{truncated".utf8)

        // Populated library, notebook list damaged.
        do {
            let sb = Sandbox(); defer { sb.cleanup() }
            try sb.writeNotebooks([mintNotebook])
            let kept = note("Kept note", "stays in its notebook")
            try sb.writeNote(kept)
            let healthy = sb.makeStore()
            check(healthy.notebook(notebookID)?.color == .mint && !healthy.notebooksNeedRecovery, "fixture library loads normally")

            try truncated.write(to: sb.notebooksFile)
            let store = sb.makeStore()
            check(store.notebooksNeedRecovery, "damaged metadata requires recovery")
            check(store.notebooks.isEmpty, "no notebooks are invented or reseeded")
            check(store.notes.count == 1 && store.notes[kept.id]?.notebookID == notebookID, "the note keeps notebook 11111111-1111-1111-1111-111111111111")
            check(store.unassignedNotebookIDs == [notebookID], "the unassigned reference is shown, not rewritten")
            check(store.issues.contains { $0.kind == .notebooksUnreadable }, "the damage is a visible issue")
            store.createNotebook(name: "Replacement", color: .sky)
            store.renameNotebook(notebookID, to: "Renamed")
            store.deleteNotebook(notebookID)
            store.moveNotebook(notebookID, by: 1)
            store.togglePin(kept.id)
            let failure = await flushFailure(store)
            check(failure == nil, "the pin change saves while notebooks await recovery")
            let _: Bool = store.flush()
            check((try? Data(contentsOf: sb.notebooksFile)) == truncated, "notebooks.json keeps its exact bytes")
            check(sb.notesOnDisk(in: sb.notes).first?.notebookID == notebookID, "the note on disk keeps its notebook UUID")

            // Once the file is repaired, the original notebook is back with its color.
            try sb.writeNotebooks([mintNotebook])
            let repaired = sb.makeStore()
            check(!repaired.notebooksNeedRecovery && repaired.notebook(notebookID)?.color == .mint, "after repair the notebook returns as .mint")
        }

        // Missing metadata in a populated library is recovery too.
        do {
            let sb = Sandbox(); defer { sb.cleanup() }
            try sb.writeNote(note("Orphan"))
            let store = sb.makeStore()
            check(store.notebooksNeedRecovery && store.notebooks.isEmpty, "missing metadata in a populated library is recovery")
            check(store.notes.count == 1, "no welcome note is added")
            let _: Bool = store.flush()
            check(!FileManager.default.fileExists(atPath: sb.notebooksFile.path), "no notebooks.json is written")
        }

        // Unreadable metadata is recovery, not a first run.
        do {
            let sb = Sandbox(); defer { sb.cleanup() }
            try sb.writeNotebooks([mintNotebook])
            try sb.writeNote(note("Guarded"))
            let original = try Data(contentsOf: sb.notebooksFile)
            chmod(sb.notebooksFile.path, 0o000)
            let store = sb.makeStore()
            check(store.notebooksNeedRecovery && store.notebooks.isEmpty, "unreadable metadata is recovery")
            let _: Bool = store.flush()
            chmod(sb.notebooksFile.path, 0o644)
            check((try? Data(contentsOf: sb.notebooksFile)) == original, "unreadable metadata keeps its bytes")
        }

        // Damaged metadata is preserved even before any note exists.
        do {
            let sb = Sandbox(); defer { sb.cleanup() }
            try FileManager.default.createDirectory(at: sb.library, withIntermediateDirectories: true)
            try truncated.write(to: sb.notebooksFile)
            let store = sb.makeStore()
            let _: Bool = store.flush()
            check(store.notebooksNeedRecovery && (try? Data(contentsOf: sb.notebooksFile)) == truncated, "damaged metadata is never overwritten by a seed")
        }

        // A genuinely new library still seeds.
        do {
            let sb = Sandbox(); defer { sb.cleanup() }
            let store = sb.makeStore()
            check(!store.notebooksNeedRecovery && store.notebooks.map(\.name) == ["Personal", "Ideas", "Lists"], "a new library seeds its notebooks")
            check(store.notes.count == 1, "a new library gets one welcome note")
            check(await flushFailure(store) == nil, "the seed is written")
            let reloaded = sb.makeStore()
            check(reloaded.notebooks.map(\.id) == store.notebooks.map(\.id) && reloaded.notes.count == 1, "the seeded library reloads unchanged")
        }
    }

    // MARK: S3

    private static func externalEditMerge() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let base = note("Base text", "Base body")
        try sb.writeNote(base)
        let store = sb.makeStore()

        var remote = base
        remote.document = doc("Remote newer text", "Only remote body")
        remote.modified = Date(timeIntervalSince1970: 1_700_000_500)
        try sb.writeNote(remote)

        store.togglePin(base.id)
        check(await flushFailure(store) == nil, "pinning a stale note saves")
        let reloaded = sb.makeStore().notes[base.id]
        check(reloaded?.document == doc("Remote newer text", "Only remote body"), "both external strings are kept")
        check(reloaded?.pinned == true, "the pin is applied on top")
        check(store.notes[base.id]?.document == doc("Remote newer text", "Only remote body") && store.notes[base.id]?.pinned == true, "memory adopts the external text")
        check(!store.issues.contains { $0.kind == .conflict }, "a compatible change is not a conflict")
    }

    private static func concurrentEditConflict() async throws {
        // Neither the newer nor the older timestamp may decide the outcome.
        for remoteModified in [1_700_000_500.0, 1_600_000_000.0] {
            let sb = Sandbox(); defer { sb.cleanup() }
            try sb.writeNotebooks([mintNotebook])
            let base = note("Base text", "Base body")
            try sb.writeNote(base)
            let store = sb.makeStore()

            var remote = base
            remote.document = doc("Remote newer text", "Only remote body")
            remote.modified = Date(timeIntervalSince1970: remoteModified)
            let package = try sb.writeNote(remote)
            let remoteBytes = try Data(contentsOf: package.appendingPathComponent("note.json"))

            store.updateDocument(base.id, doc("Local-only text"))
            let failure = await flushFailure(store)
            check(failure != nil, "a concurrent change stops the write")
            check(failure?.hasUnrecoveredEdits == false, "the local version is recoverable")
            check((try? Data(contentsOf: package.appendingPathComponent("note.json"))) == remoteBytes, "disk still holds the remote version byte for byte")
            check(store.notes[base.id]?.document == doc("Local-only text"), "memory still holds the local version")
            let conflict = store.issues.first { $0.kind == .conflict && $0.noteID == base.id }
            check(conflict != nil, "the conflict is visible")
            guard let conflict else { continue }
            let titles = Set(conflict.versions.compactMap { $0.note?.title })
            check(titles == ["Remote newer text", "Local-only text"], "both complete versions are listed")
            check(conflict.versions.contains { $0.note?.document == doc("Remote newer text", "Only remote body") }, "the remote version is complete")
            check(conflict.versions.allSatisfy { Sandbox.readNote(at: $0.package) != nil }, "each version is a readable package")

            // Keep Both publishes the local version as its own note and leaves disk's version in place.
            try await store.keepBothVersions(of: conflict.id)
            let after = sb.makeStore()
            check(after.notes[base.id]?.document == doc("Remote newer text", "Only remote body"), "the original ID keeps the disk version")
            let copies = after.notes.values.filter { $0.id != base.id }
            check(copies.count == 1 && copies.first?.document == doc("Local-only text"), "the local version becomes an independent note")
            check(!store.issues.contains { $0.kind == .conflict }, "the conflict is resolved")
        }
    }

    // MARK: S4, S5

    private static func trashLatestContent() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let old = note("Old content")
        try sb.writeNote(old)
        let store = sb.makeStore()

        store.updateDocument(old.id, doc("Latest content"))
        try await store.trash(old.id)
        check(sb.notesOnDisk(in: sb.trash).map(\.document) == [doc("Latest content")], "Trash holds Latest content")
        check(store.notes[old.id] == nil && sb.packages(in: sb.notes).isEmpty, "the note left the library")
        check(sb.makeStore().notes[old.id] == nil, "the deleted note does not resurrect")

        let fresh = store.createNote(in: notebookID)
        store.updateDocument(fresh.id, doc("Newly typed note"))
        try await store.trash(fresh.id)
        check(sb.notesOnDisk(in: sb.trash).contains { $0.id == fresh.id && $0.document == doc("Newly typed note") }, "a note typed moments ago is recoverable from Trash")
        check(sb.makeStore().notes[fresh.id] == nil, "the new note does not resurrect")

        // The blocking variant follows the same rule.
        let third = store.createNote(in: notebookID)
        store.updateDocument(third.id, doc("Blocking path"))
        blockingTrash(store, third.id)
        check(sb.notesOnDisk(in: sb.trash).contains { $0.id == third.id && $0.document == doc("Blocking path") } && store.notes[third.id] == nil, "the blocking trash keeps the latest content too")
    }

    private static func blockedTrash() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let target = note("Cannot move to Trash")
        try sb.writeNote(target)
        let store = sb.makeStore()

        _ = try sb.obstruct(sb.trash)
        var thrown: Error?
        do { try await store.trash(target.id) } catch { thrown = error }
        check(thrown != nil, "a blocked Trash move reports an error")
        check(store.notes[target.id]?.document == doc("Cannot move to Trash"), "the note stays visible with its document")
        check(FileManager.default.fileExists(atPath: sb.package(target.id).path), "the package stays in Notes")
        check(store.issues.contains { $0.kind == .trashFailed && $0.noteID == target.id }, "the failure is an issue")
        store.updateDocument(target.id, doc("Cannot move to Trash", "still editable"))
        check(store.notes[target.id]?.document == doc("Cannot move to Trash", "still editable"), "editing is re-enabled after the failure")

        // Restore storage with a prior copy already in Trash; retry keeps it.
        try FileManager.default.removeItem(at: sb.trash)
        let prior = note("Prior Trash copy", id: target.id)
        try sb.writeNote(prior, into: sb.trash)
        try await store.trash(target.id)
        let trashed = sb.notesOnDisk(in: sb.trash)
        check(trashed.count == 2, "the Trash holds both the prior copy and the new one")
        check(trashed.contains { $0.document == doc("Prior Trash copy") }, "the prior Trash copy is kept")
        check(trashed.contains { $0.document == doc("Cannot move to Trash", "still editable") }, "the retried delete is in Trash")
        check(store.notes[target.id] == nil && !store.issues.contains { $0.kind == .trashFailed }, "the note leaves only after the move succeeded")
    }

    // MARK: S6

    private static func renamedPackage() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let renamed = note("Renamed folder")
        let folder = try sb.writeNote(renamed, folder: "Holiday photos.notas")
        let store = sb.makeStore()

        check(store.notes[renamed.id] != nil, "the note loads from its actual location")
        check(store.assets(for: renamed.id).directory.deletingLastPathComponent().lastPathComponent == "Holiday photos.notas", "assets resolve inside the actual package")
        check(store.issues.contains { $0.kind == .locationMismatch && $0.noteID == renamed.id }, "the odd location is reported")
        store.togglePin(renamed.id)
        check(await flushFailure(store) == nil, "edits save")
        check(!FileManager.default.fileExists(atPath: sb.package(renamed.id).path), "no second package is created at the canonical path")
        check(Sandbox.readNote(at: folder)?.pinned == true, "the edit went to the actual package")

        try await store.trash(renamed.id)
        check(!FileManager.default.fileExists(atPath: folder.path), "delete moved the actual path")
        check(sb.notesOnDisk(in: sb.trash).map(\.id) == [renamed.id], "the package is in Trash")
        check(sb.makeStore().notes[renamed.id] == nil && sb.packages(in: sb.notes).isEmpty, "the deleted note does not resurrect")
    }

    private static func duplicateIdentities() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let id = UUID()
        try sb.writeNote(note("Canonical copy", id: id))
        try sb.writeNote(note("Conflict copy", id: id), folder: "\(id.uuidString) 2.notas")
        let store = sb.makeStore()

        let issue = store.issues.first { $0.kind == .duplicateID && $0.noteID == id }
        check(issue != nil, "the duplicate identity is reported")
        guard let issue else { return }
        check(Set(issue.versions.compactMap { $0.note?.title }) == ["Canonical copy", "Conflict copy"], "both copies are listed with their titles")
        check(Set(issue.versions.map(\.package)).count == 2 && issue.versions.allSatisfy { Sandbox.readNote(at: $0.package) != nil }, "each copy has its own readable package")
        check(Set(issue.versions.map(\.id)).count == 2, "versions have distinct IDs")
        check(store.notes[id] == nil, "neither copy is hidden behind the other")
        var thrown: Error?
        do { try await store.trash(id) } catch { thrown = error }
        check(thrown != nil && sb.packages(in: sb.notes).count == 2, "deleting an unresolved duplicate is blocked")
        store.updateDocument(id, doc("Overwrite attempt"))
        check(sb.notesOnDisk(in: sb.notes).map(\.title).sorted() == ["Canonical copy", "Conflict copy"], "edits cannot reach either copy")

        // An interruption: Trash cannot take the originals.
        _ = try sb.obstruct(sb.trash)
        var interrupted: Error?
        do { try await store.keepBothVersions(of: issue.id) } catch { interrupted = error }
        check(interrupted != nil, "Keep Both reports the interruption")
        check(store.issues.contains { $0.kind == .duplicateID }, "the duplicate stays listed until the originals are safe")
        let published = sb.notesOnDisk(in: sb.notes).filter { $0.id != id }
        check(Set(published.map(\.title)) == ["Canonical copy", "Conflict copy"], "independent copies were already published")
        check(sb.packages(in: sb.notes).count == 4, "the originals are still in Notes")

        try FileManager.default.removeItem(at: sb.trash)
        try await store.keepBothVersions(of: issue.id)
        let remaining = sb.notesOnDisk(in: sb.notes)
        check(remaining.count == 2 && Set(remaining.map(\.title)) == ["Canonical copy", "Conflict copy"], "retry adds no extra copies")
        check(remaining.allSatisfy { $0.id != id } && Set(remaining.map(\.id)).count == 2, "the copies have fresh, distinct IDs")
        check(sb.notesOnDisk(in: sb.trash).count == 2, "both originals are retained in Trash")
        check(!store.issues.contains { $0.kind == .duplicateID }, "the issue is resolved")

        let reloaded = sb.makeStore()
        check(reloaded.issues.filter { $0.kind == .duplicateID }.isEmpty && Set(reloaded.notes.values.map(\.title)) == ["Canonical copy", "Conflict copy"], "reload shows both independent notes")
        guard let first = reloaded.notes.values.first(where: { $0.title == "Canonical copy" }) else { check(false, "the canonical copy reloads"); return }
        reloaded.updateDocument(first.id, doc("Canonical copy", "edited"))
        let _: Bool = reloaded.flush()
        check(sb.makeStore().notes.values.first { $0.title == "Conflict copy" }?.document == doc("Conflict copy"), "editing one copy leaves the other alone")
    }

    // MARK: S7

    private static func pngData(_ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in color.setFill(); rect.fill(); return true }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    private static func assetNames(_ sb: Sandbox, _ id: UUID) -> [String] {
        let directory = sb.package(id).appendingPathComponent("assets", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private static func captureRetries() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let store = sb.makeStore()
        let shared = SharedCaptureStore(directory: sb.shared)
        let goodPNG = pngData(.systemGreen)

        func commit(_ id: UUID, text: String, files: [String: Data]) throws -> (CaptureRequest, URL) {
            let staging = try shared.createStagingDirectory(id: id)
            for (name, data) in files { try data.write(to: staging.appendingPathComponent(name)) }
            let request = CaptureRequest(id: id, text: text, notebookID: notebookID,
                                         attachments: files.keys.sorted().map { CaptureAttachment(name: $0, typeIdentifier: "public.png") })
            try shared.commit(request, staging: staging)
            return (request, shared.inboxURL.appendingPathComponent(id.uuidString + ".capture"))
        }

        // Good image first, bad image second, three times.
        let id = UUID()
        let (request, inbox) = try commit(id, text: "Two photos", files: ["a-good.png": goodPNG, "b-bad.png": Data("not an image".utf8)])
        var counts: [Int] = []
        var failedEveryTime = true
        for _ in 0..<3 {
            do { _ = try store.importCapture(request, package: inbox); failedEveryTime = false } catch {}
            counts.append(assetNames(sb, id).count)
        }
        check(failedEveryTime, "every retry with a bad image fails")
        check(counts == [0, 0, 0], "destination asset counts stay [0, 0, 0]")
        check(store.notes[id] == nil && !FileManager.default.fileExists(atPath: sb.package(id).path), "no partial note or package is published")
        check(((try? FileManager.default.contentsOfDirectory(atPath: sb.notes.path)) ?? []).filter { $0.hasPrefix(".capture-") }.isEmpty, "failed attempts remove their own staging files")
        check(try shared.pendingPackages().map(\.lastPathComponent) == [inbox.lastPathComponent] && FileManager.default.fileExists(atPath: inbox.appendingPathComponent("b-bad.png").path), "the inbox is intact")

        // Repair the input: the import succeeds with both images.
        try goodPNG.write(to: inbox.appendingPathComponent("b-bad.png"))
        let imported = try store.importCapture(request, package: inbox)
        check(imported.document.blocks.last?.payload?.images?.count == 2 && assetNames(sb, id).count == 2, "the repaired capture imports both images")
        check(sb.makeStore().notes[id]?.document == imported.document, "the imported note is on disk")

        // Retry after publication, before the inbox was acknowledged: exactly one note.
        let single = UUID()
        let (singleRequest, singleInbox) = try commit(single, text: "One photo", files: ["only.png": goodPNG])
        let published = try store.importCapture(singleRequest, package: singleInbox)
        let again = try store.importCapture(singleRequest, package: singleInbox)
        let restarted = sb.makeStore()
        let afterRestart = try restarted.importCapture(singleRequest, package: singleInbox)
        check(published == again && published.document == afterRestart.document && published.id == afterRestart.id, "retries return the note that was published")
        check(sb.packages(in: sb.notes).filter { $0.lastPathComponent == "\(single.uuidString).notas" }.count == 1, "exactly one package exists")
        check(restarted.notes.values.filter { $0.id == single }.count == 1, "exactly one note exists after a restart")
        let name = published.document.blocks.last?.payload?.images?.first
        check(assetNames(sb, single) == [name ?? "?"], "no extra asset was allocated by the retries")
        check(name.flatMap { try? Data(contentsOf: sb.package(single).appendingPathComponent("assets/\($0)")) } == goodPNG, "the expected image payload is stored")
        try shared.acknowledge(package: singleInbox)
        check(try shared.pendingPackages().map(\.lastPathComponent) == [inbox.lastPathComponent], "acknowledging removes only the imported capture")

        // A different package already at the destination is a conflict, never overwritten.
        let collision = UUID()
        let (collisionRequest, collisionInbox) = try commit(collision, text: "Collides", files: [:])
        try FileManager.default.createDirectory(at: sb.package(collision), withIntermediateDirectories: true)
        try Data("not a note".utf8).write(to: sb.package(collision).appendingPathComponent("stranger.txt"))
        var conflict: Error?
        do { _ = try store.importCapture(collisionRequest, package: collisionInbox) } catch { conflict = error }
        check(conflict is LibraryError && FileManager.default.fileExists(atPath: sb.package(collision).appendingPathComponent("stranger.txt").path), "an unrelated destination reports a conflict and is left alone")

        // Leftovers that cannot be removed block another attempt instead of piling up more files.
        let stuck = UUID()
        let (stuckRequest, stuckInbox) = try commit(stuck, text: "Stuck", files: ["photo.png": goodPNG])
        let staging = sb.notes.appendingPathComponent(".capture-\(stuck.uuidString)", isDirectory: true)
        let locked = staging.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("leftover".utf8).write(to: locked.appendingPathComponent("leftover.png"))
        chmod(locked.path, 0o555)
        var blocked: Error?
        do { _ = try store.importCapture(stuckRequest, package: stuckInbox) } catch { blocked = error }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: locked.path)) ?? []
        check(blocked != nil && contents == ["leftover.png"], "unremovable staging blocks the attempt without allocating more assets")
        check(store.notes[stuck] == nil && FileManager.default.fileExists(atPath: stuckInbox.path), "the blocked import leaves the inbox intact")
        chmod(locked.path, 0o755)
        check((try? store.importCapture(stuckRequest, package: stuckInbox)) != nil && assetNames(sb, stuck).count == 1, "once the leftovers can go, the import succeeds")
    }

    // MARK: S8

    private static func captureTitleAndBody() async throws {
        let sb = Sandbox(); defer { sb.cleanup() }
        try sb.writeNotebooks([mintNotebook])
        let store = sb.makeStore()

        func importAndReload(_ text: String) throws -> (CaptureRequest, Note?) {
            let request = CaptureRequest(text: text, notebookID: notebookID)
            _ = try store.importCapture(request)
            return (request, sb.makeStore().notes[request.id])
        }

        let (blankFirst, blankNote) = try importAndReload("  \nMust keep this line")
        check(blankFirst.title == "Must keep this line" && blankFirst.body.isEmpty, "a blank first line does not become the title")
        check(blankNote?.title == "Must keep this line" && blankNote?.document.blocks.count == 1, "the reloaded title is Must keep this line")

        let (_, secondNote) = try importAndReload("  \nMust keep this line\nSecond line")
        let secondRequest = CaptureRequest(text: "  \nMust keep this line\nSecond line")
        check(secondRequest.body == "Second line", "the body is Second line")
        check(secondNote?.title == "Must keep this line" && secondNote?.document.blocks.dropFirst().map(\.plainText) == ["Second line"], "the reloaded body is Second line")

        let crlf = CaptureRequest(text: "Title\r\nBody\r\n\r\nMore")
        check(crlf.title == "Title" && crlf.body == "Body\n\nMore", "CRLF line endings are one line break")
        let leading = CaptureRequest(text: "\n\n  Heading  \n\n\nFirst\n \nSecond\n\n")
        check(leading.title == "Heading" && leading.body == "First\n \nSecond", "leading and trailing blank lines are dropped, inner ones kept")

        let line = String(repeating: "L", count: 200)
        let (longRequest, longNote) = try importAndReload("  \n\(line)\nTail")
        check(longRequest.title == String(line.prefix(160)) && longRequest.body == "\(line)\nTail", "a long title keeps the full original line in the body")
        check(longNote?.title.count == 160 && longNote?.document.blocks.dropFirst().map(\.plainText) == [line, "Tail"], "the reloaded note keeps the full line")

        check(CaptureRequest(text: "", links: [URL(string: "https://example.com/x")!]).title == "example.com", "link-only captures still use the host")
        check(CaptureRequest(text: " \n ", attachments: [CaptureAttachment(name: "a.png", typeIdentifier: "public.png")]).title == "Shared photos", "photo-only captures still say so")
    }
}
#endif
