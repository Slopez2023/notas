import AppKit

/// Turns semantic attributes (block kind, marks) into fonts, colors and paragraph styles
/// for the current theme. Runs on every edit for the touched paragraphs.
struct EditorStyler {
    var style: ResolvedStyle

    static let listIndent: CGFloat = 28
    static let nestedIndent: CGFloat = 24
    static let boxPadding: CGFloat = 14

    // MARK: Fonts

    var bodySize: CGFloat { style.textSize }

    func baseFont(for kind: BlockKind) -> NSFont {
        let s = bodySize
        switch kind {
        case .title: return style.titleFont.nsFont(size: round(s * 2.15), weight: .semibold)
        case .heading1: return style.titleFont.nsFont(size: round(s * 1.6), weight: .semibold)
        case .heading2: return style.bodyFont.nsFont(size: round(s * 1.2), weight: .semibold)
        case .heading3: return style.bodyFont.nsFont(size: s, weight: .semibold)
        case .quote: return italic(style.titleFont.nsFont(size: round(s * 1.12)))
        case .code: return FontChoice.mono.nsFont(size: round(s * 0.88))
        case .divider: return .systemFont(ofSize: s)
        default: return style.bodyFont.nsFont(size: s)
        }
    }

    private func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private func bold(_ font: NSFont) -> NSFont {
        if style.bodyFont == .inter, font.familyName == "Inter" {
            let isItalic = font.fontDescriptor.symbolicTraits.contains(.italic)
            let f = NSFont.inter(size: font.pointSize, weight: .bold)
            return isItalic ? italic(f) : f
        }
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    func font(for kind: BlockKind, marks: InlineMarks) -> NSFont {
        var f = baseFont(for: kind)
        if marks.contains(.code), kind != .code {
            f = FontChoice.mono.nsFont(size: round(f.pointSize * 0.9))
        }
        if marks.contains(.bold) { f = bold(f) }
        if marks.contains(.italic) { f = italic(f) }
        return f
    }

    // MARK: Paragraph styles

    func paragraphStyle(for attrs: BlockAttributes) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let s = bodySize
        let spacing = style.lineSpacing
        p.lineHeightMultiple = 1.42 * spacing
        p.paragraphSpacing = round(s * 0.55)
        p.paragraphSpacingBefore = 0

        switch attrs.kind {
        case .title:
            p.lineHeightMultiple = 1.08
            p.paragraphSpacing = round(s * 1.1)
        case .heading1:
            p.lineHeightMultiple = 1.12
            p.paragraphSpacingBefore = round(s * 1.2)
            p.paragraphSpacing = round(s * 0.45)
        case .heading2:
            p.lineHeightMultiple = 1.2
            p.paragraphSpacingBefore = round(s * 0.9)
            p.paragraphSpacing = round(s * 0.35)
        case .heading3:
            p.lineHeightMultiple = 1.25
            p.paragraphSpacingBefore = round(s * 0.6)
            p.paragraphSpacing = round(s * 0.25)
        case .bullet, .numbered, .checklist:
            let indent = Self.listIndent + CGFloat(attrs.indent) * Self.nestedIndent
            p.headIndent = indent
            p.firstLineHeadIndent = indent
            p.paragraphSpacing = round(s * 0.3)
        case .quote:
            p.headIndent = 20
            p.firstLineHeadIndent = 20
            p.lineHeightMultiple = 1.35 * spacing
            p.paragraphSpacingBefore = round(s * 0.4)
            p.paragraphSpacing = round(s * 0.9)
        case .callout, .code:
            p.headIndent = Self.boxPadding + 4
            p.firstLineHeadIndent = Self.boxPadding + 4
            p.tailIndent = -Self.boxPadding
            p.lineHeightMultiple = (attrs.kind == .code ? 1.3 : 1.38) * spacing
            p.paragraphSpacingBefore = round(s * 0.9)
            p.paragraphSpacing = round(s * 1.2)
        case .divider:
            p.lineHeightMultiple = 1
            p.paragraphSpacingBefore = round(s * 0.3)
            p.paragraphSpacing = round(s * 0.5)
        case .gallery, .table, .board, .columns, .sketch:
            p.lineHeightMultiple = 1
            p.paragraphSpacingBefore = 8
            p.paragraphSpacing = 18
        case .body:
            break
        }
        return p
    }

    // MARK: Restyling

    var decor: DecorColors {
        DecorColors(accent: style.nsAccent,
                    muted: style.nsTertiary,
                    panel: style.theme.isDark ? style.nsSurface : style.nsSurface,
                    text: style.nsText)
    }

    /// Restyle every paragraph touching `range`, widened to whole paragraphs and to whole lists
    /// (numbering depends on neighbors).
    func restyle(_ storage: NSTextStorage, around range: NSRange) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let clamped = NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length)))
        var target = ns.paragraphRange(for: clamped)

        // Widen backward and forward across neighboring list paragraphs.
        while target.location > 0, target.location < ns.length,
              BlockAttributes(storage.attributes(at: target.location, effectiveRange: nil)).kind.isList {
            let prev = ns.paragraphRange(for: NSRange(location: target.location - 1, length: 0))
            guard BlockAttributes(storage.attributes(at: prev.location, effectiveRange: nil)).kind.isList else { break }
            target = NSUnionRange(prev, target)
        }
        while NSMaxRange(target) < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(target), length: 0))
            guard BlockAttributes(storage.attributes(at: next.location, effectiveRange: nil)).kind.isList else { break }
            target = NSUnionRange(target, next)
        }

        // Ordinal counters per indent level for numbered lists, seeded from the paragraph before `target`.
        var counters: [Int: Int] = [:]
        let decor = self.decor

        var location = target.location
        while location < NSMaxRange(target) {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var attrs = BlockAttributes(storage.attributes(at: para.location, effectiveRange: nil))

            // The first paragraph is always the title; no other paragraph can be.
            if para.location == 0 { attrs.kind = .title } else if attrs.kind == .title { attrs.kind = .body }
            if !attrs.kind.isList { attrs.indent = 0 }

            // Numbering.
            var ordinal = 0
            if attrs.kind == .numbered {
                counters = counters.filter { $0.key <= attrs.indent }
                ordinal = (counters[attrs.indent] ?? 0) + 1
                counters[attrs.indent] = ordinal
            } else if attrs.kind.isList {
                counters = counters.filter { $0.key < attrs.indent }
            } else {
                counters.removeAll()
            }

            applyParagraph(storage, range: para, attrs: attrs, ordinal: ordinal, decor: decor)
            location = NSMaxRange(para)
        }
    }

    /// Style only the characters in `range`, using each paragraph's existing block attributes.
    /// Safe to call while the text storage is processing an edit: it never touches attributes
    /// outside `range`, which would make the text view move the selection.
    func styleEditedCharacters(_ storage: NSTextStorage, range: NSRange) {
        let ns = storage.string as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return }
        let decor = self.decor
        var location = range.location
        while location < NSMaxRange(range) {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var attrs = BlockAttributes(storage.attributes(at: para.location, effectiveRange: nil))
            if para.location == 0 { attrs.kind = .title } else if attrs.kind == .title { attrs.kind = .body }
            if !attrs.kind.isList { attrs.indent = 0 }
            let ordinal = storage.attribute(.notasOrdinal, at: para.location, effectiveRange: nil) as? Int ?? (attrs.kind == .numbered ? 1 : 0)
            let slice = NSIntersectionRange(para, range)
            if slice.length > 0 {
                applyParagraph(storage, range: slice, attrs: attrs, ordinal: ordinal, decor: decor)
            }
            location = max(NSMaxRange(para), location + 1)
        }
    }

    private func applyParagraph(_ storage: NSTextStorage, range: NSRange, attrs: BlockAttributes, ordinal: Int, decor: DecorColors) {
        // Normalize the paragraph-wide semantic attributes.
        for key in BlockAttributes.keys { storage.removeAttribute(key, range: range) }
        storage.addAttributes(attrs.dictionary, range: range)
        storage.addAttribute(.paragraphStyle, value: paragraphStyle(for: attrs), range: range)
        storage.addAttribute(.notasDecor, value: decor, range: range)
        if ordinal > 0 {
            storage.addAttribute(.notasOrdinal, value: ordinal, range: range)
        } else {
            storage.removeAttribute(.notasOrdinal, range: range)
        }

        let done = attrs.kind == .checklist && attrs.checked
        let baseColor: NSColor = {
            switch attrs.kind {
            case .title, .heading1, .heading2: return style.nsText
            case .heading3: return style.nsText
            case .quote: return style.nsSecondary
            case .callout: return style.nsText
            default: return style.nsSecondary
            }
        }()

        if attrs.kind == .divider {
            storage.addAttributes([.font: baseFont(for: .divider), .foregroundColor: NSColor.clear], range: range)
            for key: NSAttributedString.Key in [.notasMarks, .notasInk, .notasHighlightColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .link] {
                storage.removeAttribute(key, range: range)
            }
            return
        }

        let dark = style.theme.isDark
        storage.enumerateAttributes(in: range) { attributes, r, _ in
            let marks = InlineMarks(rawValue: attributes[.notasMarks] as? Int ?? 0)
            let ink = (attributes[.notasInk] as? String).flatMap(InkColor.init(rawValue:))
            let highlightColor = (attributes[.notasHighlightColor] as? String).flatMap(InkColor.init(rawValue:))
            let inkColor = ink.map { NSColor(hex: dark ? $0.hex : $0.deepHex) }
            var visual: [NSAttributedString.Key: Any] = [
                .font: font(for: attrs.kind, marks: marks),
                .foregroundColor: done ? style.nsTertiary : (inkColor ?? baseColor),
            ]
            if attrs.kind == .heading3 { visual[.kern] = 0.2 }
            storage.addAttributes(visual, range: r)

            if marks.contains(.underline) {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                storage.addAttribute(.underlineColor, value: style.nsAccent, range: r)
            } else {
                storage.removeAttribute(.underlineStyle, range: r)
            }

            if marks.contains(.strike) || done {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                storage.addAttribute(.strikethroughColor, value: style.nsTertiary, range: r)
            } else {
                storage.removeAttribute(.strikethroughStyle, range: r)
            }

            if marks.contains(.highlight) {
                let base = highlightColor.map { NSColor(hex: $0.hex) } ?? style.nsAccent
                storage.addAttribute(.backgroundColor, value: base.withAlphaComponent(dark ? 0.34 : 0.42), range: r)
                if !done, inkColor == nil { storage.addAttribute(.foregroundColor, value: style.nsText, range: r) }
            } else if marks.contains(.code), attrs.kind != .code {
                storage.addAttribute(.backgroundColor, value: style.nsSurface, range: r)
                storage.addAttribute(.foregroundColor, value: style.nsAccent.mixed(with: style.nsText, 0.35), range: r)
            } else {
                storage.removeAttribute(.backgroundColor, range: r)
            }
        }

        // Links keep the accent color with a subtle underline.
        storage.enumerateAttribute(.link, in: range) { value, r, _ in
            guard value != nil else { return }
            storage.addAttribute(.foregroundColor, value: style.nsAccent, range: r)
        }
    }

    /// Typing attributes for a fresh, unmarked run in a paragraph of this kind.
    func typingAttributes(for attrs: BlockAttributes, marks: InlineMarks = []) -> [NSAttributedString.Key: Any] {
        var d = attrs.dictionary
        d[.paragraphStyle] = paragraphStyle(for: attrs)
        d[.font] = font(for: attrs.kind, marks: marks)
        d[.foregroundColor] = style.nsSecondary
        d[.notasDecor] = decor
        if !marks.isEmpty { d[.notasMarks] = marks.rawValue }
        return d
    }
}
