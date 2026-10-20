import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension NotasTextView {
    func positionRichBlocks() {
        guard !isPositioningRichBlocks, !richBlockHosts.isEmpty,
              let manager = textLayoutManager, let content = textContentStorage else { return }
        isPositioningRichBlocks = true
        defer { isPositioningRichBlocks = false }
        manager.ensureLayout(for: manager.documentRange)
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            guard offset >= 0, offset < self.textStorage?.length ?? 0,
                  let attachment = self.textStorage?.attribute(.attachment, at: offset, effectiveRange: nil) as? RichBlockAttachment,
                  let host = self.richBlockHosts[ObjectIdentifier(attachment)] else { return true }
            let rect = fragment.frameForTextAttachment(at: fragment.rangeInElement.location)
            let frame = rect.offsetBy(dx: fragment.layoutFragmentFrame.minX + self.textContainerOrigin.x,
                                      dy: fragment.layoutFragmentFrame.minY + self.textContainerOrigin.y)
            if host.frame != frame { host.frame = frame }
            return true
        }
    }

    func connectRichBlocks() {
        guard let storage = textStorage else { return }
        var active = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let attachment = value as? RichBlockAttachment else { return }
            attachment.editor = self
            let id = ObjectIdentifier(attachment)
            active.insert(id)
            if self.richBlockHosts[id] == nil {
                let host = NSHostingView(rootView: RichBlockView(attachment: attachment, state: attachment.state))
                host.sizingOptions = []
                self.richBlockHosts[id] = host
                self.addSubview(host)
            }
            if attachment.state.style != styler.style { attachment.state.style = styler.style }
        }
        for id in Array(richBlockHosts.keys) where !active.contains(id) {
            richBlockHosts.removeValue(forKey: id)?.removeFromSuperview()
        }
        needsLayout = true
    }

    func range(of attachment: RichBlockAttachment) -> NSRange? {
        guard let storage = textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? RichBlockAttachment === attachment { found = range; stop.pointee = true }
        }
        return found
    }

    func updateRichBlock(_ attachment: RichBlockAttachment, payload: BlockPayload, coalesce key: String? = nil) {
        guard let range = range(of: attachment), payload != attachment.state.payload else { return }
        let coalesced = key.map { key in
            richTyping.map { $0.0 == ObjectIdentifier(attachment) && $0.1 == key && Date().timeIntervalSince($0.2) < 0.6 } ?? false
        } ?? false
        if !coalesced {
            breakUndoCoalescing()
            let previous = attachment.state.payload
            undoManager?.registerUndo(withTarget: self) { editor in editor.updateRichBlock(attachment, payload: previous) }
            undoManager?.setActionName("Edit \(attachment.state.kind.displayName)")
        }
        richTyping = key.map { (ObjectIdentifier(attachment), $0, Date()) }
        attachment.state.payload = payload
        if let content = textContentStorage,
           let start = content.location(content.documentRange.location, offsetBy: range.location),
           let end = content.location(start, offsetBy: range.length),
           let textRange = NSTextRange(location: start, end: end) {
            textLayoutManager?.invalidateLayout(for: textRange)
        }
        needsLayout = true
        needsDisplay = true
        onUserEdit?()
    }

    /// Inserts after the current paragraph, consuming only an empty body paragraph.
    func insertRichBlock(_ kind: BlockKind, payload: BlockPayload? = nil) {
        guard kind.isAttachment, let storage = textStorage else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: selectedRange())
        var end = 0, contentsEnd = 0
        ns.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: para.location, length: 0))
        let emptyBody = para.location > 0 && contentsEnd == para.location
        let replace = emptyBody ? para : NSRange(location: contentsEnd, length: end - contentsEnd)
        let insertion = NSMutableAttributedString()
        if !emptyBody {
            insertion.append(NSAttributedString(string: "\n", attributes: BlockAttributes(kind: para.location == 0 ? .title : blockAttributes(at: para.location).kind).dictionary))
        }
        insertion.append(RichTextCodec.attributedString(from: NoteDocument(blocks: [
            Block(kind: kind, runs: [], payload: payload ?? .empty(for: kind)), Block(kind: .body, runs: [])
        ])))
        if end > contentsEnd { insertion.append(NSAttributedString(string: "\n", attributes: BlockAttributes(kind: .body).dictionary)) }
        breakUndoCoalescing()
        guard shouldChangeText(in: replace, replacementString: insertion.string) else { return }
        storage.replaceCharacters(in: replace, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: replace.location + insertion.length - (end > contentsEnd ? 1 : 0), length: 0))
        typingAttributes = styler.typingAttributes(for: BlockAttributes(kind: .body))
        undoManager?.setActionName("Insert \(kind.displayName)")
        scrollRangeToVisible(selectedRange())
    }

    func removeRichBlock(_ attachment: RichBlockAttachment) {
        guard let range = range(of: attachment), let storage = textStorage else { return }
        let para = (string as NSString).paragraphRange(for: range)
        refocus()
        guard shouldChangeText(in: para, replacementString: "") else { return }
        storage.replaceCharacters(in: para, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: min(para.location, storage.length), length: 0))
    }

    func convertListToBoard() {
        let ns = string as NSString
        guard let storage = textStorage, ns.length > 0 else { return }
        var para = ns.paragraphRange(for: selectedRange())
        guard para.location > 0, blockAttributes(at: para.location).kind.isList else { insertRichBlock(.board); return }
        while para.location > 0 {
            let previous = ns.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
            guard previous.location > 0, blockAttributes(at: previous.location).kind.isList else { break }
            para = NSUnionRange(previous, para)
        }
        while NSMaxRange(para) < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(para), length: 0))
            guard blockAttributes(at: next.location).kind.isList else { break }
            para = NSUnionRange(para, next)
        }
        let fragment = RichTextCodec.document(from: storage.attributedSubstring(from: para), forceTitle: false)
        var todo: [BoardCard] = [], done: [BoardCard] = []
        for block in fragment.blocks where block.kind.isList && !block.plainText.isEmpty {
            let card = BoardCard(text: block.plainText)
            if block.checked == true { done.append(card) } else { todo.append(card) }
        }
        let board = BoardData(columns: [BoardColumn(title: "To do", cards: todo), BoardColumn(title: "Doing", cards: []), BoardColumn(title: "Done", cards: done)])
        let text = RichTextCodec.attributedString(from: NoteDocument(blocks: [Block(kind: .board, runs: [], payload: BlockPayload(board: board)), Block(kind: .body, runs: [])]))
        breakUndoCoalescing()
        guard shouldChangeText(in: para, replacementString: text.string) else { return }
        storage.replaceCharacters(in: para, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: para.location + text.length, length: 0))
        typingAttributes = styler.typingAttributes(for: BlockAttributes(kind: .body))
        undoManager?.setActionName("Turn List into Board")
    }

    func importPhotos(into attachment: RichBlockAttachment? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add Photos"
        let selection = selectedRange()
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak attachment] response in
            guard response == .OK, let self else { return }
            do {
                guard let assets = self.noteAssets else { throw NoteAssets.AssetError.missing }
                let names = try panel.urls.flatMap { try assets.importFile($0) }
                if let attachment {
                    var payload = attachment.state.payload
                    payload.images = (payload.images ?? []) + names
                    attachment.update(payload)
                } else {
                    self.setSelectedRange(NSRange(location: min(selection.location, (self.string as NSString).length), length: 0))
                    self.insertRichBlock(.gallery, payload: BlockPayload(images: names))
                }
            } catch { self.presentAssetError(error) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(panel.runModal()) }
    }

    func presentAssetError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func receiveImages(from pasteboard: NSPasteboard) -> Bool {
        guard let assets = noteAssets else { return false }
        do {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            var images: [String] = []
            if !urls.isEmpty {
                images = try urls.flatMap { try assets.importFile($0) }
            } else if let data = pasteboard.data(forType: .pdf) {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                try data.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                images = try assets.importFile(file)
            } else if let image = NSImage(pasteboard: pasteboard) {
                images = [try assets.importImage(image)]
            }
            guard !images.isEmpty else { return false }
            insertRichBlock(.gallery, payload: BlockPayload(images: images))
            return true
        } catch { presentAssetError(error); return true }
    }

    func showScanMenu() {
        refocus()
        let menu = NSMenu(title: "Import from iPhone")
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        let hint = NSMenuItem(title: "Use a nearby iPhone signed into the same Apple Account", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let origin = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let point = window.map { convert($0.convertFromScreen(origin), from: nil).origin } ?? NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y)
        menu.popUp(positioning: nil, at: point, in: self)
    }
}
