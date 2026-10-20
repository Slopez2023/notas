import AppKit

extension NSAttributedString.Key {
    // Semantic, saved with the note.
    static let notasBlock = NSAttributedString.Key("notas.block")      // BlockKind raw value (paragraph-wide)
    static let notasChecked = NSAttributedString.Key("notas.checked")  // Bool (paragraph-wide)
    static let notasIndent = NSAttributedString.Key("notas.indent")    // Int (paragraph-wide)
    static let notasMarks = NSAttributedString.Key("notas.marks")      // InlineMarks raw value
    static let notasHighlightColor = NSAttributedString.Key("notas.highlightColor") // InkColor raw value
    static let notasInk = NSAttributedString.Key("notas.ink")          // InkColor raw value

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
struct BlockAttributes: Equatable {
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
        for (i, block) in document.blocks.enumerated() {
            let blockAttrs = BlockAttributes(kind: block.kind, checked: block.checked ?? false, indent: block.indent ?? 0).dictionary
            if block.kind.isAttachment {
                var attrs = blockAttrs
                attrs[.attachment] = RichBlockAttachment(block: block)
                out.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
            } else if block.kind == .divider {
                out.append(NSAttributedString(string: dividerCharacter, attributes: blockAttrs))
            } else {
                for run in block.runs where !run.text.isEmpty {
                    var attrs = blockAttrs
                    if !run.marks.isEmpty { attrs[.notasMarks] = run.marks.rawValue }
                    if let link = run.link { attrs[.link] = link }
                    if let c = run.highlightColor { attrs[.notasHighlightColor] = c.rawValue }
                    if let c = run.ink { attrs[.notasInk] = c.rawValue }
                    out.append(NSAttributedString(string: run.text, attributes: attrs))
                }
            }
            if i < document.blocks.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: blockAttrs))
            }
        }
        return out
    }

    /// - Parameter forceTitle: treat the first paragraph as the note title (false for clipboard fragments).
    static func document(from string: NSAttributedString, forceTitle: Bool = true) -> NoteDocument {
        let ns = string.string as NSString
        let length = ns.length
        var blocks: [Block] = []
        var start = 0

        while true {
            var end = 0, contentsEnd = 0
            ns.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))

            let attrs = start < length ? BlockAttributes(string.attributes(at: start, effectiveRange: nil)) : BlockAttributes()
            var kind = attrs.kind
            if forceTitle { kind = blocks.isEmpty ? .title : (kind == .title ? .body : kind) }

            let content = NSRange(location: start, length: contentsEnd - start)
            if kind.isAttachment, start < length,
               let attachment = string.attribute(.attachment, at: start, effectiveRange: nil) as? RichBlockAttachment {
                blocks.append(attachment.block)
            } else {
                blocks.append(Block(kind: kind,
                                    checked: kind == .checklist ? attrs.checked : nil,
                                    indent: attrs.indent > 0 ? attrs.indent : nil,
                                    runs: kind == .divider ? [] : runs(in: string, range: content)))
            }

            if end >= length {
                // Text ending in a newline has one more, empty paragraph.
                if end > contentsEnd, length > 0 {
                    blocks.append(Block(kind: .body, runs: []))
                }
                break
            }
            start = end
        }
        return NoteDocument(blocks: blocks)
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
