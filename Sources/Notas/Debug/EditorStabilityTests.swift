#if DEBUG
import AppKit

@MainActor
enum EditorStabilityTests {
    static func run() async -> Bool {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notas-editor-stability-\(UUID().uuidString)", isDirectory: true)
        let suite = "notas.editor.stability.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        var failures: [String] = []
        do { try await lifecycle(root: root, suite: suite) } catch { failures.append(error.localizedDescription) }
        do { try pasteAndDividers() } catch { failures.append(error.localizedDescription) }
        do { try indentation(root: root) } catch { failures.append(error.localizedDescription) }
        do { try emptyTrailingBlocks(root: root) } catch { failures.append(error.localizedDescription) }
        if failures.isEmpty {
            print("✓ editor stability checks passed")
            return true
        }
        print("✗ editor stability failed: \(failures.joined(separator: " | "))")
        return false
    }

    private static func lifecycle(root: URL, suite: String) async throws {
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        store.load()
        let app = AppState(store: store, preferences: UserDefaults(suiteName: suite))
        app.archiveDeletedNoteChat = { _ in }
        let kept = store.createNote(in: nil)
        store.updateDocument(kept.id, titled("Keep"))
        app.open(kept.id)

        let note = store.createNote(in: nil)
        app.open(note.id, newTab: true)
        let view = host()
        let editor = NoteEditorView.Coordinator(noteID: note.id, app: app)
        editor.mount(view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("Do not lose 🐈", replacementRange: NSRange(location: 0, length: 0))
        app.close(note.id)
        let _: Bool = store.flush()
        let reloaded = LibraryStore(rootURL: store.rootURL)
        reloaded.load()
        try check(reloaded.notes[note.id]?.document.title == "Do not lose 🐈", "close, flush, and reload keep Do not lose 🐈")

        let again = host()
        let older = NoteEditorView.Coordinator(noteID: note.id, app: app)
        older.mount(again)
        again.insertText("OLD", replacementRange: NSRange(location: 0, length: (again.string as NSString).length))
        let newerView = host()
        let newer = NoteEditorView.Coordinator(noteID: note.id, app: app)
        newer.mount(newerView)
        newerView.setSelectedRange(NSRange(location: 0, length: (newerView.string as NSString).length))
        newerView.insertText("Do not lose 🐈", replacementRange: newerView.selectedRange())
        older.dismantle()
        app.open(note.id)
        try check(app.checkpointForQuit(), "the current registration can still checkpoint")
        let _: Bool = store.flush()
        let afterTeardown = LibraryStore(rootURL: store.rootURL)
        afterTeardown.load()
        try check(afterTeardown.notes[note.id]?.document.title == "Do not lose 🐈", "an old teardown cannot replace the newer registration")

        let other = store.createNote(in: nil)
        store.updateDocument(other.id, titled("Other"))
        app.open(other.id, newTab: true)
        let bound = host()
        let boundEditor = NoteEditorView.Coordinator(noteID: note.id, app: app)
        boundEditor.mount(bound)
        bound.setSelectedRange(NSRange(location: 0, length: (bound.string as NSString).length))
        bound.insertText("Do not lose 🐈", replacementRange: bound.selectedRange())
        try check(app.checkpointForQuit(), "checkpoint uses the bound note")
        try check(store.notes[note.id]?.document.title == "Do not lose 🐈", "the bound editor writes its own note")
        try check(store.notes[other.id]?.document.title == "Other", "activeNoteID is not paired with another editor")

        app.open(note.id)
        app.activate(other.id)
        try check(store.notes[note.id]?.document.title == "Do not lose 🐈", "activation keeps the edited title")

        app.open(note.id)
        app.delete(note.id)
        let trashed = try String(contentsOf: find("Do not lose 🐈", under: root) ?? URL(fileURLWithPath: "/missing"), encoding: .utf8)
        try check(trashed.contains("Do not lose 🐈"), "deletion keeps the typed title in Trash")
        try check(store.notes[other.id]?.document.title == "Other", "deleting one note leaves the other")
    }

    private static func pasteAndDividers() throws {
        let table = Block(kind: .table, runs: [], payload: BlockPayload(table: TableData(rows: [["VALUABLE DATA"]], header: false)))
        let fixture = NoteDocument(blocks: [text(.title, "T"), table, text(.body, "After")])
        let before = paste("hello", at: 2, into: fixture)
        let after = paste("hello", at: 3, into: fixture)
        try check(labels(before) == ["T", "hello", "table", "After"], "paste beside the table at offset 2 yields [T, hello, table, After]")
        try check(labels(after) == ["T", "table", "hello", "After"], "paste beside the table at offset 3 yields [T, table, hello, After]")
        try check(before.blocks[2].payload?.table?.rows == [["VALUABLE DATA"]], "the table still holds VALUABLE DATA")
        try check(after.blocks[1].payload?.table?.rows == [["VALUABLE DATA"]], "the later paste still holds VALUABLE DATA")

        let separator = host()
        separator.load(fixture)
        grouped(separator) {
            separator.setSelectedRange(NSRange(location: 1, length: 1))
            separator.delete(nil)
        }
        try check(labels(separator.document) == ["T", "table", "After"], "deleting only the preceding separator keeps [T, table, After]")

        let saved = paste("hello", at: 2, into: fixture)
        let view = host()
        view.undoManager?.groupsByEvent = false
        view.load(fixture)
        _ = paste("hello", at: 2, into: fixture, view: view)
        let pasted = view.document
        view.undoManager?.undo()
        try check(view.document == fixture, "undo restores the table fixture")
        view.undoManager?.redo()
        try check(view.document == pasted && pasted == saved, "redo restores [T, hello, table, After]")

        let valuable = NoteDocument(blocks: [text(.title, "T"), text(.body, "VALUABLE DATA"), text(.body, "After")])
        let board = dividerBoard()
        let atStart = pasteDivider(at: 2, into: valuable, board: board)
        let atFour = pasteDivider(at: 4, into: valuable, board: board)
        try check(labels(atStart) == ["T", "divider", "VALUABLE DATA", "After"], "a divider at the body start yields [T, divider, VALUABLE DATA, After]")
        try check(labels(atFour) == ["T", "VA", "divider", "LUABLE DATA", "After"], "a divider at offset 4 yields [T, VA, divider, LUABLE DATA, After]")
        let dividerView = host()
        dividerView.undoManager?.groupsByEvent = false
        _ = pasteDivider(at: 4, into: valuable, board: board, view: dividerView)
        let split = dividerView.document
        dividerView.undoManager?.undo()
        try check(dividerView.document == valuable, "undo restores VALUABLE DATA")
        dividerView.undoManager?.redo()
        try check(dividerView.document == split, "redo restores the divider split")
    }

    private static func indentation(root: URL) throws {
        try check(NoteDocument.normalizedIndent(Int.max) == 4, "Int.max indent clamps to 4")
        try check(NoteDocument.normalizedIndent(Int.min) == 0, "a negative indent clamps to 0")
        try check(NoteDocument.indent(applying: 1, to: Int.max) == 4, "Tab after Int.max stays at 4")
        try check(NoteDocument.indent(applying: -1, to: Int.max) == 3, "Backtab after Int.max yields 3")
        try check(NoteDocument.indent(applying: 1, to: 0) == 1, "an empty list indents from 0 to 1")

        let memory = NoteDocument(blocks: [Block(kind: .bullet, indent: Int.max, runs: [InlineRun(text: "Item")])])
        let clamped = memory.normalizingExternalIndentation()
        try check(clamped.blocks[0].plainText == "Item" && clamped.blocks[0].indent == 4, "imported Item with Int.max indent clamps to 4")

        let wide = NoteDocument(blocks: [Block(kind: .bullet, indent: 1_000_000, runs: [InlineRun(text: "Item")])])
        let wideData: Data
        do { wideData = try JSONEncoder().encode(wide) } catch { throw EditorStabilityFailure("encode note: \(error.localizedDescription)") }
        let decoded: NoteDocument
        do { decoded = try JSONDecoder().decode(NoteDocument.self, from: wideData) } catch { throw EditorStabilityFailure("decode note: \(error) \(String(decoding: wideData, as: UTF8.self))") }
        try check(decoded.blocks[0].plainText == "Item" && decoded.blocks[0].indent == 4, "library input clamps Item to indent 4")

        let view = host()
        view.load(NoteDocument(blocks: [text(.title, "T"), Block(kind: .bullet, indent: 1, runs: [InlineRun(text: "Item")])]))
        let itemRange = NSRange(location: 2, length: max(0, (view.string as NSString).length - 2))
        view.textStorage?.addAttribute(.notasIndent, value: Int.max, range: itemRange)
        grouped(view) {
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.insertTab(nil)
        }
        try check(view.document.blocks.last?.plainText == "Item" && view.document.blocks.last?.indent == 4, "Tab on Item stays at indent 4")
        grouped(view) { view.insertBacktab(nil) }
        try check(view.document.blocks.last?.plainText == "Item" && view.document.blocks.last?.indent == 3, "Backtab on Item yields indent 3")

        let empty = host()
        empty.load(NoteDocument(blocks: [text(.title, "T"), Block(kind: .bullet, runs: [])]))
        grouped(empty) {
            empty.setSelectedRange(NSRange(location: (empty.string as NSString).length, length: 0))
            empty.insertTab(nil)
        }
        try check(empty.document.blocks.last?.kind == .bullet && empty.document.blocks.last?.indent == 1, "Tab on an empty list item indents to 1")

        let store = LibraryStore(rootURL: root.appendingPathComponent("portable"))
        store.load()
        let note = store.createNote(in: nil)
        store.updateDocument(note.id, NoteDocument(blocks: [text(.title, "T"), Block(kind: .bullet, indent: 1, runs: [InlineRun(text: "Item")])]))
        let shared = try SharedNoteFile(note: store.notes[note.id]!, resolved: ResolvedStyle(style: note.style, systemIsDark: false, appAccent: .violet), assets: store.assets(for: note.id), notebook: nil)
        var encoded = String(decoding: try LibraryStore.encoder.encode(shared), as: UTF8.self)
        encoded = encoded.replacingOccurrences(of: "\"indent\":1", with: "\"indent\":1000000")
        let url = root.appendingPathComponent("huge.notasnote")
        try Data(encoded.utf8).write(to: url)
        let imported: SharedNoteFile
        do { imported = try SharedNoteFile.read(from: url) } catch { throw EditorStabilityFailure("portable: \(error) bytes \(encoded.prefix(400))") }
        let item = imported.content.document.blocks.first { $0.kind == .bullet }
        try check(item?.plainText == "Item" && item?.indent == 4, "a portable note clamps Item to indent 4")

        let board = NSPasteboard(name: .init("notas.editor.indent"))
        board.clearContents()
        board.setData(wideData, forType: .notasBlocks)
        let clip = host()
        clip.load(NoteDocument(blocks: [text(.title, "T"), text(.body, "OLD")]))
        let old = (clip.string as NSString).range(of: "OLD")
        grouped(clip) {
            clip.setSelectedRange(old)
            _ = clip.readSelection(from: board, type: .notasBlocks)
        }
        let pasted = clip.document.blocks.first { $0.kind == .bullet }
        try check(pasted?.plainText == "Item" && pasted?.indent == 4, "clipboard input clamps Item to indent 4, got \(labels(clip.document)) \(clip.document.blocks.map { $0.indent ?? -1 })")
    }

    private static func emptyTrailingBlocks(root: URL) throws {
        let title = titled("T")
        let cases: [(String, NoteDocument)] = [
            ("checklist", NoteDocument(blocks: [text(.title, "T"), Block(kind: .checklist, checked: false, runs: [])])),
            ("heading", NoteDocument(blocks: [text(.title, "T"), Block(kind: .heading1, runs: [])])),
            ("bullet", NoteDocument(blocks: [text(.title, "T"), Block(kind: .bullet, runs: [])]))
        ]
        let store = LibraryStore(rootURL: root.appendingPathComponent("blocks"))
        store.load()
        for (label, expected) in cases {
            let round = RichTextCodec.document(from: RichTextCodec.attributedString(from: expected))
            try check(round == expected, "\(label) round-trips as \(labels(expected))")
            let note = store.createNote(in: nil)
            store.updateDocument(note.id, expected)
            let _: Bool = store.flush()
            let reloaded = LibraryStore(rootURL: store.rootURL)
            reloaded.load()
            try check(reloaded.notes[note.id]?.document == expected, "reopen keeps \(labels(expected))")

            let view = host()
            view.undoManager?.groupsByEvent = false
            view.load(title)
            view.applyAssistantDocument(expected)
            try check(view.document == expected, "accepting an empty \(label) yields \(labels(expected))")
            let board = NSPasteboard(name: .init("notas.editor.\(label)"))
            board.clearContents()
            view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
            _ = view.writeSelection(to: board, type: .notasBlocks)
            _ = view.writeSelection(to: board, type: .string)
            let json = String(decoding: board.data(forType: .notasBlocks) ?? Data(), as: UTF8.self)
            let plain = board.string(forType: .string) ?? ""
            try check(!json.contains("terminal") && !plain.contains("notas.terminal"), "the \(label) clipboard has no terminal marker")
            view.undoManager?.undo()
            try check(view.document == title, "undo restores [title T] after \(label)")
        }
        let newline = NoteDocument(blocks: [text(.title, "T"), text(.body, "Line"), text(.body, "")])
        let round = RichTextCodec.document(from: RichTextCodec.attributedString(from: newline))
        try check(round.blocks.map(\.kind) == [.title, .body, .body], "an ordinary trailing newline stays a body block")
    }

    private static func paste(_ text: String, at location: Int, into document: NoteDocument, view: NotasTextView? = nil) -> NoteDocument {
        let editor = view ?? host()
        if view == nil || editor.string.isEmpty { editor.load(document) }
        return grouped(editor) {
            editor.setSelectedRange(NSRange(location: location, length: 0))
            let board = NSPasteboard(name: .init("notas.editor.paste"))
            board.clearContents()
            board.setString(text, forType: .string)
            _ = editor.readSelection(from: board, type: .string)
            return editor.document
        }
    }

    private static func pasteDivider(at location: Int, into document: NoteDocument, board: NSPasteboard, view: NotasTextView? = nil) -> NoteDocument {
        let editor = view ?? host()
        editor.load(document)
        return grouped(editor) {
            editor.setSelectedRange(NSRange(location: location, length: 0))
            _ = editor.readSelection(from: board, type: .notasBlocks)
            return editor.document
        }
    }

    private static func grouped<T>(_ view: NotasTextView, _ body: () -> T) -> T {
        view.undoManager?.groupsByEvent = false
        view.undoManager?.beginUndoGrouping()
        let value = body()
        view.undoManager?.endUndoGrouping()
        return value
    }

    private static func dividerBoard() -> NSPasteboard {
        let source = host()
        source.load(NoteDocument(blocks: [text(.title, "S"), Block(kind: .divider, runs: []), text(.body, "tail")]))
        let range = (source.string as NSString).range(of: RichTextCodec.dividerCharacter)
        source.setSelectedRange(range)
        let board = NSPasteboard(name: .init("notas.editor.divider"))
        board.clearContents()
        _ = source.writeSelection(to: board, type: .notasBlocks)
        return board
    }

    private static func host() -> NotasTextView {
        let view = NotasTextView.make()
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return view
    }

    private static func titled(_ title: String) -> NoteDocument {
        NoteDocument(blocks: [text(.title, title)])
    }

    private static func text(_ kind: BlockKind, _ value: String) -> Block {
        Block(kind: kind, runs: [InlineRun(text: value)])
    }

    private static func labels(_ document: NoteDocument) -> [String] {
        document.blocks.map { block in
            if block.kind == .table { return "table" }
            if block.kind == .divider { return "divider" }
            return block.plainText
        }
    }

    private static func find(_ needle: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator {
            guard url.pathExtension == "json" || url.pathExtension == "notas" else { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(needle) { return url }
        }
        return nil
    }

    private static func check(_ condition: Bool, _ label: String) throws {
        if !condition { throw EditorStabilityFailure(label) }
    }
}

private struct EditorStabilityFailure: LocalizedError {
    let label: String
    init(_ label: String) { self.label = label }
    var errorDescription: String? { label }
}
#endif
