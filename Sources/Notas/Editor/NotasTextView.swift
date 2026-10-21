import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    static let notasBlocks = NSPasteboard.PasteboardType("com.stephenlopez.notas.blocks")
}

/// The note editor. A TextKit 2 `NSTextView` that understands blocks (lists, checklists,
/// headings…) and inline marks, and keeps the text styled for the current theme.
final class NotasTextView: NSTextView, NSTextStorageDelegate, NSTextLayoutManagerDelegate {
    var styler = EditorStyler(style: ResolvedStyle(style: NoteStyle(), systemIsDark: true, appAccent: .violet))
    /// Called after any change the user makes (typing, formatting, toggling a checkbox).
    var onUserEdit: (() -> Void)?
    var noteAssets: NoteAssets?
    var noteID: UUID?
    var richBlockHosts: [ObjectIdentifier: NSHostingView<RichBlockView>] = [:]
    var isPositioningRichBlocks = false
    var richTyping: (ObjectIdentifier, String, Date)?

    var maxContentWidth: CGFloat = 720 { didSet { updateInsets() } }
    var topInset: CGFloat = 120 { didSet { updateInsets() } }
    var headerView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let headerView { addSubview(headerView) }
            updateInsets()
        }
    }
    static let headerHeight: CGFloat = 26

    private var contentStorageRef: NSTextContentStorage?
    private var isRestyling = false
    private var isStructuredEdit = false

    // Overlays
    let overlays = EditorOverlayModel()
    private var formatHost: NSView?
    private var slashHost: NSView?
    /// Location of the "/" that opened the block menu, while it's open.
    private(set) var slashStart: Int?
    private var isMouseSelecting = false
    private var overlayUpdateScheduled = false

    enum HighlightChoice: Equatable {
        case accent
        case ink(InkColor)
    }

    // MARK: Construction

    static func make() -> NotasTextView {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container

        let view = NotasTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        view.contentStorageRef = contentStorage
        view.isRichText = true
        view.importsGraphics = true
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticLinkDetectionEnabled = false
        view.smartInsertDeleteEnabled = true
        view.allowsDocumentBackgroundColorChange = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.focusRingType = .none
        view.textContainerInset = NSSize(width: 72, height: 120)
        view.textStorage?.delegate = view
        layoutManager.delegate = view
        view.wantsLayer = true
        NSSpellChecker.shared.ignoreWord("Notas", inSpellDocumentWithTag: view.spellCheckerDocumentTag)
        view.installOverlays()
        return view
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        updateInsets()
        if widthChanged { needsLayout = true }
    }

    private var contentWidth: CGFloat {
        let minMargin: CGFloat = 76
        return max(240, min(maxContentWidth, bounds.width - minMargin * 2))
    }

    func updateInsets() {
        let inset = NSSize(width: floor((bounds.width - contentWidth) / 2), height: topInset)
        if textContainerInset != inset { textContainerInset = inset }
        headerView?.frame = NSRect(x: inset.width, y: topInset - Self.headerHeight - 14,
                                   width: contentWidth, height: Self.headerHeight)
    }

    override func layout() {
        super.layout()
        positionRichBlocks()
    }

    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + richBlockHosts.values.sorted { $0.frame.minY < $1.frame.minY }
    }

    override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        if rejectsSeparatorDeletion(selection) { return }
        if selection.length == 0 {
            let ns = string as NSString
            let para = ns.paragraphRange(for: selection)
            if blockAttributes(at: selection.location).kind.isObject { deleteDivider(para); return }
            if selection.location < ns.length, ns.character(at: selection.location) == 10,
               NSMaxRange(para) < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(para), length: 0))
                if blockAttributes(at: next.location).kind.isObject { deleteDivider(next); return }
            }
        }
        super.deleteForward(sender)
    }

    // MARK: Styling

    func applyStyle(_ style: ResolvedStyle) {
        if styler.style.theme.id != style.theme.id, window != nil, let layer = enclosingScrollView?.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.28
            layer.add(fade, forKey: "themeFade")
        }
        styler.style = style
        overlays.style = style
        insertionPointColor = style.nsAccent
        selectedTextAttributes = [.backgroundColor: style.nsAccent.withAlphaComponent(style.theme.isDark ? 0.35 : 0.25)]
        linkTextAttributes = [.foregroundColor: style.nsAccent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
        maxContentWidth = style.width.points
        restyleAll()
    }

    func restyleAll() {
        guard let storage = textStorage else { return }
        isRestyling = true
        storage.beginEditing()
        styler.restyle(storage, around: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        isRestyling = false
        refreshTypingAttributes()
        connectRichBlocks()
        needsDisplay = true
    }

    /// Paragraphs touched by edits that still need a full restyle (numbering, neighbors).
    private var pendingRestyle: NSRange?
    private var restyleScheduled = false

    /// During an edit, style just the edited characters; whole paragraphs are restyled
    /// right after the edit (see `flushRestyle`), so the selection stays put.
    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard !isRestyling else { return }
        isRestyling = true
        styler.styleEditedCharacters(textStorage, range: editedRange)
        isRestyling = false
        pendingRestyle = pendingRestyle.map { NSUnionRange($0, editedRange) } ?? editedRange
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard pendingRestyle != nil, !restyleScheduled else { return }
        restyleScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushRestyle() }
    }

    func flushRestyle() {
        restyleScheduled = false
        guard let range = pendingRestyle, let storage = textStorage else { return }
        pendingRestyle = nil
        let length = storage.length
        let start = min(range.location, length)
        let clamped = NSRange(location: start, length: min(range.length, length - start))
        let selection = selectedRanges
        let typing = typingAttributes
        isRestyling = true
        storage.beginEditing()
        styler.restyle(storage, around: clamped)
        storage.endEditing()
        isRestyling = false
        if selectedRanges != selection { selectedRanges = selection }
        typingAttributes = typing
    }

    /// Lists, quotes, callouts and code get a fragment that draws their decorations.
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let attrs = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
            switch BlockAttributes(attrs).kind {
            case .bullet, .numbered, .checklist, .quote, .callout, .code, .divider:
                return NotasLayoutFragment(textElement: textElement, range: textElement.elementRange, attributes: attrs)
            default:
                break
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    func load(_ document: NoteDocument) {
        let text = RichTextCodec.attributedString(from: document)
        textStorage?.setAttributedString(text)
        restyleAll()
        undoManager?.removeAllActions()
    }

    /// Read straight from the text storage; `attributedString()` would copy the whole note first.
    var document: NoteDocument { textStorage.map { RichTextCodec.document(from: $0) } ?? .empty }

    // MARK: Paragraph helpers

    private var nsString: NSString { string as NSString }

    private func paragraphRange(at location: Int) -> NSRange {
        nsString.paragraphRange(for: NSRange(location: min(location, nsString.length), length: 0))
    }

    /// Paragraph content without its trailing newline.
    private func contentRange(of paragraph: NSRange) -> NSRange {
        var end = 0, contentsEnd = 0
        nsString.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: paragraph.location, length: 0))
        return NSRange(location: paragraph.location, length: max(0, contentsEnd - paragraph.location))
    }

    func blockAttributes(at location: Int) -> BlockAttributes {
        let para = paragraphRange(at: location)
        if para.location < nsString.length {
            var a = BlockAttributes(textStorage!.attributes(at: para.location, effectiveRange: nil))
            if para.location == 0 { a.kind = .title }
            return a
        }
        // Empty last paragraph: whatever we're about to type.
        if para.location == 0 { return BlockAttributes(kind: .title) }
        return BlockAttributes(typingAttributes)
    }

    private var currentLocation: Int { selectedRange().location }

    /// Whatever sets them, typing attributes on the first line are always the title's,
    /// so the caret and new text line up with the title (no list indent, right size).
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            guard textStorage != nil, paragraphRange(at: selectedRange().location).location == 0,
                  BlockAttributes(newValue).kind != .title || newValue[.paragraphStyle] == nil else {
                super.typingAttributes = newValue
                return
            }
            let marks = InlineMarks(rawValue: newValue[.notasMarks] as? Int ?? 0)
            super.typingAttributes = styler.typingAttributes(for: BlockAttributes(kind: .title), marks: marks)
        }
    }

    /// Paragraph ranges touched by the selection.
    private var selectedParagraphs: [NSRange] {
        let sel = selectedRange()
        var result: [NSRange] = []
        var loc = sel.location
        repeat {
            let p = paragraphRange(at: loc)
            result.append(p)
            if NSMaxRange(p) <= loc { break } // empty last paragraph
            loc = NSMaxRange(p)
        } while loc < NSMaxRange(sel)
        return result
    }

    /// Applies an attribute change to `range` with undo, then restyles.
    private func editAttributes(in range: NSRange, _ change: (NSTextStorage) -> Void) {
        guard let storage = textStorage else { return }
        guard range.length > 0 else { return }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        change(storage)
        storage.endEditing()
        didChangeText()
    }

    /// Gives an empty last paragraph a real newline so its block kind (a checkbox, a bullet)
    /// is drawn and saved right away, not only once something is typed.
    @discardableResult
    private func materializeEmptyLastParagraph(at location: Int, as block: BlockAttributes) -> Bool {
        let para = paragraphRange(at: location)
        guard para.length == 0, para.location == nsString.length, para.location > 0, block.kind != .body,
              let storage = textStorage else { return false }
        let at = para.location
        var newlineAttrs = styler.typingAttributes(for: block)
        newlineAttrs[.notasTerminal] = true
        let newline = NSAttributedString(string: "\n", attributes: newlineAttrs)
        if shouldChangeText(in: NSRange(location: at, length: 0), replacementString: "\n") {
            storage.replaceCharacters(in: NSRange(location: at, length: 0), with: newline)
            didChangeText()
        }
        setSelectedRange(NSRange(location: at, length: 0))
        typingAttributes = styler.typingAttributes(for: block)
        return true
    }

    private func refreshTypingAttributes() {
        let loc = currentLocation
        let block = blockAttributes(at: loc)
        var marks = InlineMarks()
        if loc > 0, loc <= nsString.length, paragraphRange(at: loc).location < loc {
            marks = InlineMarks(rawValue: textStorage?.attribute(.notasMarks, at: loc - 1, effectiveRange: nil) as? Int ?? 0)
        }
        typingAttributes = styler.typingAttributes(for: block, marks: marks)
    }

    // MARK: Blocks

    /// Sets the block kind for every selected paragraph. Choosing the kind they already
    /// have turns them back into body text.
    func setBlockKind(_ kind: BlockKind, toggle: Bool = true) {
        if kind.isAttachment { insertRichBlock(kind); return }
        if kind == .divider { insertDivider(); return }
        // The title line always stays the title.
        let paragraphs = selectedParagraphs.filter { $0.location > 0 }
            .filter { !blockAttributes(at: $0.location).kind.isObject }
        guard !paragraphs.isEmpty else { return }
        let allAlready = paragraphs.allSatisfy { blockAttributes(at: $0.location).kind == kind }
        let target: BlockKind = allAlready && toggle ? .body : kind

        let editable = paragraphs.filter { $0.length > 0 }
        if let first = editable.first, let last = editable.last {
            editAttributes(in: NSUnionRange(first, last)) { storage in
                for p in editable {
                    var a = BlockAttributes(storage.attributes(at: p.location, effectiveRange: nil))
                    a.kind = target
                    if !target.isList { a.indent = 0 }
                    storage.addAttributes(a.dictionary, range: p)
                    if target != .checklist { storage.removeAttribute(.notasChecked, range: p) }
                }
            }
        }
        // Empty last paragraph: give it a newline to hold the kind.
        if paragraphs.contains(where: { $0.length == 0 }) {
            var a = blockAttributes(at: currentLocation)
            a.kind = target
            if !target.isList { a.indent = 0 }
            if !materializeEmptyLastParagraph(at: currentLocation, as: a) {
                typingAttributes = styler.typingAttributes(for: a)
            }
            needsDisplay = true
        }
        onUserEdit?()
        scheduleOverlayUpdate()
    }

    func toggleChecked(paragraphAt location: Int) {
        let p = paragraphRange(at: location)
        guard p.length > 0 else { return }
        var a = blockAttributes(at: p.location)
        guard a.kind == .checklist else { return }
        a.checked.toggle()
        editAttributes(in: p) { $0.addAttribute(.notasChecked, value: a.checked, range: p) }
        onUserEdit?()
    }

    /// Toggle the checkbox on every selected checklist item (⌘↩).
    @objc func toggleCheckedAtSelection(_ sender: Any?) {
        let items = selectedParagraphs.filter { blockAttributes(at: $0.location).kind == .checklist && $0.length > 0 }
        guard !items.isEmpty else {
            setBlockKind(.checklist)
            return
        }
        let newValue = !items.allSatisfy { blockAttributes(at: $0.location).checked }
        editAttributes(in: NSUnionRange(items.first!, items.last!)) { storage in
            for p in items { storage.addAttribute(.notasChecked, value: newValue, range: p) }
        }
        onUserEdit?()
    }

    func changeIndent(by delta: Int) {
        let paragraphs = selectedParagraphs.filter { $0.length > 0 && blockAttributes(at: $0.location).kind.isList }
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        editAttributes(in: NSUnionRange(first, last)) { storage in
            for p in paragraphs {
                var a = BlockAttributes(storage.attributes(at: p.location, effectiveRange: nil))
                a.indent = NoteDocument.indent(applying: delta, to: a.indent)
                storage.removeAttribute(.notasIndent, range: p)
                storage.addAttributes(a.dictionary, range: p)
            }
        }
        onUserEdit?()
    }

    // MARK: Inline marks

    func toggleMark(_ mark: InlineMarks) {
        let sel = selectedRange()
        guard let storage = textStorage else { return }
        if sel.length == 0 {
            var current = InlineMarks(rawValue: typingAttributes[.notasMarks] as? Int ?? 0)
            current.formSymmetricDifference(mark)
            typingAttributes = styler.typingAttributes(for: blockAttributes(at: sel.location), marks: current)
            return
        }
        var allHave = true
        storage.enumerateAttribute(.notasMarks, in: sel) { value, r, stop in
            let text = nsString.substring(with: r)
            if text.trimmingCharacters(in: .newlines).isEmpty { return }
            if !InlineMarks(rawValue: value as? Int ?? 0).contains(mark) { allHave = false; stop.pointee = true }
        }
        editAttributes(in: sel) { storage in
            storage.enumerateAttribute(.notasMarks, in: sel) { value, r, _ in
                var m = InlineMarks(rawValue: value as? Int ?? 0)
                if allHave { m.remove(mark) } else { m.insert(mark) }
                if m.isEmpty { storage.removeAttribute(.notasMarks, range: r) }
                else { storage.addAttribute(.notasMarks, value: m.rawValue, range: r) }
            }
        }
        setSelectedRange(sel)
        onUserEdit?()
        scheduleOverlayUpdate()
    }

    /// Marks active at the cursor or across the whole selection (for toolbar state).
    var activeMarks: InlineMarks {
        let sel = selectedRange()
        if sel.length == 0 { return InlineMarks(rawValue: typingAttributes[.notasMarks] as? Int ?? 0) }
        var common: InlineMarks? = nil
        textStorage?.enumerateAttribute(.notasMarks, in: sel) { value, _, _ in
            let m = InlineMarks(rawValue: value as? Int ?? 0)
            common = common.map { $0.intersection(m) } ?? m
        }
        return common ?? []
    }

    func setLink(_ url: String?) {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        editAttributes(in: sel) { storage in
            if let url, !url.isEmpty { storage.addAttribute(.link, value: url, range: sel) }
            else { storage.removeAttribute(.link, range: sel) }
        }
        setSelectedRange(sel)
        onUserEdit?()
    }

    var linkAtSelection: String? {
        let sel = selectedRange()
        guard sel.location < nsString.length else { return nil }
        let value = textStorage?.attribute(.link, at: sel.location, effectiveRange: nil)
        return (value as? String) ?? (value as? URL)?.absoluteString
    }

    /// Highlight the selection (nil removes the highlight).
    func setHighlight(_ choice: HighlightChoice?) {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        editAttributes(in: sel) { storage in
            storage.enumerateAttribute(.notasMarks, in: sel) { value, r, _ in
                var m = InlineMarks(rawValue: value as? Int ?? 0)
                if choice == nil { m.remove(.highlight) } else { m.insert(.highlight) }
                if m.isEmpty { storage.removeAttribute(.notasMarks, range: r) } else { storage.addAttribute(.notasMarks, value: m.rawValue, range: r) }
            }
            if case .ink(let c) = choice { storage.addAttribute(.notasHighlightColor, value: c.rawValue, range: sel) }
            else { storage.removeAttribute(.notasHighlightColor, range: sel) }
        }
        setSelectedRange(sel)
        onUserEdit?()
        scheduleOverlayUpdate()
    }

    /// Color the selected text (nil restores the theme's color).
    func setInk(_ color: InkColor?) {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        editAttributes(in: sel) { storage in
            if let color { storage.addAttribute(.notasInk, value: color.rawValue, range: sel) }
            else { storage.removeAttribute(.notasInk, range: sel) }
        }
        setSelectedRange(sel)
        onUserEdit?()
        scheduleOverlayUpdate()
    }

    /// The single value of `key` across the selection, or nil if mixed/absent.
    private func uniformValue(_ key: NSAttributedString.Key) -> String? {
        let sel = selectedRange()
        guard sel.length > 0, let storage = textStorage else { return nil }
        var value: String?? = .none
        storage.enumerateAttribute(key, in: sel) { v, _, stop in
            let s = v as? String
            if case .some(let existing) = value, existing != s { value = .some(nil); stop.pointee = true }
            else if case .none = value { value = .some(s) }
        }
        return value ?? nil
    }

    // MARK: Dividers

    /// Inserts a divider after the current paragraph (or turns an empty one into a divider),
    /// leaving the cursor on a fresh line below it.
    func insertDivider() {
        guard let storage = textStorage else { return }
        let loc = currentLocation
        let para = paragraphRange(at: loc)
        guard para.location > 0 || nsString.length > 0 else { return }
        let content = contentRange(of: para)
        let hasTerminator = NSMaxRange(para) > NSMaxRange(content)
        let divider = BlockAttributes(kind: .divider).dictionary
        let body = BlockAttributes(kind: .body).dictionary
        let current = blockAttributes(at: para.location).dictionary

        let replacement = NSMutableAttributedString()
        let replaced: NSRange
        let isEmptyNonTitle = content.length == 0 && para.location > 0
        if isEmptyNonTitle {
            replaced = NSRange(location: para.location, length: hasTerminator ? 1 : 0)
        } else {
            replaced = NSRange(location: NSMaxRange(content), length: hasTerminator ? 1 : 0)
            replacement.append(NSAttributedString(string: "\n", attributes: current))
        }
        replacement.append(NSAttributedString(string: RichTextCodec.dividerCharacter, attributes: divider))
        replacement.append(NSAttributedString(string: "\n", attributes: divider))
        if hasTerminator { replacement.append(NSAttributedString(string: "\n", attributes: body)) }

        if shouldChangeText(in: replaced, replacementString: replacement.string) {
            storage.replaceCharacters(in: replaced, with: replacement)
            didChangeText()
        }
        let cursor = replaced.location + replacement.length - (hasTerminator ? 1 : 0)
        setSelectedRange(NSRange(location: cursor, length: 0))
        typingAttributes = styler.typingAttributes(for: BlockAttributes(kind: .body))
        onUserEdit?()
    }

    /// Removes a whole divider paragraph.
    private func deleteDivider(_ para: NSRange) {
        guard let storage = textStorage, shouldChangeText(in: para, replacementString: "") else { return }
        storage.replaceCharacters(in: para, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: min(para.location, nsString.length), length: 0))
    }

    // MARK: Typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        isEditingForSlash = true
        defer { isEditingForSlash = false }
        let sel = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""

        // Text typed at the very start of a paragraph belongs to *this* paragraph,
        // not the previous one (whose newline would otherwise lend its attributes).
        let para = paragraphRange(at: sel.location)
        if sel.location == para.location {
            var typing = typingAttributes
            for key in BlockAttributes.keys { typing[key] = nil }
            let block = blockAttributes(at: sel.location)
            typing.merge(block.dictionary) { $1 }
            typing[.paragraphStyle] = styler.paragraphStyle(for: block)
            typingAttributes = typing
        }

        // Typing on a divider starts a new line below it.
        if blockAttributes(at: sel.location).kind.isObject, para.location > 0, !text.isEmpty {
            setSelectedRange(NSRange(location: NSMaxRange(contentRange(of: para)), length: 0))
            splitParagraph(at: selectedRange().location, newBlock: BlockAttributes(kind: .body))
            super.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }

        if text == " ", sel.length == 0, applyMarkdownShortcut(at: sel.location) { return }

        // "/" at the start of a line (or after a space) opens the block menu.
        let opensSlash: Bool = {
            guard text == "/", sel.length == 0, slashStart == nil, para.location > 0 else { return false }
            if sel.location == para.location { return true }
            let before = nsString.character(at: sel.location - 1)
            return before == 0x20 || before == 0x09
        }()
        super.insertText(string, replacementRange: replacementRange)
        if opensSlash { openSlashMenu(at: sel.location) }
    }

    /// "- ", "1. ", "[] ", "# ", "> " and friends at the start of a body paragraph.
    private func applyMarkdownShortcut(at location: Int) -> Bool {
        let para = paragraphRange(at: location)
        guard para.location > 0 else { return false } // never in the title
        let prefixRange = NSRange(location: para.location, length: location - para.location)
        guard prefixRange.length > 0, prefixRange.length <= 4 else { return false }
        let prefix = nsString.substring(with: prefixRange)
        let current = blockAttributes(at: location)
        guard current.kind == .body || current.kind.isList else { return false }

        var target: BlockAttributes
        switch prefix {
        case "-", "*", "•": target = BlockAttributes(kind: .bullet)
        case "1.", "1)": target = BlockAttributes(kind: .numbered)
        case "[]", "[ ]": target = BlockAttributes(kind: .checklist)
        case "[x]", "[X]": target = BlockAttributes(kind: .checklist, checked: true)
        case "#": target = BlockAttributes(kind: .heading1)
        case "##": target = BlockAttributes(kind: .heading2)
        case "###": target = BlockAttributes(kind: .heading3)
        case ">": target = BlockAttributes(kind: .quote)
        case "!": target = BlockAttributes(kind: .callout)
        case "```": target = BlockAttributes(kind: .code)
        default: return false
        }
        target.indent = current.kind.isList ? current.indent : 0

        // Remove the prefix and convert the paragraph, as one undoable change.
        let rest = NSRange(location: location, length: NSMaxRange(para) - location)
        let replaced = NSRange(location: para.location, length: NSMaxRange(para) - para.location)
        let tail = NSMutableAttributedString(attributedString: textStorage!.attributedSubstring(from: rest))
        if tail.length > 0 {
            for key in BlockAttributes.keys { tail.removeAttribute(key, range: NSRange(location: 0, length: tail.length)) }
            tail.addAttributes(target.dictionary, range: NSRange(location: 0, length: tail.length))
        }
        if shouldChangeText(in: replaced, replacementString: tail.string) {
            textStorage?.replaceCharacters(in: replaced, with: tail)
            didChangeText()
        }
        setSelectedRange(NSRange(location: para.location, length: 0))
        typingAttributes = styler.typingAttributes(for: target)
        materializeEmptyLastParagraph(at: para.location, as: target)
        onUserEdit?()
        return true
    }

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        let para = paragraphRange(at: sel.location)
        let content = contentRange(of: para)
        let block = blockAttributes(at: sel.location)

        if sel.length == 0, block.kind.isObject, para.location > 0 {
            setSelectedRange(NSRange(location: NSMaxRange(content), length: 0))
            splitParagraph(at: NSMaxRange(content), newBlock: BlockAttributes(kind: .body))
            return
        }

        if sel.length == 0 {
            // Return on an empty list item: outdent, or leave the list.
            if block.kind.isList, content.length == 0 {
                if block.indent > 0 { changeIndentOfEmpty(block: block, para: para, delta: -1) }
                else { convertCurrent(to: BlockAttributes(kind: .body), para: para) }
                return
            }
            // Code blocks keep their lines together; Return on an empty last line exits.
            if block.kind == .code {
                let before = sel.location > para.location ? nsString.character(at: sel.location - 1) : 0
                if before == 0x2028, sel.location == NSMaxRange(content) {
                    insertText("", replacementRange: NSRange(location: sel.location - 1, length: 1))
                    splitParagraph(at: sel.location - 1, newBlock: BlockAttributes(kind: .body))
                } else {
                    insertText("\u{2028}", replacementRange: sel)
                }
                return
            }
        }

        var next = BlockAttributes(kind: block.kind.continuesOnReturn ? block.kind : .body,
                                   checked: false,
                                   indent: block.kind.isList ? block.indent : 0)
        if block.kind == .title { next = BlockAttributes(kind: .body) }
        if sel.length > 0 { delete(nil) }
        splitParagraph(at: selectedRange().location, newBlock: next)
    }

    override func insertLineBreak(_ sender: Any?) {
        if blockAttributes(at: selectedRange().location).kind.isObject { insertNewline(sender); return }
        insertText("\u{2028}", replacementRange: selectedRange())
    }

    /// Insert a paragraph break at `location`; the new paragraph gets `newBlock`.
    private func splitParagraph(at location: Int, newBlock: BlockAttributes) {
        guard let storage = textStorage else { return }
        let para = paragraphRange(at: location)
        let tailRange = NSRange(location: location, length: NSMaxRange(para) - location)
        // The new newline ends the current paragraph, so it takes the current paragraph's attributes.
        var breakAttrs = typingAttributes
        breakAttrs[.attachment] = nil
        for key in BlockAttributes.keys { breakAttrs[key] = nil }
        breakAttrs.merge(blockAttributes(at: location).dictionary) { $1 }

        let replacement = NSMutableAttributedString(string: "\n", attributes: breakAttrs)
        let tail = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: tailRange))
        if tail.length > 0 {
            let all = NSRange(location: 0, length: tail.length)
            for key in BlockAttributes.keys { tail.removeAttribute(key, range: all) }
            tail.addAttributes(newBlock.dictionary, range: all)
        }
        replacement.append(tail)

        if shouldChangeText(in: tailRange, replacementString: replacement.string) {
            storage.replaceCharacters(in: tailRange, with: replacement)
            didChangeText()
        }
        setSelectedRange(NSRange(location: location + 1, length: 0))
        typingAttributes = styler.typingAttributes(for: newBlock)
        materializeEmptyLastParagraph(at: location + 1, as: newBlock)
        scrollRangeToVisible(selectedRange())
        onUserEdit?()
    }

    private func convertCurrent(to block: BlockAttributes, para: NSRange) {
        if para.length > 0 {
            editAttributes(in: para) { storage in
                for key in BlockAttributes.keys { storage.removeAttribute(key, range: para) }
                storage.addAttributes(block.dictionary, range: para)
            }
        }
        typingAttributes = styler.typingAttributes(for: block)
        if para.length == 0 { materializeEmptyLastParagraph(at: para.location, as: block) }
        needsDisplay = true
        onUserEdit?()
    }

    private func changeIndentOfEmpty(block: BlockAttributes, para: NSRange, delta: Int) {
        var b = block
        b.indent = NoteDocument.indent(applying: delta, to: block.indent)
        convertCurrent(to: b, para: para)
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if rejectsSeparatorDeletion(sel) { return }
        if sel.length == 0, sel.location > 0 {
            let para = paragraphRange(at: sel.location)
            let block = blockAttributes(at: sel.location)
            // Backspace on a divider, or right after one, removes the divider.
            if block.kind.isObject { deleteDivider(para); return }
            if sel.location == para.location {
                let prev = paragraphRange(at: sel.location - 1)
                if blockAttributes(at: prev.location).kind.isObject { deleteDivider(prev); return }
            }
            // Backspace at the start of a styled paragraph removes the style first.
            if sel.location == para.location, block.kind != .body, block.kind != .title {
                if block.kind.isList, block.indent > 0 { changeIndentOfEmpty(block: block, para: para, delta: -1) }
                else { convertCurrent(to: BlockAttributes(kind: .body), para: para) }
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func insertTab(_ sender: Any?) {
        if adjustListIndent(by: 1) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if adjustListIndent(by: -1) { return }
        super.insertBacktab(sender)
    }

    /// List indent, including an empty item whose paragraph has no characters yet.
    private func adjustListIndent(by delta: Int) -> Bool {
        let block = blockAttributes(at: currentLocation)
        guard block.kind.isList else { return false }
        let para = paragraphRange(at: currentLocation)
        if contentRange(of: para).length == 0 {
            changeIndentOfEmpty(block: block, para: para, delta: delta)
        } else {
            changeIndent(by: delta)
        }
        return true
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isStructuredEdit || isRestyling {
            return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        }
        if (replacementString ?? "").isEmpty, rejectsSeparatorDeletion(affectedCharRange) {
            return false
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func didChangeText() {
        richTyping = nil
        flushRestyle()
        super.didChangeText()
        // Placeholders are drawn outside TextKit's glyph invalidation. Redraw the whole
        // transparent backing layer after the text state changes so the title placeholder
        // cannot remain underneath the first typed word.
        needsDisplay = true
        connectRichBlocks()
        onUserEdit?()
        updateSlashMenu()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting, selectedRange().length == 0 { refreshTypingAttributesIfNeeded() }
        if stillSelecting { hideFormatBar() } else { scheduleOverlayUpdate() }
        if slashStart != nil, !isEditingForSlash { validateSlashCursor() }
    }

    /// True while our own insert/delete is moving the cursor around the "/query".
    private var isEditingForSlash = false

    /// The menu belongs to the "/word" being typed; moving the cursor elsewhere closes it.
    private func validateSlashCursor() {
        guard let start = slashStart else { return }
        let sel = selectedRange()
        let para = paragraphRange(at: start)
        let inWord: Bool = {
            guard sel.length == 0, sel.location > start, sel.location <= NSMaxRange(contentRange(of: para)) else { return false }
            let typed = nsString.substring(with: NSRange(location: start, length: sel.location - start))
            return typed.hasPrefix("/") && !typed.dropFirst().contains(where: { $0.isWhitespace })
        }()
        if !inWord { closeSlashMenu() }
    }

    private func refreshTypingAttributesIfNeeded() {
        // Keep paragraph-level typing attributes in step with where the cursor is.
        let block = blockAttributes(at: currentLocation)
        if BlockAttributes(typingAttributes) != block || typingAttributes[.notasDecor] == nil {
            var marks = InlineMarks(rawValue: typingAttributes[.notasMarks] as? Int ?? 0)
            if paragraphRange(at: currentLocation).location == currentLocation { marks = [] }
            typingAttributes = styler.typingAttributes(for: block, marks: marks)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (location, rect) = checkboxHit(at: point) {
            let willCheck = !blockAttributes(at: location).checked
            toggleChecked(paragraphAt: location)
            celebrateCheckbox(in: rect, checked: willCheck)
            return
        }
        closeSlashMenu()
        isMouseSelecting = true
        super.mouseDown(with: event) // runs until mouse up
        isMouseSelecting = false
        scheduleOverlayUpdate()
    }

    /// A small ripple and a trackpad tap when an item is ticked.
    private func celebrateCheckbox(in rect: NSRect, checked: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(checked ? .levelChange : .generic, performanceTime: .now)
        guard checked, let host = layer else { return }
        let ring = CAShapeLayer()
        ring.frame = rect
        ring.path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: 5, cornerHeight: 5, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = styler.style.nsAccent.cgColor
        ring.lineWidth = 2
        host.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.9
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.38
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { ring.removeFromSuperlayer() }
    }

    /// Character location of the checklist paragraph whose checkbox is under `point`,
    /// plus the checkbox's rect in view coordinates.
    private func checkboxHit(at point: NSPoint) -> (Int, NSRect)? {
        guard let tlm = textLayoutManager, let tcs = textContentStorage else { return nil }
        let origin = textContainerOrigin
        let p = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = tlm.textLayoutFragment(for: p) as? NotasLayoutFragment,
              fragment.kind == .checklist else { return nil }
        let rect = fragment.markerRect.insetBy(dx: -6, dy: -5)
            .offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
        guard rect.contains(p) else { return nil }
        let box = fragment.markerRect
            .offsetBy(dx: fragment.layoutFragmentFrame.minX + origin.x, dy: fragment.layoutFragmentFrame.minY + origin.y)
        return (tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location), box)
    }

    // MARK: Overlays

    private func installOverlays() {
        let format = OverlayHostingView(rootView: FormatBar(model: overlays, editor: self))
        format.isHidden = true
        addSubview(format)
        formatHost = format

        let slash = OverlayHostingView(rootView: SlashMenu(model: overlays, editor: self))
        slash.isHidden = true
        addSubview(slash)
        slashHost = slash
    }

    func refocus() {
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        // Keep the format bar while its link field has focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder !== self else { return }
            if !self.overlays.isEditingLink { self.hideFormatBar() }
            self.closeSlashMenu()
        }
        return ok
    }

    private func scheduleOverlayUpdate() {
        guard !overlayUpdateScheduled else { return }
        overlayUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.overlayUpdateScheduled = false
            self?.updateOverlays()
        }
    }

    /// Rect (view coordinates) covering a character range; works for empty ranges (the caret).
    private func rect(for range: NSRange) -> NSRect? {
        guard let window else { return nil }
        let start = firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        let end = firstRect(forCharacterRange: NSRange(location: NSMaxRange(range), length: 0), actualRange: nil)
        guard start != .zero else { return nil }
        let a = convert(window.convertFromScreen(start), from: nil)
        let b = convert(window.convertFromScreen(end), from: nil)
        let r = a.union(b)
        return NSRect(x: r.minX, y: r.minY, width: max(r.width, 1), height: max(r.height, a.height))
    }

    func updateOverlays() {
        let sel = selectedRange()
        guard slashStart == nil, sel.length > 0, !isMouseSelecting,
              window?.firstResponder === self || overlays.isEditingLink,
              let host = formatHost, let selection = rect(for: sel) else {
            hideFormatBar()
            return
        }
        overlays.marks = activeMarks
        overlays.blockKind = blockAttributes(at: sel.location).kind
        overlays.ink = uniformValue(.notasInk).flatMap(InkColor.init(rawValue:))
        overlays.highlightColor = uniformValue(.notasHighlightColor).flatMap(InkColor.init(rawValue:))

        let size = host.fittingSize
        let minX = textContainerOrigin.x - 24
        let maxX = textContainerOrigin.x + contentWidth + 24 - size.width
        let x = max(minX, min(maxX, selection.midX - size.width / 2))
        var y = selection.minY - size.height - 10
        if y < visibleRect.minY + 48 { y = selection.maxY + 10 }
        host.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        if host.isHidden {
            host.alphaValue = 0
            host.isHidden = false
            addSubview(host, positioned: .above, relativeTo: nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                host.animator().alphaValue = 1
            }
        }
    }

    private func hideFormatBar() {
        guard let host = formatHost, !host.isHidden else { return }
        host.isHidden = true
        overlays.showColors = false
        overlays.isEditingLink = false
    }

    // MARK: Slash menu

    var isSlashMenuOpen: Bool { slashStart != nil }

    private func openSlashMenu(at location: Int) {
        slashStart = location
        overlays.slashQuery = ""
        overlays.slashItems = SlashItem.all
        overlays.slashSelection = 0
        hideFormatBar()
        // Position once the new character has been laid out.
        DispatchQueue.main.async { [weak self] in self?.positionSlashMenu() }
    }

    private func positionSlashMenu() {
        if let tlm = textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        guard let host = slashHost, let start = slashStart, let caret = rect(for: NSRange(location: start, length: 0)) else { return }
        let size = host.fittingSize
        var y = caret.maxY + 6
        if y + size.height > visibleRect.maxY - 8 { y = caret.minY - size.height - 6 }
        let x = max(textContainerOrigin.x - 24, min(caret.minX - 8, bounds.width - size.width - 12))
        host.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        if host.isHidden {
            host.isHidden = false
            addSubview(host, positioned: .above, relativeTo: nil)
        }
    }

    private func updateSlashMenu() {
        guard let start = slashStart else { return }
        let cursor = currentLocation
        guard selectedRange().length == 0, cursor > start, start < nsString.length,
              nsString.character(at: start) == 0x2F /* "/" */ else { closeSlashMenu(); return }
        let query = nsString.substring(with: NSRange(location: start + 1, length: cursor - start - 1))
        if query.contains(where: { $0.isWhitespace || $0.isNewline }) || query.count > 18 { closeSlashMenu(); return }
        let items = SlashItem.matching(query)
        if items.isEmpty { closeSlashMenu(); return }
        overlays.slashQuery = query
        overlays.slashItems = items
        overlays.slashSelection = min(overlays.slashSelection, items.count - 1)
        DispatchQueue.main.async { [weak self] in self?.positionSlashMenu() }
    }

    func closeSlashMenu() {
        slashStart = nil
        slashHost?.isHidden = true
    }

    func applySlashItem(_ item: SlashItem) {
        guard let start = slashStart else { return }
        let end = currentLocation
        closeSlashMenu()
        // Remove the "/query" text, but only if it's still exactly what was typed.
        let typedRange = NSRange(location: start, length: max(0, end - start))
        guard typedRange.length >= 1, NSMaxRange(typedRange) <= nsString.length,
              nsString.substring(with: typedRange) == "/" + overlays.slashQuery else { return }
        insertText("", replacementRange: typedRange)
        switch item.action {
        case .block(let kind): setBlockKind(kind, toggle: false)
        case .divider: insertDivider()
        case .scan: showScanMenu()
        }
        refocus()
    }

    override func doCommand(by selector: Selector) {
        if isSlashMenuOpen {
            switch selector {
            case #selector(moveDown(_:)):
                overlays.slashSelection = (overlays.slashSelection + 1) % max(overlays.slashItems.count, 1)
                return
            case #selector(moveUp(_:)):
                overlays.slashSelection = (overlays.slashSelection - 1 + overlays.slashItems.count) % max(overlays.slashItems.count, 1)
                return
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                if overlays.slashItems.indices.contains(overlays.slashSelection) {
                    applySlashItem(overlays.slashItems[overlays.slashSelection])
                }
                return
            case #selector(cancelOperation(_:)):
                closeSlashMenu()
                return
            default:
                break
            }
        }
        if selector == #selector(cancelOperation(_:)), let host = formatHost, !host.isHidden {
            hideFormatBar()
            return
        }
        super.doCommand(by: selector)
    }

    // MARK: Placeholder

    var placeholderTitle = "Title"
    var placeholderBody = "Start writing…"

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let s = styler.style
        let origin = textContainerOrigin
        if string.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: styler.baseFont(for: .title), .foregroundColor: s.nsTertiary.withAlphaComponent(0.6)]
            (placeholderTitle as NSString).draw(at: NSPoint(x: origin.x, y: origin.y), withAttributes: attrs)
        } else if !string.contains("\n"), let tlm = textLayoutManager {
            var maxY: CGFloat = 0
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { f in
                maxY = max(maxY, f.layoutFragmentFrame.maxY)
                return true
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: styler.baseFont(for: .body), .foregroundColor: s.nsTertiary.withAlphaComponent(0.7)]
            (placeholderBody as NSString).draw(at: NSPoint(x: origin.x, y: origin.y + maxY + 4), withAttributes: attrs)
        }
    }

    // MARK: Object paragraphs

    /// Selecting only a separator must not delete the neighboring object or merge it into text.
    private func rejectsSeparatorDeletion(_ range: NSRange) -> Bool {
        guard range.length > 0, isSeparatorOnly(range) else { return false }
        return separatorDeletionWouldMergeObject(range)
    }

    private func isSeparatorOnly(_ range: NSRange) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= nsString.length else { return false }
        for index in range.location..<NSMaxRange(range) {
            let character = nsString.character(at: index)
            if character != 0x0A && character != 0x0D { return false }
        }
        return true
    }

    private func separatorDeletionWouldMergeObject(_ range: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        let before = range.location > 0 ? paragraphRange(at: range.location - 1) : nil
        let afterLocation = NSMaxRange(range)
        let after = afterLocation < nsString.length ? paragraphRange(at: afterLocation) : nil
        return paragraphContainsObject(before, in: storage) || paragraphContainsObject(after, in: storage)
    }

    private func paragraphContainsObject(_ paragraph: NSRange?, in storage: NSAttributedString) -> Bool {
        guard let paragraph, paragraph.location < storage.length else { return false }
        let end = min(NSMaxRange(paragraph), storage.length)
        var index = paragraph.location
        while index < end {
            if isObjectPayload(storage, at: index) { return true }
            index += 1
        }
        return false
    }

    private func rangeIntersectsObject(_ range: NSRange) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let start = paragraphRange(at: min(range.location, storage.length))
        if paragraphContainsObject(start, in: storage) { return true }
        guard range.length > 0 else { return false }
        let end = paragraphRange(at: min(NSMaxRange(range) - 1, storage.length - 1))
        return paragraphContainsObject(end, in: storage)
    }

    private func containsObjectPayload(_ text: NSAttributedString) -> Bool {
        guard text.length > 0 else { return false }
        for index in 0..<text.length where isObjectPayload(text, at: index) { return true }
        return false
    }

    private func isObjectPayload(_ text: NSAttributedString, at index: Int) -> Bool {
        guard index < text.length else { return false }
        if text.attribute(.attachment, at: index, effectiveRange: nil) != nil { return true }
        let character = (text.string as NSString).character(at: index)
        guard character != 0x0A, character != 0x0D else { return false }
        guard BlockAttributes(text.attributes(at: index, effectiveRange: nil)).kind == .divider else { return false }
        return character == (RichTextCodec.dividerCharacter.utf16.first ?? 0)
    }

    /// Replaces `range` so attachments and dividers stay in their own paragraphs.
    @discardableResult
    private func replacePreservingObjects(in range: NSRange, with replacement: NSAttributedString) -> Bool {
        guard let storage = textStorage else { return false }
        if replacement.length == 0, rejectsSeparatorDeletion(range) { return true }

        let ns = string as NSString
        let insertingObjects = containsObjectPayload(replacement)
        let title = paragraphRange(at: 0)
        let keepTitle = insertingObjects && title.location == 0 && range.location <= NSMaxRange(title) && NSMaxRange(range) <= max(NSMaxRange(title), range.location)
            && (ns.length == 0 || paragraphRange(at: min(range.location, ns.length)).location == 0)

        let replaceRange: NSRange
        let inserted: NSAttributedString
        if keepTitle && ns.length > 0 {
            let at = NSMaxRange(paragraphRange(at: 0))
            var piece = NSMutableAttributedString()
            if at == 0 || ns.character(at: at - 1) != 10 {
                piece.append(NSAttributedString(string: "\n", attributes: BlockAttributes(kind: .title).dictionary))
            }
            let isolated = isolateObjects(replacement)
            piece.append(isolated)
            if at < ns.length, ns.character(at: at) != 10, !piece.string.hasSuffix("\n") {
                piece.append(NSAttributedString(string: "\n", attributes: BlockAttributes(kind: .body).dictionary))
            }
            replaceRange = NSRange(location: at, length: 0)
            inserted = piece
        } else if insertingObjects || rangeIntersectsObject(range) {
            let affected = affectedParagraphRange(for: range)
            let spliced = NSMutableAttributedString(attributedString: affected.length == 0 ? NSAttributedString() : storage.attributedSubstring(from: affected))
            let relativeLocation = min(max(0, range.location - affected.location), spliced.length)
            let relativeLength = min(range.length, max(0, spliced.length - relativeLocation))
            spliced.replaceCharacters(in: NSRange(location: relativeLocation, length: relativeLength), with: replacement)
            var isolated = NSMutableAttributedString(attributedString: isolateObjects(spliced))
            let endedWithBreak = affected.length > 0 && NSMaxRange(affected) <= ns.length && ns.character(at: NSMaxRange(affected) - 1) == 10
            let moreAfter = NSMaxRange(affected) < ns.length
            if (endedWithBreak || moreAfter), isolated.length == 0 || !isolated.string.hasSuffix("\n") {
                let seed = isolated.length > 0 ? isolated.attributes(at: isolated.length - 1, effectiveRange: nil) : BlockAttributes(kind: .body).dictionary
                var breakAttrs = seed
                breakAttrs[.attachment] = nil
                breakAttrs[.notasTerminal] = nil
                isolated.append(NSAttributedString(string: "\n", attributes: breakAttrs))
            }
            replaceRange = affected
            inserted = isolated
        } else {
            replaceRange = range
            inserted = replacement
        }

        isStructuredEdit = true
        defer { isStructuredEdit = false }
        guard shouldChangeText(in: replaceRange, replacementString: inserted.string) else { return false }
        breakUndoCoalescing()
        storage.replaceCharacters(in: replaceRange, with: inserted)
        didChangeText()
        let caret = min(replaceRange.location + inserted.length, storage.length)
        setSelectedRange(NSRange(location: caret, length: 0))
        typingAttributes = styler.typingAttributes(for: BlockAttributes(kind: .body))
        return true
    }

    private func affectedParagraphRange(for range: NSRange) -> NSRange {
        let ns = nsString
        if ns.length == 0 { return NSRange(location: 0, length: 0) }
        if range.location >= ns.length {
            return ns.paragraphRange(for: NSRange(location: ns.length, length: 0))
        }
        let start = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
        guard range.length > 0 else { return start }
        let endLocation = min(NSMaxRange(range) - 1, ns.length - 1)
        return NSUnionRange(start, ns.paragraphRange(for: NSRange(location: endLocation, length: 0)))
    }

    /// Gives every object payload its own paragraph without dropping the text beside it.
    private func isolateObjects(_ source: NSAttributedString) -> NSAttributedString {
        let ns = source.string as NSString
        guard source.length > 0, containsObjectPayload(source) else { return source }
        let out = NSMutableAttributedString()
        var text = NSMutableAttributedString()

        func newlineAttributes(from attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var copy = attrs
            copy[.attachment] = nil
            copy[.notasTerminal] = nil
            return copy
        }
        func flushText(terminating: Bool) {
            guard text.length > 0 else { return }
            out.append(text)
            if terminating, !(text.string as NSString).hasSuffix("\n") {
                let attrs = text.attributes(at: text.length - 1, effectiveRange: nil)
                out.append(NSAttributedString(string: "\n", attributes: newlineAttributes(from: attrs)))
            }
            text = NSMutableAttributedString()
        }
        func moreContent(after index: Int) -> Bool {
            var next = index + 1
            if next < ns.length {
                let character = ns.character(at: next)
                if character == 0x0A || character == 0x0D { next += 1 }
            }
            return next < ns.length
        }

        var index = 0
        while index < ns.length {
            if isObjectPayload(source, at: index) {
                let follows = moreContent(after: index)
                flushText(terminating: true)
                out.append(source.attributedSubstring(from: NSRange(location: index, length: 1)))
                if follows {
                    let attrs = newlineAttributes(from: source.attributes(at: index, effectiveRange: nil))
                    out.append(NSAttributedString(string: "\n", attributes: attrs))
                }
                index += 1
                if index < ns.length {
                    let character = ns.character(at: index)
                    if character == 0x0A || character == 0x0D { index += 1 }
                }
            } else {
                text.append(source.attributedSubstring(from: NSRange(location: index, length: 1)))
                index += 1
            }
        }
        if text.length > 0 { out.append(text) }
        return out
    }

    // MARK: Pasteboard

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.notasBlocks, .string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.notasBlocks, .fileURL, .png, .tiff, .pdf, .string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let fragment = attributedSubstring(forProposedRange: selectedRange(), actualRange: nil) ?? NSAttributedString()
        let doc = RichTextCodec.document(from: fragment, forceTitle: false)
        if type == .notasBlocks {
            do {
                let payload = try BlockClipboard(document: doc, source: noteAssets)
                return pboard.setData(try JSONEncoder().encode(payload), forType: .notasBlocks)
            } catch { presentAssetError(error); return false }
        }
        if type == .string { return pboard.setString(doc.plainText, forType: .string) }
        return super.writeSelection(to: pboard, type: type)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .notasBlocks, let data = pboard.data(forType: .notasBlocks) {
            do {
                let doc: NoteDocument
                if let clipboard = try? JSONDecoder().decode(BlockClipboard.self, from: data) {
                    doc = try clipboard.imported(into: noteAssets).normalizingExternalIndentation()
                } else {
                    doc = try JSONDecoder().decode(NoteDocument.self, from: data).normalizingExternalIndentation()
                }
                let text = RichTextCodec.attributedString(from: doc)
                return replacePreservingObjects(in: selectedRange(), with: text)
            } catch { presentAssetError(error); return false }
        }
        if type == .string, let plain = pboard.string(forType: .string) {
            let block = blockAttributes(at: selectedRange().location)
            let typing = styler.typingAttributes(for: block.kind.isObject ? BlockAttributes(kind: .body) : block)
            let text = NSAttributedString(string: plain, attributes: typing)
            if containsObjectPayload(text) || rangeIntersectsObject(selectedRange()) {
                return replacePreservingObjects(in: selectedRange(), with: text)
            }
        }
        if [.fileURL, .png, .tiff, .pdf].contains(type) { return receiveImages(from: pboard) }
        return super.readSelection(from: pboard, type: type)
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        if receiveImages(from: pboard) { return true }
        return super.readSelection(from: pboard)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let type = returnType, NSImage.imageTypes.contains(type.rawValue) || type == .pdf { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        if receiveImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }
}
