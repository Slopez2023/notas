#if DEBUG || BENCH
import AppKit
import Foundation

/// Headless timings for the paths that run while writing: loading, saving, search,
/// and the editor's per-edit work. Run with `Notas --bench` (see `scripts/bench.sh`,
/// which builds release so the numbers mean something).
@MainActor
enum Benchmark {
    private static var sink = 0

    static func run() {
        _ = NSApplication.shared
        print("Notas benchmark (\(optimization))")
        library()
        editor()
        photos()
    }

    private static var optimization: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private static func time(_ label: String, runs: Int = 5, _ body: () -> Void) {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print(String(format: "  %-44@ %9.2f ms", label as NSString, median))
    }

    @inline(never)
    private static func consume(_ notes: [Note]) {
        sink ^= notes.first?.id.hashValue ?? 0
    }

    private static let words = "the quick brown fox jumps over a lazy dog while thinking about dinner plans for lisbon in spring and other small things".split(separator: " ").map(String.init)

    private static func sentence(_ seed: Int, count: Int = 12) -> String {
        (0..<count).map { words[($0 &* 7 &+ seed) % words.count] }.joined(separator: " ")
    }

    static func document(paragraphs: Int, sketchPoints: Int = 0) -> NoteDocument {
        var blocks = [Block(kind: .title, runs: [InlineRun(text: "Benchmark note \(paragraphs)")])]
        let kinds: [BlockKind] = [.body, .bullet, .numbered, .checklist, .body, .heading2, .body, .quote]
        for i in 0..<paragraphs {
            let kind = kinds[i % kinds.count]
            blocks.append(Block(kind: kind, checked: kind == .checklist ? i % 3 == 0 : nil, runs: [
                InlineRun(text: sentence(i)),
                InlineRun(text: " " + sentence(i + 3, count: 3), marks: .bold),
                InlineRun(text: " " + sentence(i + 5, count: 6)),
            ]))
        }
        if sketchPoints > 0 {
            let points = (0..<sketchPoints).flatMap { i in [Double(i) * 0.37 + 0.123456789, sin(Double(i) / 9) * 80 + 100.987654321] }
            blocks.append(Block(kind: .sketch, runs: [], payload: BlockPayload(sketch: SketchData(
                width: 640, height: 260, strokes: [SketchStroke(tool: .pen, color: nil, size: 2.8, points: points)]))))
        }
        return NoteDocument(blocks: blocks)
    }

    // MARK: Library

    private static func library() {
        print("Library")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notas-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let seeded = LibraryStore(rootURL: dir)
        seeded.load()
        let notebook = seeded.sortedNotebooks[0].id
        for i in 0..<1000 {
            let note = seeded.createNote(in: notebook)
            seeded.updateDocument(note.id, document(paragraphs: 30 + i % 40))
            if i % 5 == 0 { seeded.addTag("tag\(i % 17)", to: note.id) }
        }
        seeded.flush()

        let size = directorySize(dir)
        print(String(format: "  %-44@ %9.2f MB", "1000 notes on disk" as NSString, Double(size) / 1_000_000))

        time("load 1000 notes", runs: 3) {
            let store = LibraryStore(rootURL: dir)
            store.load()
        }

        let store = LibraryStore(rootURL: dir)
        store.load()
        time("search \"fox\" (1000 notes)") { _ = store.search("fox") }
        time("search \"quick brown\" (1000 notes)") { _ = store.search("quick brown") }
        time("recent 5, full-sort baseline", runs: 50) {
            consume(Array(store.notes.values.sorted { $0.modified > $1.modified }.prefix(5)))
        }
        time("recent 5 (menu query)", runs: 50) { consume(store.search("", limit: 5).map(\.note)) }
        time("menu recents, previous repeated queries", runs: 50) {
            let recent = store.search("", limit: 5).map(\.note)
            consume(recent)
            for note in recent {
                let matches = store.search("", limit: 5).map(\.note).filter { $0.displayTitle == note.displayTitle }
                sink ^= matches.count
            }
        }
        time("menu recents, one snapshot", runs: 50) {
            let recent = store.search("", limit: 5).map(\.note)
            consume(recent)
            for note in recent { sink ^= recent.filter { $0.displayTitle == note.displayTitle }.count }
        }
        time("list all notes sorted") { _ = store.notes(in: nil) }
        time("pinned + counts (sidebar rail)") {
            _ = store.pinnedNotes
            for nb in store.notebooks { _ = store.count(in: nb.id) }
        }
        time("all tags") { _ = store.allTags }

        let drawer = store.notes(in: nil)
        time("group + previews, 1000 rows") {
            for (_, items) in NotebookDrawer.group(drawer) { for note in items { _ = note.preview } }
        }

        let big = document(paragraphs: 400, sketchPoints: 6000)
        let note = Note(id: UUID(), notebookID: notebook, tags: [], created: Date(), modified: Date(), pinned: false, style: NoteStyle(), document: big)
        var encoded = Data()
        time("encode note (400 paras + 6k-point sketch)") { encoded = (try? LibraryStore.encoder.encode(note)) ?? Data() }
        print(String(format: "  %-44@ %9.2f KB", "  encoded size" as NSString, Double(encoded.count) / 1000))
        time("decode same note") { _ = try? LibraryStore.decoder.decode(Note.self, from: encoded) }
        time("document equality (no change)") { _ = big == big }
        var edited = big
        edited.blocks[edited.blocks.count / 2].runs[0].text += "!"
        time("document equality (changed mid-note)") { _ = big == edited }
    }

    private static func directorySize(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return e.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)
    }

    // MARK: Photos

    private static func photos() {
        print("Photos")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notas-bench-photo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 12 MP photo-like JPEG: smooth gradients plus noise.
        let width = 4032, height = 3024
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            var seed: UInt32 = 12345
            for y in 0..<height {
                for x in 0..<width {
                    seed = seed &* 1664525 &+ 1013904223
                    let i = (y * width + x) * 4
                    let noise = UInt8(truncatingIfNeeded: seed >> 28)
                    pixels[i] = UInt8(truncatingIfNeeded: x / 16) &+ noise
                    pixels[i + 1] = UInt8(truncatingIfNeeded: y / 12) &+ noise
                    pixels[i + 2] = UInt8(truncatingIfNeeded: (x + y) / 24) &+ noise
                    pixels[i + 3] = 255
                }
            }
        }
        let source = dir.appendingPathComponent("photo.jpg")
        if let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            try? data.write(to: source)
            print(String(format: "  %-44@ %9.2f MB", "source photo (12 MP JPEG)" as NSString, Double(data.count) / 1_000_000))
        }

        let assets = NoteAssets(package: dir.appendingPathComponent("note.notas"))
        var names: [String] = []
        time("import photo into note", runs: 3) { names.append(contentsOf: (try? assets.importFile(source)) ?? []) }
        if let name = names.last, let url = assets.url(for: name), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            print(String(format: "  %-44@ %9.2f MB", "  stored copy" as NSString, Double(size) / 1_000_000))
        }
        if let name = names.last, let url = assets.url(for: name) {
            // Before the cache, every redraw of a gallery decoded the full file: ~200 ms for this one.
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var loaded: NSImage?
            time("gallery tile, first load (cache miss)", runs: 1) {
                Task.detached { loaded = await PhotoCache.load(url, maxPixel: 1400); semaphore.signal() }
                semaphore.wait()
            }
            time("gallery tile, every redraw after (cache hit)") { loaded = PhotoCache.cached(url, maxPixel: 1400) }
            print(String(format: "  %-44@ %9d px", "  decoded size (longest side)" as NSString, Int(max(loaded?.size.width ?? 0, loaded?.size.height ?? 0))))
        }
    }

    // MARK: Editor

    private static func editor() {
        print("Editor")
        for paragraphs in [50, 400, 2000] {
            let doc = document(paragraphs: paragraphs)
            print("  — \(paragraphs) paragraphs")
            let tv = NotasTextView.make()
            tv.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            time("    load + style") { tv.load(doc) }
            time("    capture document (save debounce)") { _ = tv.document }
            time("    flush restyle (one keystroke)") {
                tv.insertText("x", replacementRange: NSRange(location: tv.string.utf16.count / 2, length: 0))
                tv.flushRestyle()
            }
            time("    connectRichBlocks (per keystroke)") { tv.connectRichBlocks() }
            time("    restyleAll (theme change)", runs: 3) { tv.restyleAll() }
        }

        let list = NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "List")])] +
            (0..<1000).map { Block(kind: .numbered, runs: [InlineRun(text: sentence($0, count: 5))]) })
        let tv = NotasTextView.make()
        tv.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        tv.load(list)
        time("  keystroke in 1000-item numbered list") {
            tv.insertText("x", replacementRange: NSRange(location: 40, length: 0))
            tv.flushRestyle()
        }

    }
}
#endif
