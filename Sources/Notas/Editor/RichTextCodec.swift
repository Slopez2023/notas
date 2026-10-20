import AppKit

extension NSAttributedString.Key {
    // Semantic, saved with the note.
    static let notasBlock = NSAttributedString.Key("notas.block")      // BlockKind raw value (paragraph-wide)
    static let notasChecked = NSAttributedString.Key("notas.checked")  // Bool (paragraph-wide)
    static let notasIndent = NSAttributedString.Key("notas.indent")    // Int (paragraph-wide)
    static let notasMarks = NSAttributedString.Key("notas.marks")      // InlineMarks raw value
    static let notasHighlightColor = NSAttributedString.Key("notas.highlightColor") // InkColor raw value
    static let notasInk = NSAttributedString.Key("notas.ink")          // InkColor raw value
    /// Internal marker on the synthetic terminator of a final empty non-body block.
    /// It is not a character, and it is never written to JSON or plain clipboard text.
    static let notasTerminal = NSAttributedString.Key("notas.terminal")

    // Presentation only, recomputed by the styler and read by the layout fragment.
    static let notasOrdinal = NSAttributedString.Key("notas.ordinal")  // Int, position in a numbered list
    static let notasDecor = NSAttributedString.Key("notas.decor")      // DecorColors
}

/// Colors the layout fragment needs to draw checkboxes, bullets and block backgrounds.
final class DecorColors: NSObject {
    let accent: NSColor
    let muted: NSColor
    let panel: NSColor
    let text: NSColor
    init(accent: NSColor, muted: NSColor, panel: NSColor, text: NSColor) {
        self.accent = accent
        self.muted = muted
        self.panel = panel
        self.text = text
    }
}

/// Paragraph-level semantic attributes.
struct BlockAttributes: Hashable {
    var kind: BlockKind = .body
    var checked: Bool = false
    var indent: Int = 0

    init(kind: BlockKind = .body, checked: Bool = false, indent: Int = 0) {
        self.kind = kind
        self.checked = checked
        self.indent = indent
    }

    init(_ attrs: [NSAttributedString.Key: Any]) {
        kind = (attrs[.notasBlock] as? String).flatMap(BlockKind.init(rawValue:)) ?? .body
        checked = attrs[.notasChecked] as? Bool ?? false
        indent = attrs[.notasIndent] as? Int ?? 0
    }

    var dictionary: [NSAttributedString.Key: Any] {
        var d: [NSAttributedString.Key: Any] = [.notasBlock: kind.rawValue]
        if kind == .checklist { d[.notasChecked] = checked }
        if indent > 0 { d[.notasIndent] = indent }
        return d
    }

    static let keys: [NSAttributedString.Key] = [.notasBlock, .notasChecked, .notasIndent]
}

/// Converts between the saved `NoteDocument` and the editor's attributed text.
enum RichTextCodec {
    /// A divider paragraph holds this one (invisible) character so it has something to lay out.
    static let dividerCharacter = "\u{2500}"

    static func attributedString(from document: NoteDocument) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let last = document.blocks.count - 1
        for (i, block) in document.blocks.enumerated() {
            let semantic = BlockAttributes(kind: block.kind, checked: block.checked ?? false, indent: NoteDocument.normalizedIndent(block.indent ?? 0))
            let blockAttrs = semantic.dictionary
            let isLast = i == last
            if block.kind.isAttachment {
                var attrs = blockAttrs
                attrs[.attachment] = RichBlockAttachment(block: block)
                out.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
                if !isLast { out.append(NSAttributedString(string: "\n", attributes: blockAttrs)) }
            } else if block.kind == .divider {
                out.append(NSAttributedString(string: dividerCharacter, attributes: blockAttrs))
                if !isLast { out.append(NSAttributedString(string: "\n", attributes: blockAttrs)) }
            } else {
                var wroteText = false
                for run in block.runs where !run.text.isEmpty {
                    wroteText = true
                    var attrs = blockAttrs
                    if !run.marks.isEmpty { attrs[.notasMarks] = run.marks.rawValue }
                    if let link = run.link { attrs[.link] = link }
                    if let c = run.highlightColor { attrs[.notasHighlightColor] = c.rawValue }
                    if let c = run.ink { attrs[.notasInk] = c.rawValue }
                    out.append(NSAttributedString(string: run.text, attributes: attrs))
                }
                if !isLast {
                    out.append(NSAttributedString(string: "\n", attributes: blockAttrs))
                } else if !wroteText && block.kind != .body && block.kind != .title {
                    // A final empty title stays an empty string so the caret remains in the title.
                    // Other empty blocks need a newline or their kind is dropped on the way back.
                    var terminator = blockAttrs
                    terminator[.notasTerminal] = true
                    out.append(NSAttributedString(string: "\n", attributes: terminator))
                }
            }
        }
        return out
    }

    /// - Parameter forceTitle: treat the first paragraph as the note title (false for clipboard fragments).
    static func document(from string: NSAttributedString, forceTitle: Bool = true) -> NoteDocument {
        let ns = string.string as NSString
        let length = ns.length
        var parsed: [Block] = []
        var start = 0

        while true {
            var end = 0, contentsEnd = 0
            ns.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let content = NSRange(location: start, length: max(0, contentsEnd - start))
            parsed.append(contentsOf: blocks(in: string, content: content, paragraphStart: start, forceTitle: forceTitle, emitted: parsed.count))

            if end >= length {
                // A newline ends a paragraph. Without the terminal marker it also means a real empty block follows.
                if end > contentsEnd, length > 0, !hasTerminalMarker(string, at: contentsEnd) {
                    parsed.append(Block(kind: .body, runs: []))
                }
                break
            }
            start = end
        }
        return parsed.isEmpty ? .empty : NoteDocument(blocks: parsed)
    }

    private static func hasTerminalMarker(_ string: NSAttributedString, at location: Int) -> Bool {
        guard location < string.length else { return false }
        return (string.attribute(.notasTerminal, at: location, effectiveRange: nil) as? Bool) == true
    }

    /// One paragraph may contain text and payload characters. Each object becomes its own block
    /// so neither the text nor the payload is dropped.
    private static func blocks(in string: NSAttributedString, content: NSRange, paragraphStart: Int, forceTitle: Bool, emitted: Int) -> [Block] {
        let ns = string.string as NSString
        let length = ns.length
        let attrs = paragraphStart < length ? BlockAttributes(string.attributes(at: paragraphStart, effectiveRange: nil)) : BlockAttributes()
        if content.length == 0 {
            return [block(attrs: attrs, runs: [], attachment: nil, forceTitle: forceTitle, index: emitted)]
        }
        let fragment = ns.substring(with: content)
        if !fragment.contains("\u{FFFC}"), !fragment.contains(dividerCharacter) {
            let attachment = string.attribute(.attachment, at: content.location, effectiveRange: nil) as? RichBlockAttachment
            let textAttrs = attrs.kind == .divider ? BlockAttributes(kind: .body, indent: attrs.indent) : attrs
            return [block(attrs: textAttrs, runs: runs(in: string, range: content), attachment: attachment, forceTitle: forceTitle, index: emitted)]
        }

        var pieces: [Block] = []
        var textStart: Int?
        func flushText(upTo end: Int) {
            guard let start = textStart, end > start else { textStart = nil; return }
            let range = NSRange(location: start, length: end - start)
            let textAttrs = BlockAttributes(string.attributes(at: start, effectiveRange: nil))
            let kindAttrs = textAttrs.kind == .divider ? BlockAttributes(kind: .body, indent: textAttrs.indent) : textAttrs
            pieces.append(block(attrs: kindAttrs, runs: runs(in: string, range: range), attachment: nil, forceTitle: forceTitle, index: emitted + pieces.count))
            textStart = nil
        }
        var index = content.location
        while index < NSMaxRange(content) {
            if let attachment = string.attribute(.attachment, at: index, effectiveRange: nil) as? RichBlockAttachment {
                flushText(upTo: index)
                pieces.append(attachment.block)
                index += 1
            } else if isDividerObject(string, at: index) {
                flushText(upTo: index)
                pieces.append(block(attrs: BlockAttributes(kind: .divider), runs: [], attachment: nil, forceTitle: forceTitle, index: emitted + pieces.count))
                index += 1
            } else {
                if textStart == nil { textStart = index }
                index += 1
            }
        }
        flushText(upTo: NSMaxRange(content))
        return pieces.isEmpty ? [block(attrs: attrs, runs: [], attachment: nil, forceTitle: forceTitle, index: emitted)] : pieces
    }

    private static func isDividerObject(_ string: NSAttributedString, at index: Int) -> Bool {
        guard index < string.length else { return false }
        let character = (string.string as NSString).character(at: index)
        guard character != 0x0A, character != 0x0D else { return false }
        guard BlockAttributes(string.attributes(at: index, effectiveRange: nil)).kind == .divider else { return false }
        return character == (dividerCharacter.utf16.first ?? 0)
    }

    private static func block(attrs: BlockAttributes, runs: [InlineRun], attachment: RichBlockAttachment?, forceTitle: Bool, index: Int) -> Block {
        if let attachment, attrs.kind.isAttachment || attachment.block.kind.isAttachment {
            return attachment.block
        }
        var kind = attrs.kind
        if forceTitle, !kind.isObject { kind = index == 0 ? .title : (kind == .title ? .body : kind) }
        let indent = attrs.indent > 0 ? NoteDocument.normalizedIndent(attrs.indent) : nil
        return Block(kind: kind,
                     checked: kind == .checklist ? attrs.checked : nil,
                     indent: indent,
                     runs: kind == .divider ? [] : runs)
    }

    private static func runs(in string: NSAttributedString, range: NSRange) -> [InlineRun] {
        guard range.length > 0 else { return [] }
        var result: [InlineRun] = []
        string.enumerateAttributes(in: range) { attrs, r, _ in
            let text = (string.string as NSString).substring(with: r)
            let marks = InlineMarks(rawValue: attrs[.notasMarks] as? Int ?? 0)
            let link: String? = (attrs[.link] as? String) ?? (attrs[.link] as? URL)?.absoluteString
            let highlight = marks.contains(.highlight) ? (attrs[.notasHighlightColor] as? String).flatMap(InkColor.init(rawValue:)) : nil
            let ink = (attrs[.notasInk] as? String).flatMap(InkColor.init(rawValue:))
            if var last = result.last, last.marks == marks, last.link == link, last.highlightColor == highlight, last.ink == ink {
                last.text += text
                result[result.count - 1] = last
            } else {
                result.append(InlineRun(text: text, marks: marks, link: link, highlightColor: highlight, ink: ink))
            }
        }
        return result
    }
}
