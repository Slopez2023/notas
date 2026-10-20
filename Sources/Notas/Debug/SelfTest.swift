#if DEBUG
import AppKit
import SwiftUI
import PDFKit
import Carbon
#if canImport(NotasShared)
import NotasShared
#endif

/// Headless checks for the codec and editor behavior. Run with `Notas --self-test`
/// (or `scripts/test.sh`). The Command Line Tools ship without XCTest, so this stands in.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var passes = 0

    static func run() -> Bool {
        _ = NSApplication.shared
        codec()
        editor()
        phase2()
        store()
        phase3()
        resizing()
        phase4()
        sharing()
        performance()
        print(failures == 0 ? "✓ \(passes) checks passed" : "✗ \(failures) failed, \(passes) passed")
        return failures == 0
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) {
        do {
            if try condition() { passes += 1 } else { failures += 1; print("FAIL (line \(line)): \(message)") }
        } catch { failures += 1; print("FAIL (line \(line)): \(message): \(error)") }
    }

    // MARK: Codec

    private static func codec() {
        let doc = NoteDocument(blocks: [
            Block(kind: .title, runs: [InlineRun(text: "Lisbon")]),
            Block(kind: .body, runs: [InlineRun(text: "Go "), InlineRun(text: "early", marks: [.bold, .highlight])]),
            Block(kind: .checklist, checked: true, runs: [InlineRun(text: "Flights")]),
            Block(kind: .checklist, checked: false, indent: 1, runs: [InlineRun(text: "Hotel")]),
            Block(kind: .numbered, runs: [InlineRun(text: "One")]),
            Block(kind: .quote, runs: [InlineRun(text: "Saudade", marks: .italic, link: "https://example.com")]),
        ])
        check(RichTextCodec.document(from: RichTextCodec.attributedString(from: doc)) == doc, "round trip keeps blocks and marks")

        let withEmpties = NoteDocument(blocks: [
            Block(kind: .title, runs: [InlineRun(text: "T")]),
            Block(kind: .body, runs: []),
            Block(kind: .bullet, runs: [InlineRun(text: "x")]),
            Block(kind: .body, runs: []),
        ])
        let text = RichTextCodec.attributedString(from: withEmpties)
        check(text.string == "T\n\nx\n", "empty paragraphs become newlines")
        check(RichTextCodec.document(from: text) == withEmpties, "empty paragraphs survive a round trip")

        let headed = NSAttributedString(string: "Hello\nWorld", attributes: [.notasBlock: BlockKind.heading1.rawValue])
        check(RichTextCodec.document(from: headed).blocks.map(\.kind) == [.title, .heading1], "first paragraph is always the title")
        check(RichTextCodec.document(from: NSAttributedString()) == NoteDocument.empty, "empty text is an empty title")

        let item = NSAttributedString(string: "Item", attributes: [.notasBlock: BlockKind.checklist.rawValue, .notasChecked: true])
        check(RichTextCodec.document(from: item, forceTitle: false).blocks == [Block(kind: .checklist, checked: true, runs: [InlineRun(text: "Item")])],
              "clipboard fragments keep their kinds")

        var note = Note.new(in: UUID())
        note.document = WelcomeNote.document
        if let data = try? LibraryStore.encoder.encode(note), let back = try? LibraryStore.decoder.decode(Note.self, from: data) {
            check(back.document == note.document, "note JSON round trip")
        } else {
            check(false, "note JSON encodes and decodes")
        }
    }

    // MARK: Editor

    private static func makeEditor(_ blocks: [Block]) -> NotasTextView {
        let tv = NotasTextView.make()
        tv.load(NoteDocument(blocks: blocks))
        return tv
    }

    static var trace = false
    private static func type(_ tv: NotasTextView, _ s: String) {
        for ch in s {
            if ch == "\n" { tv.insertNewline(nil) } else { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            if trace { print("typed \(ch == "\n" ? "⏎" : String(ch)) → sel \(tv.selectedRange()) \(tv.string.debugDescription)") }
        }
    }

    /// Block kinds, ignoring the empty body line that can trail a note.
    private static func kinds(_ tv: NotasTextView) -> [BlockKind] { trimmed(tv.document).map(\.kind) }

    private static func trimmed(_ doc: NoteDocument) -> [Block] {
        var blocks = doc.blocks
        while blocks.count > 1, let last = blocks.last, last.kind == .body, last.runs.isEmpty { blocks.removeLast() }
        return blocks
    }

    private static func editor() {
        // Typing a title then Return gives a body paragraph.
        var tv = makeEditor([Block(kind: .title, runs: [])])
        type(tv, "Groceries\nmilk")
        check(kinds(tv) == [.title, .body], "Return after title starts body (got \(kinds(tv)))")
        check(tv.document.title == "Groceries", "title text")

        // "[] " makes a checklist, Return continues it, Return on empty exits.
        tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "List")]), Block(kind: .body, runs: [])])
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        type(tv, "[] eggs\nbread\n\nafter")
        check(kinds(tv) == [.title, .checklist, .checklist, .body], "checklist shortcut, continue, exit (got \(kinds(tv)))")
        check(tv.document.blocks[1].plainText == "eggs", "shortcut prefix removed (got '\(tv.document.blocks[1].plainText)')")
        check(tv.document.blocks[3].plainText == "after", "typing after exiting list")

        // Toggling a checkbox.
        tv.toggleChecked(paragraphAt: 6)
        check(tv.document.blocks[1].checked == true, "toggle checks the item")
        tv.toggleChecked(paragraphAt: 6)
        check(tv.document.blocks[1].checked == false, "toggle unchecks the item")

        // Return on a checked item starts an unchecked one.
        tv.toggleChecked(paragraphAt: 6)
        tv.setSelectedRange(NSRange(location: 9, length: 0)) // end of "eggs"
        type(tv, "\nham")
        check(tv.document.blocks[2].plainText == "ham" && tv.document.blocks[2].checked == false,
              "new item after checked item is unchecked (got \(tv.document.blocks.map { "\($0.kind):\($0.plainText):\($0.checked.map(String.init) ?? "-")" }))")

        // Numbered and bullet shortcuts, heading shortcut.
        tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [])])
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        type(tv, "1. one\ntwo\n\n- dot\n\n# Big\nplain")
        check(kinds(tv) == [.title, .numbered, .numbered, .bullet, .heading1, .body], "numbered, bullet, heading shortcuts (got \(kinds(tv)))")

        // Numbering is computed per list.
        if let storage = tv.textStorage {
            let second = (tv.string as NSString).range(of: "two").location
            check(storage.attribute(.notasOrdinal, at: second, effectiveRange: nil) as? Int == 2, "second item is numbered 2")
        }

        // Backspace at start of a list item turns it into body text.
        let dot = (tv.string as NSString).range(of: "dot").location
        tv.setSelectedRange(NSRange(location: dot, length: 0))
        tv.deleteBackward(nil)
        check(tv.document.blocks[3].kind == .body && tv.document.blocks[3].plainText == "dot", "backspace removes list style first")

        // Bold toggling over a selection.
        let plain = (tv.string as NSString).range(of: "plain")
        tv.setSelectedRange(plain)
        tv.toggleMark(.bold)
        check(trimmed(tv.document).last?.runs.first?.marks == [.bold], "bold applied")
        tv.toggleMark(.bold)
        check(trimmed(tv.document).last?.runs.first?.marks == [], "bold removed")

        // Block kind via command, and toggling back.
        tv.setSelectedRange(NSRange(location: plain.location, length: 0))
        tv.setBlockKind(.quote)
        check(trimmed(tv.document).last?.kind == .quote, "set block kind")
        tv.setBlockKind(.quote)
        check(trimmed(tv.document).last?.kind == .body, "same kind toggles back to body")

        // Typing at the start of a paragraph keeps that paragraph's kind.
        tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]),
                         Block(kind: .heading1, runs: [InlineRun(text: "H")]),
                         Block(kind: .checklist, runs: [InlineRun(text: "task")])])
        let task = (tv.string as NSString).range(of: "task").location
        tv.setSelectedRange(NSRange(location: task, length: 0))
        type(tv, "a ")
        check(kinds(tv) == [.title, .heading1, .checklist], "typing at paragraph start keeps its kind (got \(kinds(tv)))")

        // Tab indents list items.
        tv.setSelectedRange(NSRange(location: task, length: 0))
        tv.insertTab(nil)
        check(tv.document.blocks[2].indent == 1, "tab indents a list item")
        tv.insertBacktab(nil)
        check(tv.document.blocks[2].indent == nil, "shift-tab outdents")

        // Undo restores the previous text.
        tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [InlineRun(text: "x")])])
        check(tv.allowsUndo, "undo is enabled")
    }

    // MARK: Phase 2: dividers, colors, slash menu

    private static func phase2() {
        // Codec keeps dividers, highlight colors and ink.
        let doc = NoteDocument(blocks: [
            Block(kind: .title, runs: [InlineRun(text: "T")]),
            Block(kind: .body, runs: [InlineRun(text: "warm", marks: .highlight, highlightColor: .yellow), InlineRun(text: " red", ink: .red)]),
            Block(kind: .divider, runs: []),
            Block(kind: .body, runs: [InlineRun(text: "after")]),
        ])
        check(RichTextCodec.document(from: RichTextCodec.attributedString(from: doc)) == doc, "codec keeps dividers, highlight colors, ink")

        // Insert a divider after a line; cursor lands on a fresh body line below.
        var tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [InlineRun(text: "one")])])
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertDivider()
        type(tv, "two")
        check(kinds(tv) == [.title, .body, .divider, .body], "divider inserted between lines (got \(kinds(tv)))")
        check(trimmed(tv.document).last?.plainText == "two", "typing continues below the divider")

        // Backspace at the start of the line after a divider removes the divider.
        let two = (tv.string as NSString).range(of: "two").location
        tv.setSelectedRange(NSRange(location: two, length: 0))
        tv.deleteBackward(nil)
        check(kinds(tv) == [.title, .body, .body], "backspace after divider removes it (got \(kinds(tv)))")

        // Divider in the middle of text keeps the following paragraph intact.
        tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [InlineRun(text: "a")]),
                         Block(kind: .checklist, runs: [InlineRun(text: "b")])])
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.insertDivider()
        check(kinds(tv) == [.title, .body, .divider, .body, .checklist], "divider mid-document (got \(kinds(tv)))")

        // Highlight with a color, then ink, then remove.
        tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [InlineRun(text: "color me")])])
        let range = (tv.string as NSString).range(of: "color")
        tv.setSelectedRange(range)
        tv.setHighlight(.ink(.green))
        tv.setInk(.purple)
        var run = tv.document.blocks[1].runs.first
        check(run?.marks == .highlight && run?.highlightColor == .green && run?.ink == .purple, "highlight color and ink applied")
        tv.setHighlight(nil)
        tv.setInk(nil)
        run = tv.document.blocks[1].runs.first
        check(run?.marks == [] && run?.highlightColor == nil && run?.ink == nil, "highlight and ink removed")

        // Slash menu: "/che" + Return makes a checklist and removes the typed text.
        tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [])])
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        type(tv, "/")
        check(tv.isSlashMenuOpen, "slash opens the menu at line start")
        type(tv, "che")
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(!tv.isSlashMenuOpen, "menu closes after choosing")
        check(kinds(tv) == [.title, .checklist] && tv.document.blocks[1].plainText.isEmpty, "slash item applied (got \(kinds(tv)) '\(tv.document.blocks[1].plainText)')")

        // An empty checklist line shows its checkbox right away (it has a fragment of its own).
        check(tv.document.blocks.count == 3 && tv.document.blocks[1].kind == .checklist, "empty checklist line is materialized")

        // Slash menu: arrows + divider.
        type(tv, "x")
        tv.insertNewline(nil)
        check(trimmed(tv.document).count == 3 && trimmed(tv.document)[2].kind == .checklist, "Return at the end of a checklist makes a visible new item")
        tv.insertNewline(nil) // leave the list
        type(tv, "/div")
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(kinds(tv).contains(.divider), "slash divider (got \(kinds(tv)))")

        // Slash in the middle of a word doesn't open the menu; Escape closes it.
        tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [InlineRun(text: "and")])])
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        type(tv, "/or")
        check(!tv.isSlashMenuOpen, "slash after a letter is just a slash")
        type(tv, " /")
        check(tv.isSlashMenuOpen, "slash after a space opens the menu")
        tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check(!tv.isSlashMenuOpen && tv.document.blocks[1].plainText == "and/or /", "escape closes and keeps the text")

        // Moving the cursor away closes the menu; Return then behaves normally.
        tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [InlineRun(text: " keep")])])
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        type(tv, "/ch")
        check(tv.isSlashMenuOpen, "menu open while typing /ch")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        check(!tv.isSlashMenuOpen, "moving the cursor away closes the menu")
        tv.insertNewline(nil)
        check(trimmed(tv.document).map(\.plainText) == ["T", "/ch keep"], "Return after moving away doesn't eat the typed text (got \(trimmed(tv.document).map(\.plainText)))")

        // Block commands never touch the title, even in an empty note.
        tv = makeEditor([Block(kind: .title, runs: [])])
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.setBlockKind(.checklist)
        let ps = tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        check(BlockAttributes(tv.typingAttributes).kind == .title && (ps?.firstLineHeadIndent ?? 0) == 0,
              "checklist on an empty note leaves the title alone")
        type(tv, "Hi")
        check(kinds(tv) == [.title] && tv.document.title == "Hi", "typing after that is still the title")

        // Quotes and callouts end on Return.
        tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [])])
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        type(tv, "! note\nnext")
        check(kinds(tv) == [.title, .callout, .body], "Return after a callout starts body text (got \(kinds(tv)))")
    }

    private static func phase3() {
        let richKinds: [BlockKind] = [.gallery, .table, .board, .columns, .sketch]
        let blocks = [Block(kind: .title, runs: [InlineRun(text: "Power")])] + richKinds.map {
            Block(kind: $0, runs: [], payload: .empty(for: $0))
        }
        let document = NoteDocument(blocks: blocks)
        let text = RichTextCodec.attributedString(from: document)
        check(RichTextCodec.document(from: text) == document, "all rich blocks survive codec round trip, including final sketch")
        if let data = try? JSONEncoder().encode(document), let back = try? JSONDecoder().decode(NoteDocument.self, from: data) {
            check(back == document, "all rich blocks survive JSON round trip")
        } else { check(false, "rich JSON round trip") }
        for kind in richKinds {
            check(!NoteDocument(blocks: [Block(kind: .title, runs: []), Block(kind: kind, runs: [], payload: .empty(for: kind))]).isEmpty,
                  "untitled \(kind) note counts as content")
        }

        let tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]), Block(kind: .body, runs: [])])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = tv
        window.contentView = scroll
        tv.setFrameSize(NSSize(width: 1000, height: 800))
        window.makeFirstResponder(tv)
        tv.undoManager?.removeAllActions()
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.insertRichBlock(.table)
        check(kinds(tv) == [.title, .table], "table insertion consumes empty body and preserves title")
        type(tv, "After")
        check(kinds(tv) == [.title, .table, .body] && tv.document.blocks.last?.plainText == "After", "typing after an attachment stays body text")
        tv.positionRichBlocks()
        check(tv.richBlockHosts.count == 1 && tv.richBlockHosts.values.first!.frame.width > 100 && tv.richBlockHosts.values.first!.frame.height > 100,
              "table has a mounted view at its TextKit attachment frame")
        let wide = tv.richBlockHosts.values.first!.frame.width
        tv.setFrameSize(NSSize(width: 760, height: 800))
        tv.positionRichBlocks()
        check(tv.richBlockHosts.values.first!.frame.width < wide, "rich block follows editor width changes")
        let tableLocation = 2
        if let attachment = tv.textStorage?.attribute(.attachment, at: tableLocation, effectiveRange: nil) as? RichBlockAttachment {
            if let undo = tv.undoManager {
                while undo.groupingLevel > 0 { undo.endUndoGrouping() }
                undo.groupsByEvent = false
            }
            tv.undoManager?.removeAllActions()
            tv.undoManager?.beginUndoGrouping()
            var payload = attachment.state.payload
            payload.table?.rows[0][0] = "Budget"
            tv.updateRichBlock(attachment, payload: payload)
            tv.undoManager?.endUndoGrouping()
            check(tv.document.blocks[1].payload?.table?.rows[0][0] == "Budget", "table child edit reaches note document")
            tv.undoManager?.undo()
            check(tv.document.blocks[1].payload?.table?.rows[0][0] == "", "undo restores table cell value")
            tv.undoManager?.redo()
            check(tv.document.blocks[1].payload?.table?.rows[0][0] == "Budget", "redo restores table cell edit")
            tv.undoManager?.removeAllActions()
            tv.undoManager?.beginUndoGrouping()
            var typing = attachment.state.payload
            typing.table?.rows[0][1] = "F"
            tv.updateRichBlock(attachment, payload: typing, coalesce: "cell-0-1")
            typing.table?.rows[0][1] = "Friday"
            tv.updateRichBlock(attachment, payload: typing, coalesce: "cell-0-1")
            tv.undoManager?.endUndoGrouping()
            tv.undoManager?.undo()
            check(tv.document.blocks[1].payload?.table?.rows[0][1] == "", "undo coalesces a cell typing burst")
            tv.undoManager?.redo()
            check(tv.document.blocks[1].payload?.table?.rows[0][1] == "Friday", "redo restores the entire cell typing burst")
            // Start the edit/delete sequence with one registered cell edit.
            tv.undoManager?.removeAllActions()
            tv.undoManager?.beginUndoGrouping()
            var fresh = attachment.state.payload
            fresh.table?.rows[0][0] = "Changed"
            tv.updateRichBlock(attachment, payload: fresh)
            tv.undoManager?.endUndoGrouping()
            let before = tv.document
            tv.undoManager?.beginUndoGrouping()
            tv.removeRichBlock(attachment)
            tv.undoManager?.endUndoGrouping()
            check(!kinds(tv).contains(.table) && tv.richBlockHosts.isEmpty, "deleting attachment removes its mounted view")
            tv.undoManager?.undo()
            tv.connectRichBlocks()
            check(tv.document == before && tv.richBlockHosts.count == 1, "undo restores deleted block and content (got \(tv.document.blocks.map { "\($0.kind):\($0.plainText)" }))")
            tv.undoManager?.undo()
            check(tv.document.blocks[1].payload?.table?.rows[0][0] == "Budget", "undo edit after undo delete restores pre-edit payload")
            tv.undoManager?.redo()
            tv.undoManager?.redo()
            check(!kinds(tv).contains(.table), "redo edit then redo delete keeps history ordered")
        } else { check(false, "table attachment exists") }

        let list = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")]),
                               Block(kind: .checklist, checked: false, runs: [InlineRun(text: "Book dinner")]),
                               Block(kind: .checklist, checked: true, runs: [InlineRun(text: "Book hotel")]),
                               Block(kind: .body, runs: [InlineRun(text: "Keep this")])])
        list.setSelectedRange(NSRange(location: 2, length: 0))
        list.convertListToBoard()
        check(list.document.blocks[1].payload?.board?.columns[0].cards.map(\.text) == ["Book dinner"], "list conversion preserves open tasks")
        check(list.document.blocks[1].payload?.board?.columns[2].cards.map(\.text) == ["Book hotel"], "list conversion puts checked tasks in Done")
        check(list.document.blocks.last?.plainText == "Keep this", "list conversion preserves following text")
        var board = BoardData(columns: [BoardColumn(id: "a", title: "A", cards: [BoardCard(id: "one", text: "First"), BoardCard(id: "two", text: "Second")]), BoardColumn(id: "b", title: "B", cards: [])])
        board.move(card: "one", to: "b")
        check(board.columns[0].cards.map(\.text) == ["Second"] && board.columns[1].cards.map(\.text) == ["First"], "board drag moves card without losing it")
        board.move(card: "one", to: "a", before: "two")
        check(board.columns[0].cards.map(\.text) == ["First", "Second"], "board drag reorders before a card")
        var table = TableData(rows: [["A", "B"], ["C"]]); table.normalize()
        check(table.rows == [["A", "B"], ["C", ""]], "ragged table normalizes empty cells")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notas-rich-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(rootURL: dir)
        store.load()
        let note = store.createNote(in: nil)
        let assets = store.assets(for: note.id)
        check(assets.url(for: "../escape") == nil && assets.url(for: "/tmp/escape") == nil, "asset paths stay inside note package")
        do {
            let image = NSImage(size: NSSize(width: 32, height: 24), flipped: false) { rect in NSColor.systemPink.setFill(); rect.fill(); return true }
            let name = try assets.importImage(image)
            let doc = NoteDocument(blocks: [Block(kind: .title, runs: []), Block(kind: .gallery, runs: [], payload: BlockPayload(images: [name]))])
            store.updateDocument(note.id, doc)
            store.flush()
            let reload = LibraryStore(rootURL: dir); reload.load()
            check(reload.notes[note.id]?.document == doc, "untitled photo-only note survives reopen")
            check(NSImage(contentsOf: assets.url(for: name)!) != nil, "photo persists inside note package")
            let clipboard = try BlockClipboard(document: doc, source: assets)
            let other = store.createNote(in: nil)
            let copied = try clipboard.imported(into: store.assets(for: other.id))
            let copiedName = copied.blocks[1].payload!.images![0]
            check(copiedName != name && NSImage(contentsOf: store.assets(for: other.id).url(for: copiedName)!) != nil, "cross-note clipboard copies photo bytes with a fresh asset name")
            let pb = NSPasteboard(name: NSPasteboard.Name("notas-test-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            let source = makeEditor(doc.blocks); source.noteAssets = assets
            source.setSelectedRange(NSRange(location: 1, length: 1))
            check(source.writeSelection(to: pb, type: .notasBlocks), "copy photo attachment to private pasteboard")
            let target = makeEditor([Block(kind: .title, runs: [InlineRun(text: "Target")])]); target.noteAssets = store.assets(for: other.id)
            target.setSelectedRange(NSRange(location: 3, length: 0))
            check(target.readSelection(from: pb, type: .notasBlocks), "paste photo attachment into another note")
            check(target.document.title == "Target" && target.document.blocks[1].kind == .gallery, "pasted attachment preserves title and occupies its own paragraph")
            let replacing = makeEditor([Block(kind: .title, runs: [InlineRun(text: "Target")]), Block(kind: .body, runs: [InlineRun(text: "Replace me")])])
            replacing.noteAssets = store.assets(for: other.id)
            replacing.setSelectedRange(NSRange(location: 7, length: 10))
            check(replacing.readSelection(from: pb, type: .notasBlocks) && replacing.document.blocks[1].kind == .gallery && !replacing.document.plainText.contains("Replace me"), "pasting a rich block replaces selected body text")
            replacing.setSelectedRange(NSRange(location: 0, length: (replacing.string as NSString).length))
            replacing.insertText("", replacementRange: replacing.selectedRange())
            check(replacing.richBlockHosts.isEmpty && replacing.document.isEmpty, "clearing a note removes all hosted block views")
            let scan = NSPasteboard(name: NSPasteboard.Name("notas-scan-test-\(UUID().uuidString)"))
            defer { scan.releaseGlobally() }
            scan.setData(image.tiffRepresentation!, forType: .tiff)
            check(target.readSelection(from: scan), "Continuity Camera image delivery uses image importer")
            check(target.document.blocks.filter { $0.kind == .gallery }.count == 2, "camera delivery inserts a persistent gallery")
            let pdf = PDFDocument()
            pdf.insert(PDFPage(image: image)!, at: 0)
            pdf.insert(PDFPage(image: image)!, at: 1)
            scan.clearContents()
            scan.setData(pdf.dataRepresentation()!, forType: .pdf)
            check(target.readSelection(from: scan), "multi-page scan PDF is accepted")
            check(target.document.blocks.filter { $0.kind == .gallery }.last?.payload?.images?.count == 2, "multi-page scan keeps every page")
        } catch { check(false, "asset pipeline: \(error)") }
        window.orderOut(nil)
    }

    private static func resizing() {
        let tv = makeEditor([
            Block(kind: .title, runs: [InlineRun(text: "Resize")]),
            Block(kind: .table, runs: [], payload: .empty(for: .table)),
            Block(kind: .sketch, runs: [], payload: BlockPayload(sketch: SketchData(width: 640, height: 260, strokes: [
                SketchStroke(tool: .pen, color: 0x9381FF, size: 4, points: [40, 40, 320, 220, 600, 40])
            ]))),
            Block(kind: .body, runs: [InlineRun(text: "After the blocks")])
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.backgroundColor = tv.styler.style.nsBackground
        scroll.documentView = tv
        window.contentView = scroll
        let original = tv.document
        let snapshots = ProcessInfo.processInfo.environment["NOTAS_RESIZE_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let snapshots { try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        for width in [1000, 760, 900, 780, 1180, 760] {
            window.setContentSize(NSSize(width: width, height: 900))
            window.contentView?.layoutSubtreeIfNeeded()
            let expectedWidth = min(720, CGFloat(width) - 152)
            for host in tv.richBlockHosts.values {
                check(abs(host.frame.width - expectedWidth) < 1,
                      "rich block fills note at window width \(width), got \(host.frame)")
                check(abs(host.frame.minX - floor((CGFloat(width) - expectedWidth) / 2)) < 1,
                      "rich block stays aligned with text at window width \(width), got \(host.frame)")
                if host.rootView.state.kind == .table {
                    func fields(in view: NSView) -> [NSTextField] {
                        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
                    }
                    let cell = fields(in: host).first { $0.accessibilityLabel() == "Row 1, column 1" }
                    check(cell != nil && abs(cell!.alignmentRect(forFrame: cell!.frame).width - ((expectedWidth - 30) / 3 - 20)) < 1,
                          "table cells reflow in the same layout pass at window width \(width), got \(cell?.frame.width ?? -1)")
                }
            }
            if let snapshots, let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) {
                scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: snapshots.appendingPathComponent("editor-\(width).png"))
            }
        }
        check(tv.document == original, "resizing preserves table and sketch content")

        tv.load(NoteDocument(blocks: [
            Block(kind: .title, runs: [InlineRun(text: "Long note")]),
            Block(kind: .table, runs: [], payload: .empty(for: .table))
        ] + (0..<200).map { Block(kind: .body, runs: [InlineRun(text: "Paragraph \($0)")]) } + [
            Block(kind: .sketch, runs: [], payload: .empty(for: .sketch))
        ]))
        tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
        tv.layoutSubtreeIfNeeded()
        let tableHost = tv.richBlockHosts.values.first { $0.rootView.state.kind == .table }!
        let sketchHost = tv.richBlockHosts.values.first { $0.rootView.state.kind == .sketch }!
        check(!tableHost.isHidden && sketchHost.isHidden, "long note mounts visible table and hides offscreen sketch")
        tv.scrollRangeToVisible(NSRange(location: (tv.string as NSString).length - 1, length: 1))
        tv.layoutSubtreeIfNeeded()
        check(!sketchHost.isHidden && tableHost.isHidden, "scrolling reveals sketch and hides offscreen table")
        window.setContentSize(NSSize(width: 900, height: 900))
        window.contentView?.layoutSubtreeIfNeeded()
        check(!sketchHost.isHidden && abs(sketchHost.frame.width - 720) < 1,
              "offscreen sketch uses current note width when scrolled into view and resized")
        tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
        tv.layoutSubtreeIfNeeded()
        check(!tableHost.isHidden && abs(tableHost.frame.width - 720) < 1,
              "scrolling back restores the table at current note width")
        window.close()
        if let snapshots { capturePanels(in: snapshots, document: original) }
    }

    private static func capturePanels(in snapshots: URL, document: NoteDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notas-resize-\(UUID().uuidString)")
        let suite = "com.stephenlopez.notas.resize.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let store = LibraryStore(rootURL: root)
        store.load()
        let app = AppState(store: store, preferences: preferences)
        app.appearance = .dark
        let note = store.createNote(in: nil)
        store.updateDocument(note.id, document)
        app.open(note.id)
        let host = NSHostingView(rootView: MainView().environment(app))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for (name, width, drawer, panel) in [
            ("drawer-wide", 1180, true, false), ("drawer-narrow", 760, true, false),
            ("style-narrow", 760, false, true), ("style-wide", 1180, false, true),
            ("closed", 760, false, false)
        ] {
            app.drawer = drawer ? .all : nil
            app.isStylePanelOpen = panel
            window.setContentSize(NSSize(width: width, height: 800))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: snapshots.appendingPathComponent("\(name).png"))
            }
        }
        window.close()
        store.flush()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private static func phase4() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notas-phase4-\(UUID().uuidString)")
        let suite = "com.stephenlopez.notas.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library")); store.load(); store.flush()
        let app = AppState(store: store, preferences: preferences)
        let shared = SharedCaptureStore(directory: root.appendingPathComponent("Shared"))
        let integration = CaptureIntegration(app: app, shared: shared, reloadWidgets: {})
        do {
            let target = store.createNotebook(name: "Captured")
            let request = CaptureRequest(text: "Weekend plans\nBook a quiet dinner\nPack a warm coat", links: [URL(string: "https://example.com/trip")!], notebookID: target.id)
            let staging = try shared.createStagingDirectory(id: request.id)
            check(try shared.pendingPackages().isEmpty, "uncommitted capture is invisible to importer")
            try shared.commit(request, staging: staging)
            check(try shared.pendingPackages().count == 1, "share commits one complete capture package")
            try shared.commit(request, staging: staging)
            check(try shared.pendingPackages().count == 1, "retrying capture commit does not duplicate it")
            integration.importPending()
            let imported = store.notes[request.id]
            check(imported?.title == "Weekend plans" && imported?.notebookID == target.id, "capture uses first line as title and selected notebook")
            check(imported?.document.blocks.dropFirst().map(\.plainText) == ["Book a quiet dinner", "Pack a warm coat", "https://example.com/trip"], "capture preserves text lines and shared link")
            check(imported?.document.blocks.last?.runs.first?.link == "https://example.com/trip", "shared URL remains a clickable link")
            check(try shared.pendingPackages().isEmpty, "import acknowledges capture only after persistence")
            _ = try store.importCapture(request)
            check(store.notes.values.filter { $0.id == request.id }.count == 1, "repeated imports keep one note")
            let reloaded = LibraryStore(rootURL: store.rootURL); reloaded.load()
            check(reloaded.notes[request.id]?.document == imported?.document, "captured note is durable without a delayed save")

            let invalidID = UUID()
            let invalid = shared.inboxURL.appendingPathComponent(invalidID.uuidString + ".capture")
            try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
            try Data("bad json".utf8).write(to: invalid.appendingPathComponent("capture.json"))
            let next = CaptureRequest(text: "Still imports")
            try shared.commit(next, staging: shared.createStagingDirectory(id: next.id))
            integration.importPending()
            check(store.notes[next.id]?.title == "Still imports", "one malformed capture does not block another")
            check(FileManager.default.fileExists(atPath: invalid.path), "malformed capture remains recoverable")
            integration.importPending(reportFailures: true)
            check(app.captureImportError != nil, "failed shared imports report a recoverable problem to the app")

            let image = NSImage(size: NSSize(width: 32, height: 20), flipped: false) { rect in NSColor.systemBlue.setFill(); rect.fill(); return true }
            let imageRequestID = UUID()
            let imageStaging = try shared.createStagingDirectory(id: imageRequestID)
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: imageStaging.appendingPathComponent("photo.png"))
            let imageRequest = CaptureRequest(id: imageRequestID, text: "A shared moment", attachments: [CaptureAttachment(name: "photo.png", typeIdentifier: "public.png")])
            try shared.commit(imageRequest, staging: imageStaging)
            integration.importPending()
            let photoName = store.notes[imageRequestID]?.document.blocks.last?.payload?.images?.first
            check(photoName.flatMap { store.assets(for: imageRequestID).url(for: $0) }.flatMap(NSImage.init(contentsOf:)) != nil,
                  "shared photo is copied into its note before inbox removal")
            check(!FileManager.default.fileExists(atPath: shared.inboxURL.appendingPathComponent(imageRequestID.uuidString + ".capture").path), "photo capture is acknowledged after a successful import")

            let missing = CaptureRequest(text: "Missing photo", attachments: [CaptureAttachment(name: "missing.png", typeIdentifier: "public.png")])
            do { try shared.commit(missing, staging: shared.createStagingDirectory(id: missing.id)); check(false, "missing photo rejected") }
            catch { check(store.notes[missing.id] == nil, "missing photo prevents incomplete capture commit") }
            do { _ = try SharedCaptureStore.attachmentURL(name: "../outside", in: imageStaging); check(false, "capture path rejected") }
            catch { check(true, "capture attachment paths cannot escape their package") }

            let draftURL = root.appendingPathComponent("Drafts/quick.json")
            let model = QuickCaptureModel(app: app, draftURL: draftURL)
            model.text = "A quick thought\nKeep this detail"; model.notebookID = target.id
            model.saveDraft()
            let restored = QuickCaptureModel(app: app, draftURL: draftURL)
            check(restored.text == model.text && restored.draftID == model.draftID && restored.notebookID == target.id, "quick capture restores its draft and destination")
            let saved = try restored.save()
            check(saved.title == "A quick thought" && saved.document.bodyText == "Keep this detail", "quick capture saves title and body")
            check(saved.id == model.draftID && restored.text.isEmpty && restored.draftID != saved.id, "successful capture clears draft and gives the next one a fresh ID")
            check(try QuickCaptureDraft.read(from: draftURL).text.isEmpty, "cleared draft is persisted")
            try QuickCaptureDraft(id: saved.id, text: "A quick thought\nKeep this detail", notebookID: target.id).write(to: draftURL)
            check(QuickCaptureModel(app: app, draftURL: draftURL).text.isEmpty, "already committed draft does not reappear after a crash")

            let longLine = String(repeating: "word ", count: 45)
            let longCapture = CaptureRequest(text: longLine)
            check(longCapture.title.count == 160 && longCapture.body == longLine, "shortened capture title preserves the full text in body")
            app.widgetNoteID = saved.id
            integration.publishNow()
            let snapshot = try shared.snapshot()
            check(snapshot.note?.id == saved.id && snapshot.note?.title == "A quick thought", "widget snapshot contains the chosen note")
            check(snapshot.notebooks.contains { $0.id == target.id && $0.name == "Captured" }, "share destination snapshot includes notebooks")
            store.updateDocument(saved.id, NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "Checklist")]), Block(kind: .checklist, checked: true, runs: [InlineRun(text: "Book hotel")]), Block(kind: .checklist, checked: false, runs: [InlineRun(text: "Pack coat")])]))
            integration.publishNow()
            check(try shared.snapshot().note?.checklist.map(\.checked) == [true, false], "widget snapshot preserves checklist completion")

            let sharedURL = URL(string: "https://example.com/trip?day=2")!
            check(CaptureItemDecoder.url(from: sharedURL.dataRepresentation as NSData) == sharedURL, "Safari URL data decodes without losing query parameters")
            check(CaptureItemDecoder.url(from: sharedURL as NSURL) == sharedURL, "shared URL objects decode")
            check(CaptureItemDecoder.url(from: sharedURL.absoluteString as NSString) == sharedURL, "shared URL strings decode")
            check(CaptureItemDecoder.url(from: NSNumber(value: 42)) == nil, "shared URL decoder rejects unrelated values")
            for link in [NotasLink.quickCapture, .open, .note(saved.id)] { check(NotasLink(url: link.url) == link, "deep link round trip \(link)") }
            check(NotasLink(url: URL(string: "https://example.com/quick")!) == nil && NotasLink(url: URL(string: "notas://note/not-a-uuid")!) == nil,
                  "deep links reject foreign schemes and malformed note IDs")
            check(NotasLink(url: URL(string: "notas://quick?unexpected=1")!) == nil, "deep links reject unexpected parameters")

            var delivered = false
            let hotKey = GlobalCaptureHotKey()
            hotKey.action = { delivered = true }
            let registered = hotKey.register(.controlOptionSpace)
            check(registered == noErr, "global quick-capture shortcut registers without accessibility permission")
            if registered == noErr {
                var event: EventRef?
                let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(0), &event)
                if created == noErr, let event {
                    defer { ReleaseEvent(event) }
                    var identifier = EventHotKeyID(signature: 0x4E544153, id: 1)
                    let parameter = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier)
                    let sent = SendEventToEventTarget(event, GetApplicationEventTarget())
                    check(parameter == noErr && sent == noErr && delivered, "system hot-key event reaches quick-capture action")
                } else { check(false, "system hot-key event can be constructed") }
            }
            _ = hotKey.register(.off)

            let broken = LibraryStore(rootURL: root.appendingPathComponent("Broken")); broken.load(); broken.flush()
            try FileManager.default.removeItem(at: broken.rootURL.appendingPathComponent("Notes"))
            try Data("not a directory".utf8).write(to: broken.rootURL.appendingPathComponent("Notes"))
            let failedDraft = QuickCaptureModel(app: AppState(store: broken, preferences: preferences), draftURL: root.appendingPathComponent("failed.json"))
            failedDraft.text = "Keep this if save fails"
            do { _ = try failedDraft.save(); check(false, "capture persistence failure reported") }
            catch { check(failedDraft.text == "Keep this if save fails" && broken.notes[failedDraft.draftID] == nil, "failed save keeps the draft instead of claiming success") }
        } catch { check(false, "phase 4 pipeline: \(error)") }
    }

    private static func sharing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notas-share-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = LibraryStore(rootURL: dir.appendingPathComponent("source"))
            store.load()
            var note = store.createNote(in: store.sortedNotebooks.first?.id)
            note.tags = ["shared", "colors"]
            let image = NSImage(size: NSSize(width: 240, height: 160), flipped: false) { rect in
                NSColor.systemPink.setFill(); rect.fill(); return true
            }
            let name = try store.assets(for: note.id).importImage(image)
            let cards = (0..<25).map { BoardCard(text: "Card \($0) complete") }
            note.document = NoteDocument(blocks: [
                Block(kind: .title, runs: [InlineRun(text: "A colorful shared note")]),
                Block(kind: .body, runs: [InlineRun(text: "Pink highlight", marks: [.bold, .highlight], highlightColor: .pink), InlineRun(text: " and blue ink", marks: .italic, ink: .blue)]),
                Block(kind: .body, runs: [InlineRun(text: "A clickable link", link: "https://example.com/shared")]),
                Block(kind: .checklist, checked: true, runs: [InlineRun(text: "Checked task")]),
                Block(kind: .quote, runs: [InlineRun(text: "A quote to remember")]),
                Block(kind: .callout, runs: [InlineRun(text: "Keep every detail")]),
                Block(kind: .code, runs: [InlineRun(text: "print(\"Hello\")")]),
                Block(kind: .gallery, runs: [], payload: BlockPayload(images: [name])),
                Block(kind: .table, runs: [], payload: BlockPayload(table: TableData(rows: (0..<18).map { row in (0..<9).map { "Cell \(row)-\($0)" } }))),
                Block(kind: .board, runs: [], payload: BlockPayload(board: BoardData(columns: (0..<6).map { BoardColumn(title: "Column \($0)", cards: cards) }))),
                Block(kind: .columns, runs: [], payload: BlockPayload(columns: [String(repeating: "Long left column. ", count: 100) + "LEFT END", String(repeating: "Long right column. ", count: 100) + "RIGHT END"])),
                Block(kind: .sketch, runs: [], payload: BlockPayload(sketch: SketchData(width: 640, height: 260, strokes: [SketchStroke(tool: .pen, color: InkColor.pink.hex, size: 5, points: [10, 10, 200, 100, 500, 50])]))),
                Block(kind: .body, runs: [InlineRun(text: "FINAL NOTE TEXT")]),
            ])
            let resolved = ResolvedStyle(style: note.style, systemIsDark: true, appAccent: .coral)
            let copy = try SharedNoteFile(note: note, resolved: resolved, assets: store.assets(for: note.id), notebook: store.notebook(note.notebookID))
            let url = dir.appendingPathComponent("Copy.notasnote")
            try copy.write(to: url)
            let decoded = try SharedNoteFile.read(from: url)
            check(decoded.content.document == note.document, "shared file preserves every block, mark, color and sketch")
            check(ResolvedStyle(style: decoded.style, systemIsDark: false, appAccent: .mint) == resolved, "shared style keeps sender colors on a different Mac appearance")
            check(decoded.content.assets[name] != nil && decoded.tags == ["shared", "colors"], "shared copy includes photos and tags")
            let receiver = LibraryStore(rootURL: dir.appendingPathComponent("receiver"))
            receiver.load()
            let first = try receiver.importSharedNote(decoded)
            let second = try receiver.importSharedNote(decoded)
            check(first.id != second.id && first.id != note.id, "opening shared files creates independent copies")
            let importedName = first.document.blocks.first { $0.kind == .gallery }?.payload?.images?.first ?? ""
            let importedData = try Data(contentsOf: receiver.assets(for: first.id).url(for: importedName)!)
            check(importedName != name && importedData == decoded.content.assets[name], "imported photos have independent names and identical bytes")
            let reloaded = LibraryStore(rootURL: receiver.rootURL)
            reloaded.load()
            check(reloaded.notes[first.id]?.document == first.document, "imported copy is complete on disk before opening")
            let pdfData = try NotePDFRenderer(file: decoded).render()
            let pdf = PDFDocument(data: pdfData)
            let text = pdf?.string ?? ""
            check((pdf?.pageCount ?? 0) > 1 && text.contains("FINAL NOTE TEXT"), "PDF has pages and includes the end of the note")
            check(text.contains("Cell 17-8") && text.contains("Column 5") && text.contains("Card 24 complete"), "PDF includes offscreen table columns and board cards")
            check(text.contains("LEFT END") && text.contains("RIGHT END"), "PDF includes the full scrolling text columns")
            check(text.contains("Pink highlight") && text.contains("Checked task"), "PDF text remains selectable")
            check(pdf?.page(at: 0)?.annotations.contains { $0.url?.absoluteString == "https://example.com/shared" } == true, "PDF links remain clickable")
            if let page = pdf?.page(at: 0), let link = page.annotations.first(where: { $0.url != nil }) {
                check(page.selection(for: link.bounds)?.string?.contains("clickable") == true, "PDF link target aligns with its visible text")
            } else { check(false, "PDF link target aligns with its visible text") }
            if let output = ProcessInfo.processInfo.environment["NOTAS_SHARE_TEST_OUTPUT"] {
                let folder = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try pdfData.write(to: folder.appendingPathComponent("Shared note.pdf"))
                try copy.write(to: folder.appendingPathComponent("Shared note.notasnote"))
            }
            var damaged = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            damaged["version"] = 99
            try JSONSerialization.data(withJSONObject: damaged).write(to: url)
            do { _ = try SharedNoteFile.read(from: url); check(false, "unsupported shared version rejected") }
            catch { check(true, "unsupported shared version rejected") }
            try copy.write(to: url)
            damaged = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var content = damaged["content"] as! [String: Any]
            content["assets"] = [:]
            damaged["content"] = content
            try JSONSerialization.data(withJSONObject: damaged).write(to: url)
            do { _ = try SharedNoteFile.read(from: url); check(false, "shared file missing photos rejected") }
            catch { check(true, "shared file missing photos rejected") }
        } catch { check(false, "sharing pipeline: \(error)") }
    }

    // MARK: Store

    private static func store() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notas-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LibraryStore(rootURL: dir)
        store.load()
        check(store.notebooks.count == 3, "first run seeds notebooks")
        check(store.notes.count == 1, "first run seeds the welcome note")

        let nb = store.createNotebook(name: "Recipes")
        let note = store.createNote(in: nb.id)
        store.updateDocument(note.id, NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "Sunday pasta")]),
                                                            Block(kind: .body, runs: [InlineRun(text: "brown butter and sage")])]))
        store.addTag("#Dinner Ideas", to: note.id)
        check(store.notes[note.id]?.tags == ["dinner-ideas"], "tags are normalized")
        check(store.search("pasta").first?.note.id == note.id, "search by title")
        check(store.search("sage").first?.note.id == note.id, "search by body")
        check(store.search("zzz").isEmpty, "search misses")
        store.flush()

        let reloaded = LibraryStore(rootURL: dir)
        reloaded.load()
        check(reloaded.notes[note.id]?.title == "Sunday pasta", "notes persist to disk")
        check(reloaded.notebooks.contains { $0.name == "Recipes" }, "notebooks persist to disk")

        reloaded.deleteNotebook(nb.id)
        check(reloaded.notes[note.id]?.notebookID != nb.id, "deleting a notebook moves its notes")
    }

    // MARK: Performance paths
    // Behavior the speed-ups must not change: restyle skipping, the search index, compact files, photo import.

    private static func performance() {
        // Inserting a numbered item renumbers the items after it, even though they weren't edited.
        let tv = makeEditor([Block(kind: .title, runs: [InlineRun(text: "T")])] +
                            (1...6).map { Block(kind: .numbered, runs: [InlineRun(text: "item \($0)")]) })
        func ordinal(_ text: String) -> Int? {
            guard let storage = tv.textStorage else { return nil }
            let found = (tv.string as NSString).range(of: text)
            guard found.location != NSNotFound else { return nil }
            return storage.attribute(.notasOrdinal, at: found.location, effectiveRange: nil) as? Int
        }
        let initial: [Int?] = (1...6).map { n in ordinal("item " + String(n)) }
        check(initial == [1, 2, 3, 4, 5, 6], "list starts numbered 1…6 (got \(initial))")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "item 2").upperBound, length: 0))
        type(tv, "\nnew")
        check(ordinal("new") == 3 && ordinal("item 3") == 4 && ordinal("item 6") == 7, "inserting an item renumbers the rest")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "new").location, length: 0))
        tv.setBlockKind(.body)
        check(ordinal("item 2") == 2 && ordinal("item 3") == 1 && ordinal("item 6") == 4, "splitting a list restarts numbering after the gap")

        // A theme change reaches paragraphs that never changed.
        let light = ResolvedStyle(style: NoteStyle(themeID: "ink"), systemIsDark: false, appAccent: .violet)
        let dark = ResolvedStyle(style: NoteStyle(themeID: "midnight"), systemIsDark: true, appAccent: .violet)
        tv.applyStyle(light)
        let lightText = tv.textStorage?.attribute(.foregroundColor, at: (tv.string as NSString).range(of: "item 6").location, effectiveRange: nil) as? NSColor
        tv.applyStyle(dark)
        let darkText = tv.textStorage?.attribute(.foregroundColor, at: (tv.string as NSString).range(of: "item 6").location, effectiveRange: nil) as? NSColor
        check(lightText != nil && lightText != darkText, "changing theme restyles untouched paragraphs")
        check(tv.document.blocks.count == 8, "restyling keeps every paragraph")

        // Search sees edits immediately even though it caches lowercased text.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notas-selftest-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(rootURL: dir)
        store.load()
        let note = store.createNote(in: nil)
        store.updateDocument(note.id, NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "Alpine")]),
                                                            Block(kind: .body, runs: [InlineRun(text: "Marmot Burrow")])]))
        check(store.search("marmot").first?.note.id == note.id, "search finds body text (and builds the index)")
        store.updateDocument(note.id, NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "Alpine")]),
                                                            Block(kind: .body, runs: [InlineRun(text: "Ibex")])]))
        check(store.search("marmot").isEmpty && store.search("ibex").first?.note.id == note.id, "search index follows edits")
        store.mutate(note.id) { $0.document.blocks[0].runs = [InlineRun(text: "Glacier")] }
        check(store.search("glacier").first?.note.id == note.id && store.search("alpine").isEmpty, "search index follows mutate")
        check(store.search("ibex").first?.snippet?.lowercased().contains("ibex") == true, "search hits carry a snippet")
        store.trash(note.id)
        check(store.search("ibex").isEmpty, "trashed notes leave search")

        // Previews stop after three lines and skip the title and empty paragraphs.
        let long = Note(id: UUID(), notebookID: UUID(), tags: [], created: Date(), modified: Date(), pinned: false, style: NoteStyle(),
                        document: NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "Title")]),
                                                        Block(kind: .body, runs: []),
                                                        Block(kind: .body, runs: [InlineRun(text: "one")]),
                                                        Block(kind: .body, runs: [InlineRun(text: "  two  ")]),
                                                        Block(kind: .body, runs: [InlineRun(text: "three")]),
                                                        Block(kind: .body, runs: [InlineRun(text: "four")])]))
        check(long.preview == "one two three", "preview is the first three non-empty lines (got '\(long.preview)')")

        // Files are compact, old pretty-printed files still open, and sketch points are trimmed.
        let sketch = SketchStroke(tool: .pen, color: nil, size: 2.8, points: [1.23456789, 2.98765432])
        let sketchNote = Note(id: UUID(), notebookID: UUID(), tags: ["a"], created: Date(), modified: Date(), pinned: false, style: NoteStyle(),
                              document: NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "S")]),
                                                              Block(kind: .sketch, runs: [], payload: BlockPayload(sketch: SketchData(width: 10, height: 10, strokes: [sketch])))]))
        if let data = try? LibraryStore.encoder.encode(sketchNote), let text = String(data: data, encoding: .utf8) {
            check(!text.contains("\n"), "note files are written compact")
            check(text.contains("1.23") && !text.contains("1.234"), "sketch points are stored to two decimals")
            let pretty = JSONEncoder()
            pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
            pretty.dateEncodingStrategy = .iso8601
            let old = (try? pretty.encode(sketchNote)).flatMap { try? LibraryStore.decoder.decode(Note.self, from: $0) }
            check(old?.id == sketchNote.id && old?.tags == ["a"], "pretty-printed files from earlier versions still load")
        } else { check(false, "note encodes") }

        // Parallel load returns every note, including with more notes than workers.
        let many = LibraryStore(rootURL: dir.appendingPathComponent("many"))
        many.load()
        let ids = (0..<40).map { i -> UUID in
            let n = many.createNote(in: nil)
            many.updateDocument(n.id, NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "Note \(i)")]), Block(kind: .body, runs: [InlineRun(text: "body \(i)")])]))
            return n.id
        }
        many.flush()
        let reopened = LibraryStore(rootURL: dir.appendingPathComponent("many"))
        reopened.load()
        check(ids.allSatisfy { reopened.notes[$0] != nil } && reopened.notes.count == 41, "parallel load reads every note (got \(reopened.notes.count))")

        // Photo import keeps small files, shrinks big ones, and the thumbnail cache serves repeat requests.
        let photoDir = dir.appendingPathComponent("photos")
        try? FileManager.default.createDirectory(at: photoDir, withIntermediateDirectories: true)
        let assets = NoteAssets(package: photoDir.appendingPathComponent("p.notas"))
        func makePhoto(_ width: Int, _ height: Int, as type: NSBitmapImageRep.FileType, name: String) -> URL? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let data = rep.representation(using: type, properties: [:]) else { return nil }
            let url = photoDir.appendingPathComponent(name)
            return (try? data.write(to: url)) != nil ? url : nil
        }
        if let small = makePhoto(400, 300, as: .jpeg, name: "small.jpg"), let big = makePhoto(4000, 1000, as: .png, name: "big.png") {
            do {
                let smallName = try assets.importFile(small)[0]
                let bigName = try assets.importFile(big)[0]
                let copied = try Data(contentsOf: assets.url(for: smallName)!)
                let original = try Data(contentsOf: small)
                check(smallName.hasSuffix(".jpg") && copied == original, "small JPEG is copied untouched")
                let bigSize = NSImage(contentsOf: assets.url(for: bigName)!)?.representations.first.map { max($0.pixelsWide, $0.pixelsHigh) } ?? 0
                check(bigSize == NoteAssets.maxStoredPixels, "oversized photos are shrunk to \(NoteAssets.maxStoredPixels)px (got \(bigSize))")
                check(PhotoCache.cached(assets.url(for: smallName)!, maxPixel: 200) == nil, "thumbnail cache starts empty")
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var thumb: NSImage?
                let thumbURL = assets.url(for: smallName)!
                Task.detached { thumb = await PhotoCache.load(thumbURL, maxPixel: 200); sem.signal() }
                sem.wait()
                check(max(thumb?.size.width ?? 0, thumb?.size.height ?? 0) == 200, "thumbnail is downsampled to the requested size")
                check(PhotoCache.cached(thumbURL, maxPixel: 200) != nil, "thumbnail is cached after the first load")

                // The gallery tile view loads its photo through the cache once it is on screen.
                let host = NSHostingView(rootView: PhotoImage(url: thumbURL, maxPixel: 640, fill: true) { Color.red })
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let deadline = Date().addingTimeInterval(3)
                while PhotoCache.cached(thumbURL, maxPixel: 640) == nil, Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                check(PhotoCache.cached(thumbURL, maxPixel: 640) != nil, "PhotoImage loads its photo into the cache")
                window.contentView = nil
            } catch { check(false, "photo import: \(error)") }
        } else { check(false, "test photos could not be created") }
    }
}
#endif
