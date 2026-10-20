import AppKit
import WidgetKit
#if canImport(NotasShared)
import NotasShared
#endif

extension LibraryStore {
    /// A capture ID is also its note ID, so retrying after a crash cannot duplicate it.
    /// Everything is assembled in one hidden folder and published with a single move, so a failure
    /// leaves no half-written package, and the caller's inbox or draft is only cleared after success.
    @discardableResult
    func importCapture(_ request: CaptureRequest, package: URL? = nil, style: NoteStyle = NoteStyle()) throws -> Note {
        if let note = try publishedCapture(request.id) { return note }
        guard !request.isEmpty else { throw CaptureError.emptyCapture }
        let notebookID = try captureNotebookID(requested: request.notebookID)
        var blocks = [Block(kind: .title, runs: [InlineRun(text: request.title)])]
        if !request.body.isEmpty {
            blocks += request.body.components(separatedBy: "\n").map { Block(kind: .body, runs: [InlineRun(text: $0)]) }
        }
        for url in request.links {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw CaptureError.invalidAttachment }
            blocks.append(Block(kind: .body, runs: [InlineRun(text: url.absoluteString, link: url.absoluteString)]))
        }
        if !request.attachments.isEmpty, package == nil { throw CaptureError.invalidAttachment }
        let staging = try beginCaptureStaging(for: request.id)
        do {
            if let package, !request.attachments.isEmpty {
                let assets = NoteAssets(package: staging)
                let images = try request.attachments.flatMap { attachment in
                    try assets.importFile(try SharedCaptureStore.attachmentURL(name: attachment.name, in: package))
                }
                blocks.append(Block(kind: .gallery, runs: [], payload: BlockPayload(images: images)))
            }
            let note = Note(id: request.id, notebookID: notebookID, tags: [], created: request.created,
                            modified: request.created, pinned: false, style: style, document: NoteDocument(blocks: blocks))
            return try publishCapture(note, staging: staging)
        } catch {
            discardCaptureStaging(staging)
            throw error
        }
    }
}

@MainActor
final class CaptureIntegration {
    let app: AppState
    let shared: SharedCaptureStore?
    private let reloadWidgets: () -> Void
    private var observer: NSObjectProtocol?
    private var directorySource: DispatchSourceFileSystemObject?
    private var publishTask: Task<Void, Never>?
    private var lastPublished: SharedLibrarySnapshot?
    private(set) var lastError: String?

    init(app: AppState, shared: SharedCaptureStore? = try? .live(), reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: "NotasFavorite") }) {
        self.app = app
        self.shared = shared
        self.reloadWidgets = reloadWidgets
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        directorySource?.cancel()
        publishTask?.cancel()
    }

    func start() {
        app.store.onLibraryChange = { [weak self] in self?.schedulePublish() }
        observer = DistributedNotificationCenter.default().addObserver(forName: .notasCaptureReady, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.importPending() }
        }
        if let shared {
            do {
                try FileManager.default.createDirectory(at: shared.inboxURL, withIntermediateDirectories: true)
                let descriptor = Darwin.open(shared.inboxURL.path, O_EVTONLY)
                if descriptor >= 0 {
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
                    source.setEventHandler { [weak self] in self?.importPending() }
                    source.setCancelHandler { Darwin.close(descriptor) }
                    source.resume()
                    directorySource = source
                }
            } catch { lastError = error.localizedDescription }
        }
        importPending(reportFailures: true)
        publishNow()
    }

    func importPending(reportFailures: Bool = false) {
        guard let shared else { return }
        var failure: String?
        do {
            for package in try shared.pendingPackages() {
                do {
                    let request = try shared.request(in: package)
                    _ = try app.store.importCapture(request, package: package, style: app.defaultStyle)
                    try shared.acknowledge(package: package)
                } catch { failure = error.localizedDescription }
            }
        } catch { failure = error.localizedDescription }
        lastError = failure
        if reportFailures { app.captureImportError = failure }
        publishNow()
    }

    func useCurrentNoteInWidget() {
        guard let id = app.activeNoteID else { return }
        app.widgetNoteID = id
        publishNow()
    }

    func schedulePublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.publishNow()
        }
    }

    func snapshot() -> SharedLibrarySnapshot {
        let chosen = app.widgetNoteID.flatMap { app.store.notes[$0] }
            ?? app.store.pinnedNotes.first ?? app.store.notes(in: nil).first
        let projection = chosen.map { note in
            let style = app.resolvedStyle(for: note)
            let checklist = note.document.blocks.enumerated().filter { $0.element.kind == .checklist }.prefix(12).map {
                WidgetChecklistItem(id: $0.offset, text: $0.element.plainText, checked: $0.element.checked ?? false)
            }
            return WidgetNoteSnapshot(id: note.id, title: note.displayTitle, text: String(note.document.bodyText.prefix(1200)),
                                      checklist: checklist, background: style.theme.background, foreground: style.theme.text,
                                      accent: style.nsAccent.hexRGB, updated: note.modified)
        }
        return SharedLibrarySnapshot(notebooks: app.store.sortedNotebooks.map { NotebookOption(id: $0.id, name: $0.name) }, note: projection)
    }

    func publishNow() {
        guard let shared else { return }
        let snapshot = snapshot()
        guard snapshot != lastPublished else { return }
        do {
            try shared.publish(snapshot)
            lastPublished = snapshot
            reloadWidgets()
        } catch { lastError = error.localizedDescription }
    }
}

extension Notification.Name {
    static let notasCaptureReady = Notification.Name("com.stephenlopez.notas.capture-ready")
}

private extension NSColor {
    var hexRGB: UInt32 {
        guard let rgb = usingColorSpace(.sRGB) else { return 0x8B7CFF }
        return UInt32((rgb.redComponent * 255).rounded()) << 16 | UInt32((rgb.greenComponent * 255).rounded()) << 8 | UInt32((rgb.blueComponent * 255).rounded())
    }
}
