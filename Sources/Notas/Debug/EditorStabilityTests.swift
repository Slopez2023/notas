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
        do { try separatorBlockChange() } catch { failures.append(error.localizedDescription) }
        do { try inlinePasteKeepsBlock() } catch { failures.append(error.localizedDescription) }
        do { try carriedColors() } catch { failures.append(error.localizedDescription) }
        do { try slashMatching() } catch { failures.append(error.localizedDescription) }
        do { try openableLinks() } catch { failures.append(error.localizedDescription) }
        do { try indentation(root: root) } catch { failures.append(error.localizedDescription) }
        do { try emptyTrailingBlocks(root: root) } catch { failures.append(error.localizedDescription) }
        do { try await photos(root: root) } catch { failures.append(error.localizedDescription) }
        do { try tableFocus() } catch { failures.append(error.localizedDescription) }
        do { try pastedLines() } catch { failures.append(error.localizedDescription) }
        do { try titleSelectionPaste() } catch { failures.append(error.localizedDescription) }
        do { try typedIntoTrailingLine(root: root) } catch { failures.append(error.localizedDescription) }
        do { try inlinePrediction(root: root, suite: suite) } catch { failures.append(error.localizedDescription) }
        do { try await reloadsMergedText(root: root, suite: suite) } catch { failures.append(error.localizedDescription) }
        do { try richBlocks(root: root) } catch { failures.append(error.localizedDescription) }
        do { try scrollBackIntoView() } catch { failures.append(error.localizedDescription) }
        do { try pasteTextOverImage(root: root) } catch { failures.append(error.localizedDescription) }
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

    private static func separatorBlockChange() throws {
        let view = host()
        view.undoManager?.groupsByEvent = false
        view.load(NoteDocument(blocks: [text(.title, "T"), Block(kind: .divider, runs: []), Block(kind: .bullet, runs: []), text(.body, "After")]))
        let divider = (view.string as NSString).range(of: RichTextCodec.dividerCharacter).location
        grouped(view) {
            view.setSelectedRange(NSRange(location: divider + 2, length: 0))
            view.setBlockKind(.body)
        }
        try check(labels(view.document) == ["T", "divider", "", "After"], "an empty bullet under a divider keeps its place, got \(labels(view.document))")
        try check(view.document.blocks[2].kind == .body, "turning the empty bullet under a divider into text is not rejected")
    }

    private static func inlinePasteKeepsBlock() throws {
        let checklist = NoteDocument(blocks: [text(.title, "T"), Block(kind: .checklist, checked: false, runs: [InlineRun(text: "Buy milk")])])
        let typed = paste("Hello ", at: 2, into: checklist)
        try check(typed.blocks[1].kind == .checklist && typed.blocks[1].plainText == "Hello Buy milk", "pasted text keeps the checklist, got \(typed.blocks[1].kind) \(typed.blocks[1].plainText)")

        let view = host()
        view.load(checklist)
        let board = fragmentBoard("Hello ")
        let pasted = grouped(view) {
            view.setSelectedRange(NSRange(location: 2, length: 0))
            _ = view.readSelection(from: board, type: .notasBlocks)
            return view.document
        }
        try check(pasted.blocks[1].kind == .checklist && pasted.blocks[1].plainText == "Hello Buy milk", "a pasted body fragment keeps the checklist, got \(pasted.blocks[1].kind) \(pasted.blocks[1].plainText)")
    }

    private static func carriedColors() throws {
        let inked = host()
        inked.load(NoteDocument(blocks: [text(.title, "T"), Block(kind: .body, runs: [InlineRun(text: "Red", ink: .red)])]))
        let inkEnd = (inked.string as NSString).length
        inked.setSelectedRange(NSRange(location: inkEnd, length: 0))
        inked.insertText(" more", replacementRange: NSRange(location: NSNotFound, length: 0))
        let inkStorage = inked.textStorage
        try check(inkStorage?.attribute(.notasInk, at: inkEnd, effectiveRange: nil) as? String == InkColor.red.rawValue
            && inkStorage?.attribute(.notasInk, at: inkEnd + 4, effectiveRange: nil) as? String == InkColor.red.rawValue, "typing after red ink keeps the red")

        let marked = host()
        marked.load(NoteDocument(blocks: [text(.title, "T"), Block(kind: .body, runs: [InlineRun(text: "Mark", marks: [.highlight], highlightColor: .yellow)])]))
        let markEnd = (marked.string as NSString).length
        marked.setSelectedRange(NSRange(location: markEnd, length: 0))
        marked.insertText(" more", replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(marked.textStorage?.attribute(.notasHighlightColor, at: markEnd + 4, effectiveRange: nil) as? String == InkColor.yellow.rawValue, "typing after a yellow highlight keeps the highlight color")
    }

    private static func slashMatching() throws {
        try check(SlashItem.matching("tareas").first?.id == "check", "the slash query tareas finds the checklist first")
        try check(SlashItem.matching("titulo").first?.id == "h1", "the slash query titulo finds the heading first")
        try check(SlashItem.matching("Título").first?.id == "h1", "the slash query Título ignores case and accents")
        try check(SlashItem.matching("lista").contains { $0.id == "bullet" }, "the slash query lista finds the bulleted list")
    }

    private static func openableLinks() throws {
        try check(OpenableLink.url(from: "https://example.com/a")?.absoluteString == "https://example.com/a", "an https link opens as written")
        try check(OpenableLink.url(from: "example.com")?.absoluteString == "https://example.com", "a bare host becomes https")
        try check(OpenableLink.url(from: URL(string: "mailto:hi@example.com"))?.scheme == "mailto", "a mailto link is allowed")
        try check(OpenableLink.url(from: "http://example.com")?.scheme == "http", "an http link is allowed")
        try check(OpenableLink.url(from: "file:///etc/hosts") == nil, "a file link is rejected")
        try check(OpenableLink.url(from: "javascript://example.com/%0Aalert(1)") == nil, "a javascript link is rejected")
        try check(OpenableLink.url(from: "notas://open") == nil, "a notas link is rejected")
        try check(OpenableLink.url(from: "") == nil, "an empty link is rejected")
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

    private static func photos(root: URL) async throws {
        let assets = NoteAssets(package: root.appendingPathComponent("photos.notas"))
        let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5000, pixelsHigh: 3000, bitsPerSample: 8, samplesPerPixel: 3,
                                      hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let big = NSImage(size: NSSize(width: 5000, height: 3000))
        if let opaque { big.addRepresentation(opaque) }
        let bigName = try assets.importImage(big)
        let bigSource = CGImageSourceCreateWithURL(assets.url(for: bigName)! as CFURL, nil)
        let bigProps = bigSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
        let bigLongest = max(bigProps?[kCGImagePropertyPixelWidth] as? Int ?? 0, bigProps?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        try check(bigName.hasSuffix(".jpg") && bigLongest == NoteAssets.maxStoredPixels, "pasted opaque image is downsampled to \(NoteAssets.maxStoredPixels) JPEG (got \(bigName) \(bigLongest))")

        let alpha = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let small = NSImage(size: NSSize(width: 64, height: 48))
        if let alpha { small.addRepresentation(alpha) }
        let smallName = try assets.importImage(small)
        try check(smallName.hasSuffix(".png"), "pasted image with transparency stays PNG (got \(smallName))")

        let late = root.appendingPathComponent("late.png")
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:])
        try check(png != nil, "test photo is created")
        Task.detached { try? await Task.sleep(for: .milliseconds(100)); try? png?.write(to: late) }
        let retried = await PhotoCache.loadWhenAvailable(late, maxPixel: 20, backoff: [0.5], isUbiquitous: { _ in true })
        try check(max(retried?.size.width ?? 0, retried?.size.height ?? 0) == 20, "a photo that arrives during the iCloud backoff loads on retry")
        let missing = await PhotoCache.loadWhenAvailable(root.appendingPathComponent("never.png"), maxPixel: 20, backoff: [0.01], isUbiquitous: { _ in false })
        try check(missing == nil, "a missing local photo is not retried")
    }

    private static func tableFocus() throws {
        var focused = 0
        let input = BlockInput(text: .constant(""), style: ResolvedStyle(style: NoteStyle(), systemIsDark: true, appAccent: .violet), label: "cell", onFocus: { focused += 1 })
        input.makeCoordinator().controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: NSTextField()))
        try check(focused == 1, "a cell that starts editing reports focus so Tab can continue from it")
    }

    private static func pastedLines() throws {
        let heading = NoteDocument(blocks: [text(.title, "T"), text(.heading1, "Head")])
        let headed = paste("one\ntwo\nthree", at: 6, into: heading)
        try check(labels(headed) == ["T", "Headone", "two", "three"] && headed.blocks.map(\.kind) == [.title, .heading1, .body, .body], "multi-line paste keeps the heading on the first line only, got \(labels(headed)) \(headed.blocks.map(\.kind))")

        let list = NoteDocument(blocks: [text(.title, "T"), Block(kind: .bullet, indent: 1, runs: [InlineRun(text: "Item")])])
        let bullets = paste("a\nb", at: 6, into: list)
        try check(labels(bullets) == ["T", "Itema", "b"] && bullets.blocks.map(\.kind) == [.title, .bullet, .bullet] && bullets.blocks.map { $0.indent ?? 0 } == [0, 1, 1], "multi-line paste continues the bullet at indent 1, got \(labels(bullets)) \(bullets.blocks.map { $0.indent ?? 0 })")

        let checklist = NoteDocument(blocks: [text(.title, "T"), Block(kind: .checklist, checked: true, runs: [InlineRun(text: "Task")])])
        let checks = paste("x\ny", at: 6, into: checklist)
        try check(labels(checks) == ["T", "Taskx", "y"] && checks.blocks.map(\.kind) == [.title, .checklist, .checklist] && checks.blocks[2].checked != true, "multi-line paste adds an unchecked checklist item, got \(labels(checks)) \(checks.blocks.map(\.checked))")

        let code = NoteDocument(blocks: [text(.title, "T"), text(.code, "let a = 1")])
        let lines = paste("\nlet b = 2\nlet c = 3", at: 11, into: code)
        try check(lines.blocks.dropFirst().allSatisfy { $0.kind == .code } && lines.blocks.count == 4, "multi-line paste into code stays code, got \(labels(lines)) \(lines.blocks.map(\.kind))")
    }

    private static func titleSelectionPaste() throws {
        let view = host()
        view.load(titled("Hello"))
        view.setSelectedRange(NSRange(location: 1, length: 3))
        grouped(view) { _ = view.readSelection(from: dividerBoard(), type: .notasBlocks) }
        try check(labels(view.document) == ["Ho", "divider"] && view.document.blocks.map(\.kind) == [.title, .divider], "a divider pasted over the title selection leaves [Ho, divider], got \(labels(view.document))")
        let whole = host()
        whole.load(titled("Hello"))
        whole.setSelectedRange(NSRange(location: 0, length: 5))
        grouped(whole) { _ = whole.readSelection(from: dividerBoard(), type: .notasBlocks) }
        try check(labels(whole.document) == ["", "divider"] && whole.document.blocks.map(\.kind) == [.title, .divider], "a divider pasted over the whole title keeps an empty title above it, got \(labels(whole.document))")
    }

    private static func typedIntoTrailingLine(root: URL) throws {
        let view = host()
        view.undoManager?.groupsByEvent = false
        view.load(NoteDocument(blocks: [text(.title, "T"), Block(kind: .checklist, runs: [])]))
        grouped(view) {
            view.setSelectedRange(NSRange(location: (view.string as NSString).length - 1, length: 0))
            view.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let typed = view.document
        try check(labels(typed) == ["T", "abc", ""] && typed.blocks.map(\.kind) == [.title, .checklist, .body], "typing into the last empty checklist keeps the empty line below, got \(labels(typed)) \(typed.blocks.map(\.kind))")

        let store = LibraryStore(rootURL: root.appendingPathComponent("trailing"))
        store.load()
        let note = store.createNote(in: nil)
        store.updateDocument(note.id, typed)
        let _: Bool = store.flush()
        let reloaded = LibraryStore(rootURL: store.rootURL)
        reloaded.load()
        try check(reloaded.notes[note.id]?.document == typed, "reopen keeps the typed line and the empty line below it")
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

    private static func fragmentBoard(_ value: String) -> NSPasteboard {
        let source = host()
        source.load(NoteDocument(blocks: [text(.title, "S"), text(.body, value)]))
        source.setSelectedRange((source.string as NSString).range(of: value))
        let board = NSPasteboard(name: .init("notas.editor.fragment"))
        board.clearContents()
        _ = source.writeSelection(to: board, type: .notasBlocks)
        return board
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

    /// A change from another device merged in by a save shows up in the open, idle editor.
    private static func reloadsMergedText(root: URL, suite: String) async throws {
        let library = root.appendingPathComponent("merged")
        let store = LibraryStore(rootURL: library)
        store.load()
        let app = AppState(store: store, preferences: UserDefaults(suiteName: suite))
        app.archiveDeletedNoteChat = { _ in }
        let note = store.createNote(in: nil)
        store.updateDocument(note.id, NoteDocument(blocks: [text(.title, "Mine"), text(.body, "Old body")]))
        try await store.flush()
        app.open(note.id)
        let view = host()
        let editor = NoteEditorView.Coordinator(noteID: note.id, app: app)
        editor.mount(view)
        view.setSelectedRange(NSRange(location: 2, length: 0))

        var remote = try LibraryStore.decoder.decode(Note.self, from: Data(contentsOf: library.appendingPathComponent("Notes/\(note.id.uuidString).notas/note.json")))
        remote.document = NoteDocument(blocks: [text(.title, "Mine"), text(.body, "Body from the other Mac")])
        try LibraryStore.encoder.encode(remote).write(to: library.appendingPathComponent("Notes/\(note.id.uuidString).notas/note.json"), options: .atomic)
        store.togglePin(note.id)
        try await store.flush()
        try check(view.document.blocks.last?.plainText == "Body from the other Mac", "an idle editor shows text merged from another device")
        try check(view.selectedRange().location == 2, "reloading keeps the caret")
        editor.dismantle()
    }

    /// macOS shows an inline prediction as marked text: what was typed plus gray NSTextCompletion text.
    /// Autosave must leave it alone (committing it moved the caret to the start of the word),
    /// and a forced save keeps only what was typed.
    private static func inlinePrediction(root: URL, suite: String) throws {
        let store = LibraryStore(rootURL: root.appendingPathComponent("prediction"))
        store.load()
        let app = AppState(store: store, preferences: UserDefaults(suiteName: suite))
        app.archiveDeletedNoteChat = { _ in }
        let note = store.createNote(in: nil)
        store.updateDocument(note.id, NoteDocument(blocks: [text(.title, "T"), text(.body, "Happy ")]))
        app.open(note.id)
        let view = host()
        let editor = NoteEditorView.Coordinator(noteID: note.id, app: app)
        editor.mount(view)
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        view.insertText("birthd", replacementRange: NSRange(location: NSNotFound, length: 0))
        let prediction = NSMutableAttributedString(string: "birthd")
        prediction.append(NSAttributedString(string: "ay", attributes: [.textCompletion: 1, .foregroundColor: NSColor.gray]))
        view.setMarkedText(prediction, selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: end, length: 6))
        view.flushRestyle()
        let caret = view.selectedRange()

        editor.saveNow()
        try check(view.hasMarkedText(), "autosave leaves an inline prediction in place")
        try check(view.selectedRange() == caret, "autosave keeps the caret after the typed letters")

        try check(editor.checkpoint(), "a forced save succeeds with a prediction showing")
        try check(store.notes[note.id]?.document.blocks.last?.plainText == "Happy birthd", "a forced save keeps only the typed letters")
        editor.dismantle()
    }

    private static func richBlocks(root: URL) throws {
        let (view, _) = scrolledHost()
        view.load(NoteDocument(blocks: [text(.title, "T"), Block(kind: .body, runs: [])]))
        view.undoManager?.removeAllActions()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.insertRichBlock(.table)
        while (view.undoManager?.groupingLevel ?? 0) > 0 { view.undoManager?.endUndoGrouping() }
        let before = view.document
        let storage = view.textStorage!
        let attachment = storage.attribute(.attachment, at: 2, effectiveRange: nil) as? RichBlockAttachment
        try check(attachment != nil && view.richBlockHosts.count == 1, "table block is mounted before deletion")
        grouped(view) { view.removeRichBlock(attachment!) }
        try check(view.richBlockHosts.isEmpty, "deleting the table unmounts it")
        view.undoManager?.undo()
        try check(view.document == before, "undo restores the deleted table")
        try check(view.richBlockHosts.count == 1, "undo of a block deletion remounts the block without connectRichBlocks")
    }

    private static func scrollBackIntoView() throws {
        let (view, scroll) = scrolledHost()
        let filler = (0..<80).map { Block(kind: .body, runs: [InlineRun(text: "Line \($0)")]) }
        view.load(NoteDocument(blocks: [text(.title, "T")] + filler + [Block(kind: .table, runs: [], payload: .empty(for: .table))]))
        guard let manager = view.textLayoutManager, let content = view.textContentStorage,
              let offset = view.textStorage?.string.utf16.count, offset > 0 else { throw EditorStabilityFailure("editor has TextKit 2 layout") }
        manager.ensureLayout(for: manager.documentRange)
        view.setFrameSize(NSSize(width: 800, height: manager.usageBoundsForTextContainer.maxY + 400))
        let tableIndex = (view.textStorage?.string as NSString?).map { _ in
            (0..<offset).first { view.textStorage?.attribute(.attachment, at: $0, effectiveRange: nil) is RichBlockAttachment } ?? -1
        } ?? -1
        guard tableIndex >= 0, let location = content.location(content.documentRange.location, offsetBy: tableIndex),
              let fragment = manager.textLayoutFragment(for: location) else { throw EditorStabilityFailure("table has a layout fragment") }
        let tableTop = fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y
        let clip = scroll.contentView
        func scrollTo(_ y: CGFloat) throws {
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            view.layoutSubtreeIfNeeded()
        }
        try scrollTo(tableTop - 100)
        let host = view.richBlockHosts.values.first
        try check(host != nil && host?.isHidden == false, "scrolling a table into view shows it without a manual reposition")
        try scrollTo(0)
        try check(host?.isHidden == true, "scrolling the table out of view hides it")
        try scrollTo(tableTop - 100)
        try check(host?.isHidden == false && host.map { view.visibleRect.intersects($0.frame) } == true, "scrolling back shows the table in the visible rect")
        try check(view.observedClipView === clip, "the editor observes the clip view of its scroll view")
        view.removeFromSuperview()
        try check(view.observedClipView == nil, "leaving the scroll view stops observing the clip view")
    }

    private static func scrolledHost() -> (NotasTextView, NSScrollView) {
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let view = NotasTextView.make()
        scroll.documentView = view
        window.contentView = scroll
        view.setFrameSize(NSSize(width: 800, height: 600))
        window.makeFirstResponder(view)
        return (view, scroll)
    }

    private static func pasteTextOverImage(root: URL) throws {
        let view = host()
        view.load(NoteDocument(blocks: [text(.title, "T"), Block(kind: .body, runs: [])]))
        view.noteAssets = NoteAssets(package: root.appendingPathComponent("paste-\(UUID().uuidString).notas", isDirectory: true))
        guard let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]) else { throw EditorStabilityFailure("a tiny PNG can be made") }
        let both = NSPasteboard(name: .init("notas.editor.rich-paste-\(UUID().uuidString)"))
        defer { both.releaseGlobally() }
        both.clearContents()
        both.setString("Pasted words", forType: .string)
        both.setData(png, forType: .png)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        _ = view.readSelection(from: both)
        try check(view.string.contains("Pasted words"), "text on the pasteboard beside an image pastes as text")
        try check(!view.document.blocks.contains { $0.kind == .gallery }, "text beside an image does not paste a gallery")

        let imageOnly = NSPasteboard(name: .init("notas.editor.image-paste-\(UUID().uuidString)"))
        defer { imageOnly.releaseGlobally() }
        imageOnly.clearContents()
        imageOnly.setData(png, forType: .png)
        _ = view.readSelection(from: imageOnly)
        try check(view.document.blocks.contains { $0.kind == .gallery }, "an image-only pasteboard still pastes a photo")
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
